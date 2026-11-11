import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/wall_thickness.dart';
import '../geom/bbox.dart';
import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../repair/holes.dart';
import '../repair/weld.dart';
import '../spatial/bvh.dart';
import '../tools/modify.dart';
import 'marching_tetrahedra.dart';
import 'surface_nets.dart';
import 'voxel.dart';

enum SolidMode { blocky, fast, accurate }

enum BooleanOp { union, intersection, difference }

class SolidResult {
  final TriMesh mesh;
  final int gridResolution;
  final double cellSize;
  final int elapsedMs;
  final WallThicknessCertificate? wallCertificate;

  /// Total applied Make Solid offset, including bounded thickness growth.
  final double appliedOffset;

  /// SDF shell thickness used by Hollow, which can exceed its requested value.
  final double? appliedShellThickness;
  final int thicknessAttempts;
  final String reconstruction;
  final String? reconstructionDiagnostic;
  SolidResult(this.mesh, this.gridResolution, this.cellSize, this.elapsedMs,
      {this.wallCertificate,
      this.appliedOffset = 0,
      this.appliedShellThickness,
      this.thicknessAttempts = 0,
      this.reconstruction = 'surface-nets',
      this.reconstructionDiagnostic});
}

/// Converts triangle soup into watertight solids and performs grid-based CSG.
///
/// Mirrors the shipped "Convert To Solid" / boolean / hollow tool stack
/// (MeshToSolid, ImplicitPolygonizer, SurfaceOffset, MeshBoolean) including the
/// Blocky / Fast / Accurate routines and the Smoothing / Grid Resolution /
/// Mesh Resolution / Reduce Percentage controls exposed in the UI.
class Solidifier {
  static VoxelGrid _gridFor(BBox bounds, int resolution, double padCells) {
    if (resolution < 8 ||
        resolution > 256 ||
        !padCells.isFinite ||
        padCells < 0) {
      throw ArgumentError('Resolution must be 8–256 and padding finite');
    }
    if (bounds.isEmpty) return VoxelGrid(8, 8, 8, 1, -4, -4, -4);
    final extent =
        math.max(bounds.extentX, math.max(bounds.extentY, bounds.extentZ));
    if (extent <= 0) {
      return VoxelGrid(
          8, 8, 8, 1.0, bounds.minX - 4, bounds.minY - 4, bounds.minZ - 4);
    }
    final cell = extent / resolution;
    final pad = padCells * cell;
    final nx = ((bounds.extentX + 2 * pad) / cell).ceil() + 1;
    final ny = ((bounds.extentY + 2 * pad) / cell).ceil() + 1;
    final nz = ((bounds.extentZ + 2 * pad) / cell).ceil() + 1;
    return VoxelGrid(nx, ny, nz, cell, bounds.minX - pad, bounds.minY - pad,
        bounds.minZ - pad);
  }

  static SolidResult makeSolid(
    TriMesh mesh, {
    SolidMode mode = SolidMode.accurate,
    int resolution = 128,
    double offset = 0,
    int smoothing = 0,
    double minThickness = 0,
    bool closeHoles = true,
    int maxThicknessAttempts = 6,
    double? maxAdditionalOffset,
    int maxThicknessCandidatePairs = 5000000,
  }) {
    mesh.requireUntextured('Make Solid');
    if (resolution < 8 ||
        resolution > 256 ||
        !offset.isFinite ||
        smoothing < 0 ||
        smoothing > 1000 ||
        !minThickness.isFinite ||
        minThickness < 0) {
      throw ArgumentError('Invalid Make Solid parameters');
    }
    if (minThickness > 0) {
      if (mode == SolidMode.fast) {
        throw UnsupportedError('Minimum clearance requires Accurate or Blocky '
            'mode; Fast mode reprojects vertices onto the original surface');
      }
      return _makeSolidWithClearance(mesh,
          mode: mode,
          resolution: resolution,
          offset: offset,
          smoothing: smoothing,
          minimum: minThickness,
          closeHoles: closeHoles,
          attempts: maxThicknessAttempts,
          maxGrowth: maxAdditionalOffset ?? minThickness,
          candidateBudget: maxThicknessCandidatePairs);
    }
    return _makeSolidMesh(mesh,
        mode: mode,
        resolution: resolution,
        offset: offset,
        smoothing: smoothing,
        closeHoles: closeHoles);
  }

  static SolidResult _makeSolidMesh(TriMesh mesh,
      {required SolidMode mode,
      required int resolution,
      required double offset,
      required int smoothing,
      required bool closeHoles,
      bool verifyTopology = false}) {
    final sw = Stopwatch()..start();
    var work = mesh;
    if (closeHoles) {
      work = HoleFiller.fill(work, maxLoopLength: work.bounds().diagonal * 0.5);
    }
    final effectiveResolution = switch (mode) {
      SolidMode.blocky => math.max(24, (resolution * 0.45).round()),
      SolidMode.fast => math.max(40, (resolution * 0.7).round()),
      SolidMode.accurate => resolution,
    };
    final effectiveSmoothing = switch (mode) {
      SolidMode.blocky => smoothing,
      SolidMode.fast => math.max(smoothing, 1),
      SolidMode.accurate => smoothing,
    };
    final bounds = work.bounds();
    final extent =
        math.max(bounds.extentX, math.max(bounds.extentY, bounds.extentZ));
    final cell = extent <= 0 ? 1.0 : extent / effectiveResolution;
    // Pad has to cover the offset, otherwise the grown surface is clipped by
    // the grid boundary and the result silently shrinks.
    final padCells = 3.0 + offset.abs() / cell;
    final grid = _gridFor(bounds, effectiveResolution, padCells);
    // The narrow band must cover the requested offset, otherwise the offset
    // surface falls outside the exact-distance region and gets clipped.
    grid.rasterize(work, bandCells: offset.abs() / grid.cellSize + 2.5);
    if (offset != 0) grid.offset(offset);
    if (effectiveSmoothing > 0) grid.smooth(effectiveSmoothing);
    final (polygonized, reconstruction, diagnostic) =
        _polygonize(grid, verifyTopology: verifyTopology);
    var solid = polygonized;
    if (solid.signedVolume() < 0) solid = _flip(solid);
    // Meshmixer's Fast mode reprojects the meshed voxel surface back onto the
    // input mesh after polygonization (see the Make Solid help page).
    if (mode == SolidMode.fast && work.vertexCount > 0) {
      final bvh = TriangleBVH.build(work);
      final pos = Float32List.fromList(solid.positions);
      for (var v = 0; v < solid.vertexCount; v++) {
        final hit =
            bvh.closestPoint(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]);
        if (hit == null) continue;
        pos[v * 3] = hit.point[0];
        pos[v * 3 + 1] = hit.point[1];
        pos[v * 3 + 2] = hit.point[2];
      }
      solid.positions = pos;
    }
    // Keep zero-area faces: surface nets can emit them where two cells
    // collapse, and dropping them would punch holes in the solid.
    solid.removeDegenerateFaces(minArea: -1);
    solid.compact();
    sw.stop();
    return SolidResult(
        solid, effectiveResolution, grid.cellSize, sw.elapsedMilliseconds,
        appliedOffset: offset,
        reconstruction: reconstruction,
        reconstructionDiagnostic: diagnostic);
  }

  static (TriMesh, String, String?) _polygonize(VoxelGrid grid,
      {required bool verifyTopology}) {
    var mesh = SurfaceNets.polygonize(grid,
        maximumFaces: verifyTopology ? 500000 : null);
    if (!verifyTopology) return (mesh, 'surface-nets', null);
    mesh = Weld.weldVertices(mesh, tolerance: grid.cellSize * 1e-6);
    final topology = MeshTopology(mesh);
    if (topology.boundaryEdges().isEmpty &&
        topology.nonManifoldEdges().isEmpty &&
        topology.nonManifoldVertices().isEmpty) {
      return (mesh, 'surface-nets', null);
    }
    final fallback = MarchingTetrahedra.polygonize(grid);
    return (
      fallback,
      'marching-tetrahedra',
      'Surface nets produced nonmanifold topology; used bounded marching '
          'tetrahedra on the same SDF grid before final clearance verification'
    );
  }

  static void _validateClearanceBudget(
      int attempts, double growth, int candidateBudget) {
    if (attempts < 1 ||
        attempts > 12 ||
        !growth.isFinite ||
        growth < 0 ||
        candidateBudget < 1 ||
        candidateBudget > 100000000) {
      throw ArgumentError('Clearance verification needs 1–12 attempts, finite '
          'nonnegative growth and a 1–100000000 candidate-pair budget');
    }
  }

  static SolidResult _makeSolidWithClearance(TriMesh mesh,
      {required SolidMode mode,
      required int resolution,
      required double offset,
      required int smoothing,
      required double minimum,
      required bool closeHoles,
      required int attempts,
      required double maxGrowth,
      required int candidateBudget}) {
    _validateClearanceBudget(attempts, maxGrowth, candidateBudget);
    final watch = Stopwatch()..start();
    var currentOffset = offset;
    WallThicknessCertificate? last;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final result = _makeSolidMesh(mesh,
          mode: mode,
          resolution: resolution,
          offset: currentOffset,
          smoothing: smoothing,
          closeHoles: closeHoles,
          verifyTopology: true);
      // Surface nets can emit coincident vertices at grid-aligned crossings.
      // Weld before verification; no operation may change a certified result.
      final output =
          Weld.weldVertices(result.mesh, tolerance: result.cellSize * 1e-6);
      final certificate = WallThickness.certify(output, minimum,
          maxCandidatePairs: candidateBudget);
      if (certificate.passed) {
        return SolidResult(output, result.gridResolution, result.cellSize,
            watch.elapsedMilliseconds,
            wallCertificate: certificate,
            appliedOffset: currentOffset,
            thicknessAttempts: attempt,
            reconstruction: result.reconstruction,
            reconstructionDiagnostic: result.reconstructionDiagnostic);
      }
      last = certificate;
      if (certificate.witnessClearance == null) {
        throw StateError('Make Solid clearance could not be verified: '
            '${certificate.diagnostic}. Applied offset $currentOffset; '
            'repair the input or adjust resolution/work budget.');
      }
      final remaining = offset + maxGrowth - currentOffset;
      if (remaining <= 0 || attempt == attempts) break;
      final increment = math.max(
          (minimum - certificate.witnessClearance!) * .5 +
              certificate.numericalMargin,
          result.cellSize * 1.5);
      currentOffset += math.min(remaining, increment);
    }
    throw StateError(
        'Make Solid could not meet ${WallThicknessCertificate.metric} '
        '$minimum within $attempts attempts and $maxGrowth additional offset. '
        'Last offset $currentOffset: ${last!.diagnostic}. Increase the explicit '
        'growth bound/resolution or revise sharp/thin features.');
  }

  static SolidResult boolean(TriMesh a, TriMesh b, BooleanOp op,
      {int resolution = 160}) {
    if (resolution < 8 || resolution > 256) {
      throw ArgumentError('Resolution must be 8–256');
    }
    final sw = Stopwatch()..start();
    final exact = trivialBoolean(a, b, op);
    if (exact != null) {
      return SolidResult(exact, resolution, 0, sw.elapsedMilliseconds);
    }
    a.requireUntextured('Grid Boolean');
    b.requireUntextured('Grid Boolean');
    final bounds = BBox();
    bounds.addBox(a.bounds());
    bounds.addBox(b.bounds());
    final grid = _gridFor(bounds, resolution, 3.0);
    final ga = _gridFor(bounds, resolution, 3.0);
    final gb = _gridFor(bounds, resolution, 3.0);
    ga.rasterize(a, bandCells: 2.5);
    gb.rasterize(b, bandCells: 2.5);
    for (var i = 0; i < grid.values.length; i++) {
      final va = ga.values[i];
      final vb = gb.values[i];
      grid.values[i] = switch (op) {
        BooleanOp.union => math.min(va, vb),
        BooleanOp.intersection => math.max(va, vb),
        BooleanOp.difference => math.max(va, -vb),
      };
    }
    var out = SurfaceNets.polygonize(grid);
    if (out.signedVolume() < 0) out = _flip(out);
    out.removeDegenerateFaces(minArea: -1);
    out.compact();
    sw.stop();
    return SolidResult(out, resolution, grid.cellSize, sw.elapsedMilliseconds);
  }

  /// Offset surface. Positive grows, negative shrinks.
  static SolidResult offsetSolid(TriMesh mesh, double distance,
      {int resolution = 128}) {
    return makeSolid(mesh,
        resolution: resolution, offset: distance, smoothing: 1);
  }

  /// Hollow shell with escape holes.
  ///
  /// Material band = points whose distance to the surface lies in
  /// [-thickness, 0]; escape holes are subtracted as capped cylinders.
  static SolidResult hollow(
    TriMesh mesh, {
    double thickness = 2.0,
    int holes = 3,
    double holeRadius = 3.0,
    int resolution = 128,
    bool openTop = false,
    double minThickness = 0.0,
    int maxThicknessAttempts = 6,
    double? maxAdditionalThickness,
    int maxThicknessCandidatePairs = 5000000,
  }) {
    mesh.requireUntextured('Hollow');
    if (!thickness.isFinite ||
        thickness <= 0 ||
        !minThickness.isFinite ||
        minThickness < 0 ||
        holes < 0 ||
        holes > 1000 ||
        !holeRadius.isFinite ||
        holeRadius <= 0) {
      throw ArgumentError('Invalid hollow parameters');
    }
    if (minThickness > 0) {
      if (holes != 0 || openTop) {
        throw UnsupportedError('Verified Hollow clearance requires an enclosed '
            'shell (holes: 0, openTop: false); hole rims have zero local clearance');
      }
      return _hollowWithClearance(mesh,
          thickness: thickness,
          minimum: minThickness,
          resolution: resolution,
          attempts: maxThicknessAttempts,
          maxGrowth: maxAdditionalThickness ?? minThickness,
          candidateBudget: maxThicknessCandidatePairs);
    }
    return _hollowMesh(mesh,
        thickness: thickness,
        holes: holes,
        holeRadius: holeRadius,
        resolution: resolution,
        openTop: openTop);
  }

  static SolidResult _hollowMesh(TriMesh mesh,
      {required double thickness,
      required int holes,
      required double holeRadius,
      required int resolution,
      required bool openTop,
      bool verifyTopology = false}) {
    final sw = Stopwatch()..start();
    final bounds = mesh.bounds();
    final grid = _gridFor(bounds, resolution, 3.0);
    // Band must span the wall thickness: beyond the band the field is a far
    // constant, which would otherwise truncate the shell.
    grid.rasterize(mesh, bandCells: thickness / grid.cellSize + 2.5);
    final d = grid.values;
    for (var i = 0; i < d.length; i++) {
      final v = d[i];
      d[i] = math.max(v, -thickness - v);
    }
    if (openTop) {
      // Remove a cap band above the top of the model.
      final top = bounds.maxY - thickness;
      for (var i = 0; i < grid.nx; i++) {
        for (var k = 0; k < grid.nz; k++) {
          for (var j = 0; j < grid.ny; j++) {
            final wy = grid.originY + j * grid.cellSize;
            if (wy < top) continue;
            final idx = grid.index(i, j, k);
            if (d[idx] < 0) d[idx] = grid.cellSize;
          }
        }
      }
    }
    if (holes > 0) {
      _drillEscapeHoles(grid, bounds, holes, holeRadius, thickness);
    }
    final (polygonized, reconstruction, diagnostic) =
        _polygonize(grid, verifyTopology: verifyTopology);
    var out = polygonized;
    if (out.signedVolume() < 0) out = _flip(out);
    out.removeDegenerateFaces(minArea: -1);
    out.compact();
    sw.stop();
    return SolidResult(out, resolution, grid.cellSize, sw.elapsedMilliseconds,
        appliedShellThickness: thickness,
        reconstruction: reconstruction,
        reconstructionDiagnostic: diagnostic);
  }

  static SolidResult _hollowWithClearance(TriMesh mesh,
      {required double thickness,
      required double minimum,
      required int resolution,
      required int attempts,
      required double maxGrowth,
      required int candidateBudget}) {
    _validateClearanceBudget(attempts, maxGrowth, candidateBudget);
    final watch = Stopwatch()..start();
    final maximum = thickness + maxGrowth;
    final initial = math.min(maximum, math.max(thickness, minimum));
    var current = initial;
    WallThicknessCertificate? last;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      final result = _hollowMesh(mesh,
          thickness: current,
          holes: 0,
          holeRadius: 3,
          resolution: resolution,
          openTop: false,
          verifyTopology: true);
      final output =
          Weld.weldVertices(result.mesh, tolerance: result.cellSize * 1e-6);
      final certificate = WallThickness.certify(output, minimum,
          maxCandidatePairs: candidateBudget);
      if (!certificate.passed && certificate.witnessClearance == null) {
        throw StateError('Hollow clearance could not be verified: '
            '${certificate.diagnostic}. Applied shell thickness $current; '
            'repair input or adjust resolution/work budget.');
      }
      // Verification already bounded faces/shells before component extraction.
      final (labels, count) = MeshTopology(output).components();
      var hasCavity = false;
      for (var part = 0; part < count; part++) {
        final shell = output.extractFaces([
          for (var f = 0; f < labels.length; f++)
            if (labels[f] == part) f
        ]);
        final bounds = shell.bounds();
        final cx = (bounds.minX + bounds.maxX) * .5;
        final cy = (bounds.minY + bounds.maxY) * .5;
        final cz = (bounds.minZ + bounds.maxZ) * .5;
        for (var v = 0; v < shell.vertexCount; v++) {
          shell.positions[v * 3] -= cx;
          shell.positions[v * 3 + 1] -= cy;
          shell.positions[v * 3 + 2] -= cz;
        }
        if (shell.signedVolume() < 0) hasCavity = true;
      }
      if (!hasCavity) {
        throw StateError('Verified Hollow would remove the enclosed cavity at '
            'shell thickness $current; reduce the requested minimum or increase resolution');
      }
      if (certificate.passed) {
        return SolidResult(output, result.gridResolution, result.cellSize,
            watch.elapsedMilliseconds,
            wallCertificate: certificate,
            appliedShellThickness: current,
            thicknessAttempts: attempt,
            reconstruction: result.reconstruction,
            reconstructionDiagnostic: result.reconstructionDiagnostic);
      }
      last = certificate;
      final remaining = maximum - current;
      if (remaining <= 0 || attempt == attempts) break;
      current = math.min(
          maximum,
          current +
              math.max(
                  minimum -
                      certificate.witnessClearance! +
                      certificate.numericalMargin,
                  result.cellSize * 1.5));
    }
    throw StateError('Hollow could not meet ${WallThicknessCertificate.metric} '
        '$minimum within $attempts attempts and $maxGrowth additional thickness. '
        'Last shell thickness $current: ${last!.diagnostic}. Increase the '
        'explicit growth bound/resolution or revise sharp/thin features.');
  }

  /// Drills radial escape holes around the lower part of the shell.
  static void _drillEscapeHoles(
      VoxelGrid grid, BBox bounds, int count, double radius, double thickness) {
    final cx = (bounds.minX + bounds.maxX) / 2;
    final cz = (bounds.minZ + bounds.maxZ) / 2;
    final y = bounds.minY + math.max(thickness * 1.5, bounds.extentY * 0.08);
    for (var h = 0; h < count; h++) {
      final angle = 2 * math.pi * h / count;
      final dx = math.cos(angle), dz = math.sin(angle);
      // Cylinder axis points inward from outside the bounding box.
      final startX = cx + dx * (bounds.extentX * 0.6);
      final startZ = cz + dz * (bounds.extentZ * 0.6);
      final len = math.max(bounds.extentX, bounds.extentZ) * 0.8;
      for (var i = 0; i < grid.nx; i++) {
        final px = grid.originX + i * grid.cellSize;
        for (var j = 0; j < grid.ny; j++) {
          final py = grid.originY + j * grid.cellSize;
          for (var k = 0; k < grid.nz; k++) {
            final pz = grid.originZ + k * grid.cellSize;
            final qx = px - startX, qy = py - y, qz = pz - startZ;
            final along = qx * dx + qz * dz;
            if (along < 0 || along > len) continue;
            final perpX = qx - along * dx;
            final perpZ = qz - along * dz;
            final radial = math.sqrt(perpX * perpX + qy * qy + perpZ * perpZ);
            final idx = grid.index(i, j, k);
            if (radial < radius && grid.values[idx] < 0) {
              grid.values[idx] = radius - radial; // positive => carved out
            }
          }
        }
      }
    }
  }

  static TriMesh _flip(TriMesh m) {
    final idx = Uint32List(m.indices.length);
    for (var f = 0; f < m.faceCount; f++) {
      idx[f * 3] = m.indices[f * 3];
      idx[f * 3 + 1] = m.indices[f * 3 + 2];
      idx[f * 3 + 2] = m.indices[f * 3 + 1];
    }
    return TriMesh(m.positions, idx,
        faceGroups: m.faceGroups, vertexColors: m.vertexColors);
  }
}

/// Exact empty, identical and strictly disjoint set operations. Returns null
/// when surface classification or voxelization is required.
TriMesh? trivialBoolean(TriMesh a, TriMesh b, BooleanOp op) {
  if (a.validate().isNotEmpty || b.validate().isNotEmpty) {
    throw ArgumentError('Invalid boolean operand');
  }
  if (a.faceCount == 0 || b.faceCount == 0) {
    return switch (op) {
      BooleanOp.union => (a.faceCount == 0 ? b : a).clone(),
      BooleanOp.intersection => TriMesh.empty(),
      BooleanOp.difference => a.clone(),
    };
  }
  bool same(List<num> x, List<num> y) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  if (same(a.positions, b.positions) && same(a.indices, b.indices)) {
    return op == BooleanOp.difference ? TriMesh.empty() : a.clone();
  }
  final aa = a.bounds(), bb = b.bounds();
  final disjoint = aa.maxX < bb.minX ||
      bb.maxX < aa.minX ||
      aa.maxY < bb.minY ||
      bb.maxY < aa.minY ||
      aa.maxZ < bb.minZ ||
      bb.maxZ < aa.minZ;
  if (!disjoint) return null;
  return switch (op) {
    BooleanOp.union => Modify.combine([a, b]),
    BooleanOp.intersection => TriMesh.empty(),
    BooleanOp.difference => a.clone(),
  };
}
