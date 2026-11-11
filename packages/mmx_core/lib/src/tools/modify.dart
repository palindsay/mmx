/// Edit actions recovered from the Meshmixer `userEditAction` action bar that
/// the first implementation pass did not cover: normal flipping, global
/// smoothing, bed placement, duplication, joining, pattern arrays, primitive
/// fitting, measurement and inter-object clearance.
///
/// Every routine is deterministic, allocation-bounded and runs on a worker
/// isolate from the app layer.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../mesh/material.dart';
import '../mesh/limits.dart';
import '../spatial/bvh.dart';

enum PrimitiveKind { box, cylinder, sphere }

/// Result of [Modify.measure].
class MeasureResult {
  final List<double> dimensions;
  final double surfaceArea;
  final double volume;
  final List<double> centroid;
  final int shellCount;
  final int boundaryEdgeCount;

  const MeasureResult({
    required this.dimensions,
    required this.surfaceArea,
    required this.volume,
    required this.centroid,
    required this.shellCount,
    required this.boundaryEdgeCount,
  });

  bool get watertight => boundaryEdgeCount == 0;

  Map<String, Object> toJson() => <String, Object>{
        'dimensions': dimensions,
        'surfaceArea': surfaceArea,
        'volume': volume,
        'centroid': centroid,
        'shellCount': shellCount,
        'boundaryEdgeCount': boundaryEdgeCount,
        'watertight': watertight,
      };
}

class Modify {
  /// Reverses triangle winding so normals point the other way. The shipped
  /// FlipNormalsTool works on a face selection; [faceMask] restricts it.
  static TriMesh flipNormals(TriMesh mesh, {Uint8List? faceMask}) {
    final out = mesh.clone();
    for (var f = 0; f < out.faceCount; f++) {
      if (faceMask != null && (f >= faceMask.length || faceMask[f] == 0)) {
        continue;
      }
      out.reverseFace(f);
    }
    return out;
  }

  /// Taubin (lambda/mu) smoothing: removes high-frequency noise without the
  /// volume collapse plain Laplacian smoothing causes. Boundary vertices stay
  /// pinned unless [preserveBoundary] is false.
  static TriMesh smooth(
    TriMesh mesh, {
    int iterations = 8,
    double lambda = 0.5,
    double mu = -0.53,
    bool preserveBoundary = true,
  }) {
    if (mesh.faceCount == 0 || iterations <= 0) return mesh.clone();
    final topo = MeshTopology(mesh);
    final pinned = <int>{};
    if (preserveBoundary) {
      for (final e in topo.boundaryEdges()) {
        pinned.add(e[0]);
        pinned.add(e[1]);
      }
    }
    final positions = Float32List.fromList(mesh.positions);
    final scratch = Float32List(positions.length);
    final neighbours = List<List<int>>.generate(
        mesh.vertexCount, (v) => topo.neighborsOfVertex(v));

    void pass(double factor) {
      scratch.setAll(0, positions);
      for (var v = 0; v < mesh.vertexCount; v++) {
        if (pinned.contains(v)) continue;
        final nb = neighbours[v];
        if (nb.isEmpty) continue;
        var ax = 0.0, ay = 0.0, az = 0.0;
        for (final w in nb) {
          ax += positions[w * 3];
          ay += positions[w * 3 + 1];
          az += positions[w * 3 + 2];
        }
        final k = nb.length;
        final lx = ax / k - positions[v * 3];
        final ly = ay / k - positions[v * 3 + 1];
        final lz = az / k - positions[v * 3 + 2];
        scratch[v * 3] = positions[v * 3] + factor * lx;
        scratch[v * 3 + 1] = positions[v * 3 + 1] + factor * ly;
        scratch[v * 3 + 2] = positions[v * 3 + 2] + factor * lz;
      }
      positions.setAll(0, scratch);
    }

    for (var i = 0; i < iterations; i++) {
      pass(lambda);
      pass(mu);
    }
    return mesh.clone()..positions = positions;
  }

  /// Drops the object onto the print bed: lowest point sits at [bedY].
  static TriMesh dropToBed(TriMesh mesh, {double bedY = 0}) {
    final b = mesh.bounds();
    if (b.isEmpty) return mesh.clone();
    final out = mesh.clone();
    final dy = bedY - b.minY;
    for (var i = 1; i < out.positions.length; i += 3) {
      out.positions[i] += dy;
    }
    return out;
  }

  /// Centers the footprint on the bed origin and drops it onto the bed.
  static TriMesh centerOnBed(TriMesh mesh, {double bedY = 0}) {
    final b = mesh.bounds();
    if (b.isEmpty) return mesh.clone();
    final out = mesh.clone();
    final dx = -(b.minX + b.maxX) / 2;
    final dz = -(b.minZ + b.maxZ) / 2;
    final dy = bedY - b.minY;
    for (var i = 0; i < out.positions.length; i += 3) {
      out.positions[i] += dx;
      out.positions[i + 1] += dy;
      out.positions[i + 2] += dz;
    }
    return out;
  }

  /// Copies a mesh with an optional offset (Meshmixer's DuplicateTool).
  static TriMesh duplicate(TriMesh mesh,
      {List<double> offset = const <double>[0, 0, 0]}) {
    final out = mesh.clone();
    if (offset.length >= 3) {
      for (var i = 0; i < out.positions.length; i += 3) {
        out.positions[i] += offset[0];
        out.positions[i + 1] += offset[1];
        out.positions[i + 2] += offset[2];
      }
    }
    return out;
  }

  /// Joins meshes into one object (Meshmixer's Combine/JoinTool). Face groups
  /// are preserved and offset per input so regions stay distinguishable.
  static TriMesh combine(List<TriMesh> meshes) {
    final usable = meshes.where((m) => m.faceCount > 0).toList();
    if (usable.isEmpty) return TriMesh.empty();
    if (usable.length == 1) return usable.first.clone();

    var vertexTotal = 0;
    var faceTotal = 0;
    var groupTotal = 0;
    for (final m in usable) {
      vertexTotal += m.vertexCount;
      faceTotal += m.faceCount;
      if (m.faceGroups != null) groupTotal += m.faceCount;
    }
    final positions = Float32List(vertexTotal * 3);
    final indices = Uint32List(faceTotal * 3);
    final groups = groupTotal > 0 ? Uint16List(faceTotal) : null;
    final colors = usable.any((m) => m.vertexColors != null)
        ? Float32List(vertexTotal * 3)
        : null;
    colors?.fillRange(0, colors.length, 1.0);
    final uvs = usable.any((m) => m.cornerUvs != null)
        ? Float32List(faceTotal * 6)
        : null;
    final materials = <MeshMaterial>[];
    final materialMap = <MeshMaterial, int>{};
    final materialIds = usable.any((m) => m.materials.isNotEmpty)
        ? Uint16List(faceTotal)
        : null;
    final fallbackMaterial = MeshMaterial(name: 'unassigned');
    var vOffset = 0;
    var fOffset = 0;
    var groupId = 0;
    for (final m in usable) {
      if (uvs != null && m.cornerUvs != null) {
        uvs.setRange(
            fOffset * 6, fOffset * 6 + m.cornerUvs!.length, m.cornerUvs!);
      }
      if (materialIds != null) {
        final remap = <int, int>{};
        int mapped(int id) => remap.putIfAbsent(id, () {
              final material = id < 0 ? fallbackMaterial : m.materials[id];
              return materialMap.putIfAbsent(material, () {
                if (materials.length >= 4096) {
                  throw const FormatException(
                      'Combined material limit exceeded');
                }
                materials.add(material);
                return materials.length - 1;
              });
            });
        for (var f = 0; f < m.faceCount; f++) {
          materialIds[fOffset + f] = mapped(m.faceMaterials?[f] ?? -1);
        }
      }
      positions.setRange(
          vOffset * 3, vOffset * 3 + m.positions.length, m.positions);
      for (var i = 0; i < m.indices.length; i++) {
        indices[fOffset * 3 + i] = m.indices[i] + vOffset;
      }
      if (colors != null && m.vertexColors != null) {
        colors.setRange(
            vOffset * 3, vOffset * 3 + m.vertexColors!.length, m.vertexColors!);
      }
      if (groups != null) {
        final maxGroup = m.faceGroups?.reduce(math.max) ?? 0;
        if (maxGroup + groupId > 65535) {
          throw StateError('Combined face groups exceed uint16 range');
        }
        for (var f = 0; f < m.faceCount; f++) {
          groups[fOffset + f] = (m.faceGroups?[f] ?? 0) + groupId;
        }
        groupId += maxGroup + 1;
      }
      vOffset += m.vertexCount;
      fOffset += m.faceCount;
    }
    return TriMesh(positions, indices,
        faceGroups: groups,
        vertexColors: colors,
        cornerUvs: uvs,
        faceMaterials: materialIds,
        materials: materials);
  }

  /// Rectangular array of copies (Meshmixer's MakePatternTool, grid mode).
  /// Spacing defaults to the object's footprint plus [gap].
  static TriMesh makePattern(
    TriMesh mesh, {
    int countX = 3,
    int countY = 1,
    int countZ = 1,
    double gap = 2,
    double? spacingX,
    double? spacingZ,
    int maximumFaces = defaultMaximumGeneratedFaces,
  }) {
    if (countX <= 0 ||
        countY <= 0 ||
        countZ <= 0 ||
        !gap.isFinite ||
        (spacingX != null && !spacingX.isFinite) ||
        (spacingZ != null && !spacingZ.isFinite)) {
      throw ArgumentError('Pattern counts must be positive and spacing finite');
    }
    checkGeneratedSize(
        mesh.faceCount, mesh.vertexCount, maximumFaces, 'Pattern');
    if (mesh.faceCount == 0) return TriMesh.empty();
    var faces = mesh.faceCount;
    for (final count in [countX, countY, countZ]) {
      faces = checkedFaceProduct(faces, count, maximumFaces, 'Pattern');
    }
    final copiesCount = faces ~/ mesh.faceCount;
    if (mesh.vertexCount > maximumFaces * 3 ~/ copiesCount) {
      throw StateError('Pattern exceeds the output vertex budget');
    }
    final b = mesh.bounds();
    final sx = spacingX ?? (b.extentX + gap);
    final sz = spacingZ ?? (b.extentZ + gap);
    final copies = <TriMesh>[];
    for (var ix = 0; ix < countX; ix++) {
      for (var iz = 0; iz < countZ; iz++) {
        for (var iy = 0; iy < countY; iy++) {
          copies.add(duplicate(mesh, offset: <double>[
            ix * sx,
            iy * (b.extentY + gap),
            iz * sz,
          ]));
        }
      }
    }
    return combine(copies);
  }

  /// Replaces the mesh with a primitive fitted to its bounding box, matching
  /// FitPrimitiveTool's box/cylinder/sphere choices.
  static TriMesh fitPrimitive(TriMesh mesh, PrimitiveKind kind) {
    final b = mesh.bounds();
    if (b.isEmpty) return TriMesh.empty();
    final cx = (b.minX + b.maxX) / 2;
    final cy = (b.minY + b.maxY) / 2;
    final cz = (b.minZ + b.maxZ) / 2;
    switch (kind) {
      case PrimitiveKind.box:
        return _box(b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ);
      case PrimitiveKind.cylinder:
        final r = math.max(b.extentX, b.extentZ) / 2;
        return cylinderMesh(
          <double>[cx, b.minY, cz],
          <double>[cx, b.maxY, cz],
          r,
          r,
          sides: 48,
        );
      case PrimitiveKind.sphere:
        final r = math.max(b.extentX, math.max(b.extentY, b.extentZ)) / 2;
        return _uvSphere(cx, cy, cz, r, 32, 16);
    }
  }

  /// Bounding-box dimensions, area, signed volume, centroid and topology
  /// counters. The shipped MeasuringTool reports the same quantities.
  static MeasureResult measure(TriMesh mesh) {
    final b = mesh.bounds();
    final topo = MeshTopology(mesh);
    final components = topo.components();
    return MeasureResult(
      dimensions: <double>[b.extentX, b.extentY, b.extentZ],
      surfaceArea: mesh.surfaceArea(),
      volume: mesh.signedVolume().abs(),
      centroid: mesh.centroid(),
      shellCount: components.$2,
      boundaryEdgeCount: topo.boundaryEdges().length,
    );
  }

  /// Approximate minimum separation between two meshes: every vertex of each
  /// mesh is tested against the other's BVH and the smallest distance wins.
  /// Vertex sampling under-reports by at most the local edge length, which is
  /// the same caveat Meshmixer's clearance tool carries at coarse resolution.
  static double clearance(TriMesh a, TriMesh b) {
    if (a.faceCount == 0 || b.faceCount == 0) return double.infinity;
    final bvhA = TriangleBVH.build(a);
    final bvhB = TriangleBVH.build(b);
    var best = double.infinity;
    for (var v = 0; v < a.vertexCount; v++) {
      final hit = bvhB.closestPoint(a.vx(v), a.vy(v), a.vz(v), maxDist: best);
      if (hit != null && hit.distance < best) best = hit.distance;
    }
    for (var v = 0; v < b.vertexCount; v++) {
      final hit = bvhA.closestPoint(b.vx(v), b.vy(v), b.vz(v), maxDist: best);
      if (hit != null && hit.distance < best) best = hit.distance;
    }
    return best;
  }

  // ------------------------------------------------------------- primitives

  static TriMesh _box(
      double x0, double y0, double z0, double x1, double y1, double z1) {
    final b = MeshBuilder();
    final v = <int>[
      b.addVertex(x0, y0, z0),
      b.addVertex(x1, y0, z0),
      b.addVertex(x1, y0, z1),
      b.addVertex(x0, y0, z1),
      b.addVertex(x0, y1, z0),
      b.addVertex(x1, y1, z0),
      b.addVertex(x1, y1, z1),
      b.addVertex(x0, y1, z1),
    ];
    // Bottom, top, then the four sides, wound outward.
    const faces = <int>[
      0,
      2,
      1,
      0,
      3,
      2,
      4,
      5,
      6,
      4,
      6,
      7,
      0,
      1,
      5,
      0,
      5,
      4,
      1,
      2,
      6,
      1,
      6,
      5,
      2,
      3,
      7,
      2,
      7,
      6,
      3,
      0,
      4,
      3,
      4,
      7,
    ];
    for (var i = 0; i < faces.length; i += 3) {
      b.addTriangle(v[faces[i]], v[faces[i + 2]], v[faces[i + 1]]);
    }
    return b.build();
  }

  static TriMesh _uvSphere(
      double cx, double cy, double cz, double r, int segments, int rings) {
    final b = MeshBuilder();
    final top = b.addVertex(cx, cy + r, cz);
    final rows = <List<int>>[];
    for (var ring = 1; ring < rings; ring++) {
      final theta = math.pi * ring / rings;
      final row = <int>[];
      for (var seg = 0; seg < segments; seg++) {
        final phi = 2 * math.pi * seg / segments;
        row.add(b.addVertex(
          cx + r * math.sin(theta) * math.cos(phi),
          cy + r * math.cos(theta),
          cz + r * math.sin(theta) * math.sin(phi),
        ));
      }
      rows.add(row);
    }
    final bottom = b.addVertex(cx, cy - r, cz);

    // Top cap.
    for (var seg = 0; seg < segments; seg++) {
      final next = (seg + 1) % segments;
      b.addTriangle(top, rows.first[seg], rows.first[next]);
    }
    // Body quads split into triangles.
    for (var ring = 0; ring < rows.length - 1; ring++) {
      final upper = rows[ring];
      final lower = rows[ring + 1];
      for (var seg = 0; seg < segments; seg++) {
        final next = (seg + 1) % segments;
        b.addTriangle(upper[seg], lower[seg], upper[next]);
        b.addTriangle(upper[next], lower[seg], lower[next]);
      }
    }
    // Bottom cap.
    for (var seg = 0; seg < segments; seg++) {
      final next = (seg + 1) % segments;
      b.addTriangle(bottom, rows.last[next], rows.last[seg]);
    }
    final mesh = b.build();
    if (mesh.signedVolume() < 0) {
      for (var f = 0; f < mesh.faceCount; f++) {
        final t = mesh.indices[f * 3 + 1];
        mesh.indices[f * 3 + 1] = mesh.indices[f * 3 + 2];
        mesh.indices[f * 3 + 2] = t;
      }
    }
    return mesh;
  }
}
