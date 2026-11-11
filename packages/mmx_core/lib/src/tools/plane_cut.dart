import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';
import '../repair/holes.dart';
import '../mesh/topology.dart';
import '../geom/planar_region.dart';

/// Plane cutting and slicing.
///
/// Mirrors Meshmixer's Plane Cut tool parameters: "Cut Type: Cut (Discard
/// Half) | Slice (Keep Both) | Slice Groups", "Fill Type: No Fill | Minimal
/// Fill | Remeshed Fill | Fixed Fill", plus plane offset/rotation.
class PlaneCut {
  static TriMesh cut(
    TriMesh mesh, {
    required List<double> point,
    required List<double> normal,
    bool keepPositive = true,
    bool fill = true,
    HoleFillMode fillMode = HoleFillMode.flatMinimal,
    bool sliceBoth = false,
  }) {
    if (point.length != 3 ||
        normal.length != 3 ||
        [...point, ...normal].any((v) => !v.isFinite)) {
      throw ArgumentError(
          'Plane must have finite three-dimensional point and normal');
    }
    mesh.requireUntextured('Plane cut');
    final nx = normal[0], ny = normal[1], nz = normal[2];
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) throw ArgumentError('Plane normal must be nonzero');
    final ux = nx / nl, uy = ny / nl, uz = nz / nl;
    final px = point[0], py = point[1], pz = point[2];
    final sign = keepPositive ? 1.0 : -1.0;

    double side(int v) =>
        sign *
        ((mesh.vx(v) - px) * ux +
            (mesh.vy(v) - py) * uy +
            (mesh.vz(v) - pz) * uz);

    final builderPos = <double>[...mesh.positions];
    final colors =
        mesh.vertexColors == null ? null : <double>[...mesh.vertexColors!];
    final groups = mesh.faceGroups == null ? null : <int>[];
    final eps = math.max(mesh.bounds().diagonal * 1e-9, 1e-30);
    final indices = <int>[];
    final n = mesh.vertexCount;
    // Cache of split points on edges (edge key -> vertex id).
    final splitCache = <int, int>{};

    int splitVertex(int a, int b) {
      final key = a < b ? a * n + b : b * n + a;
      final cached = splitCache[key];
      if (cached != null) return cached;
      final da = side(a), db = side(b);
      if (da.abs() <= eps) return a;
      if (db.abs() <= eps) return b;
      final t = da / (da - db);
      final id = builderPos.length ~/ 3;
      builderPos.add(mesh.vx(a) + (mesh.vx(b) - mesh.vx(a)) * t);
      builderPos.add(mesh.vy(a) + (mesh.vy(b) - mesh.vy(a)) * t);
      builderPos.add(mesh.vz(a) + (mesh.vz(b) - mesh.vz(a)) * t);
      if (colors != null) {
        for (var k = 0; k < 3; k++) {
          colors.add(mesh.vertexColors![a * 3 + k] * (1 - t) +
              mesh.vertexColors![b * 3 + k] * t);
        }
      }
      splitCache[key] = id;
      return id;
    }

    // Ordered half-space clipping preserves the source winding for every
    // permutation, including triangles with vertices exactly on the plane.
    for (var f = 0; f < mesh.faceCount; f++) {
      final polygon = <int>[];
      for (var k = 0; k < 3; k++) {
        final a = mesh.indices[f * 3 + k],
            b = mesh.indices[f * 3 + (k + 1) % 3];
        final insideA = side(a) >= -eps, insideB = side(b) >= -eps;
        if (insideA) polygon.add(a);
        if (insideA != insideB) polygon.add(splitVertex(a, b));
      }
      for (var k = 1; k + 1 < polygon.length; k++) {
        final a = polygon[0], b = polygon[k], c = polygon[k + 1];
        if (a == b || b == c || a == c) continue;
        indices.addAll([a, b, c]);
        groups?.add(mesh.faceGroups![f]);
      }
    }
    var out = TriMesh(
        Float32List.fromList(builderPos), Uint32List.fromList(indices),
        faceGroups: groups == null ? null : Uint16List.fromList(groups),
        vertexColors: colors == null ? null : Float32List.fromList(colors));
    out.removeDegenerateFaces(
        minArea: mesh.bounds().diagonal * mesh.bounds().diagonal * 1e-16);
    out.compact();
    if (fill) {
      // Only cap boundaries produced on this plane. Existing scan holes away
      // from the cut remain open; nested contours describe cavities, not disks.
      final topology = MeshTopology(out);
      final loops = topology
          .boundaryLoops()
          .where((loop) => loop.every((v) =>
              ((out.vx(v) - px) * ux +
                      (out.vy(v) - py) * uy +
                      (out.vz(v) - pz) * uz)
                  .abs() <=
              math.max(eps * 128, out.bounds().diagonal * 2e-7)))
          .toList();
      if (loops.isNotEmpty) {
        final cap = triangulatePlanarRegion(
            out.positions, loops, [-sign * ux, -sign * uy, -sign * uz]);
        out.indices = Uint32List.fromList([...out.indices, ...cap]);
        if (out.faceGroups != null) {
          out.faceGroups = Uint16List.fromList(
              [...out.faceGroups!, ...List<int>.filled(cap.length ~/ 3, 0)]);
        }
        final after = MeshTopology(out);
        for (final loop in loops) {
          for (var i = 0; i < loop.length; i++) {
            if (after
                    .edgeFaces[
                        after.edgeKey(loop[i], loop[(i + 1) % loop.length])]
                    ?.length !=
                2) {
              throw StateError('Cut cap did not close its boundary');
            }
          }
        }
      }
    }
    if (sliceBoth) {
      final other = cut(mesh,
          point: point,
          normal: normal,
          keepPositive: !keepPositive,
          fill: fill,
          fillMode: fillMode);
      out = _merge(out, other);
    }
    return out;
  }

  /// Assigns a new face group to triangles on one side of the plane without
  /// changing geometry (Meshmixer's Plane Cut "Slice Groups" mode).
  static TriMesh sliceGroups(
    TriMesh mesh, {
    required List<double> point,
    required List<double> normal,
    int groupId = 1,
    int? negativeGroupId,
  }) {
    final nx = normal[0], ny = normal[1], nz = normal[2];
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) return mesh;
    final ux = nx / nl, uy = ny / nl, uz = nz / nl;
    final px = point[0], py = point[1], pz = point[2];
    final groups = Uint16List.fromList(
        mesh.faceGroups ?? List<int>.filled(mesh.faceCount, 0));
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3];
      final b = mesh.indices[f * 3 + 1];
      final c = mesh.indices[f * 3 + 2];
      final cx = (mesh.vx(a) + mesh.vx(b) + mesh.vx(c)) / 3.0;
      final cy = (mesh.vy(a) + mesh.vy(b) + mesh.vy(c)) / 3.0;
      final cz = (mesh.vz(a) + mesh.vz(b) + mesh.vz(c)) / 3.0;
      final side = (cx - px) * ux + (cy - py) * uy + (cz - pz) * uz;
      if (side > 0) {
        groups[f] = groupId;
      } else if (negativeGroupId != null) {
        groups[f] = negativeGroupId;
      }
    }
    return mesh.clone()..faceGroups = groups;
  }

  /// Splits the mesh into shells separated by the plane without discarding
  /// either side.
  static TriMesh slice(TriMesh mesh,
      {required List<double> point, required List<double> normal}) {
    final positive =
        cut(mesh, point: point, normal: normal, keepPositive: true, fill: true);
    final negative = cut(mesh,
        point: point, normal: normal, keepPositive: false, fill: true);
    return _merge(positive, negative);
  }

  static TriMesh _merge(TriMesh a, TriMesh b) {
    final positions = Float32List(a.positions.length + b.positions.length);
    positions.setAll(0, a.positions);
    positions.setAll(a.positions.length, b.positions);
    final indices = Uint32List(a.indices.length + b.indices.length);
    indices.setAll(0, a.indices);
    final offset = a.vertexCount;
    for (var i = 0; i < b.indices.length; i++) {
      indices[a.indices.length + i] = b.indices[i] + offset;
    }
    return TriMesh(positions, indices,
        faceGroups: a.faceGroups == null && b.faceGroups == null
            ? null
            : Uint16List.fromList([
                ...?a.faceGroups,
                if (a.faceGroups == null) ...List.filled(a.faceCount, 0),
                ...?b.faceGroups,
                if (b.faceGroups == null) ...List.filled(b.faceCount, 0),
              ]),
        vertexColors: a.vertexColors == null && b.vertexColors == null
            ? null
            : Float32List.fromList([
                ...?a.vertexColors,
                if (a.vertexColors == null)
                  ...List.filled(a.positions.length, 1.0),
                ...?b.vertexColors,
                if (b.vertexColors == null)
                  ...List.filled(b.positions.length, 1.0),
              ]));
  }
}
