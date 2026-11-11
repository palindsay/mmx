import 'dart:typed_data';

import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';

/// Vertex welding and crack closing.
///
/// The shipped Meshmixer binary exposes both "Weld Cracks" and implicit
/// welding during import; this module implements the same idea with a
/// quantized spatial hash (O(n) instead of O(n^2)).
class Weld {
  /// Welds all vertices closer than [tolerance], then drops degenerate faces.
  static TriMesh weldVertices(TriMesh mesh, {double tolerance = 1e-6}) {
    return _weld(mesh, Iterable<int>.generate(mesh.vertexCount), tolerance);
  }

  /// Merges close boundary vertices without changing interior vertices.
  static TriMesh weldCracks(TriMesh mesh, {double tolerance = 1e-5}) {
    final boundary = <int>{};
    for (final edge in MeshTopology(mesh).boundaryEdges()) {
      boundary.addAll(edge);
    }
    return _weld(mesh, boundary, tolerance);
  }

  static TriMesh _weld(
      TriMesh mesh, Iterable<int> candidates, double tolerance) {
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError('Invalid weld tolerance');
    }
    if (tolerance == 0 || mesh.vertexCount == 0) return mesh.clone();
    final buckets = <(int, int, int), List<int>>{};
    final remap =
        Uint32List.fromList(List<int>.generate(mesh.vertexCount, (i) => i));
    final square = tolerance * tolerance;
    for (final v in candidates) {
      final x = mesh.vx(v), y = mesh.vy(v), z = mesh.vz(v);
      final qx = (x / tolerance).floor(),
          qy = (y / tolerance).floor(),
          qz = (z / tolerance).floor();
      int? representative;
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            for (final w
                in buckets[(qx + dx, qy + dy, qz + dz)] ?? const <int>[]) {
              final a = x - mesh.vx(w), b = y - mesh.vy(w), c = z - mesh.vz(w);
              if (a * a + b * b + c * c <= square &&
                  (representative == null || w < representative)) {
                representative = w;
              }
            }
          }
        }
      }
      if (representative == null) {
        buckets.putIfAbsent((qx, qy, qz), () => []).add(v);
      } else {
        remap[v] = representative;
      }
    }
    final out = mesh.clone();
    for (var i = 0; i < out.indices.length; i++) {
      out.indices[i] = remap[out.indices[i]];
    }
    out.removeDegenerateFaces(minArea: 0);
    out.compact();
    return out;
  }

  /// Removes faces that duplicate an existing face (same vertex set).
  static int removeDuplicateFaces(TriMesh mesh) {
    final seen = <String>{};
    final keep = <int>[];
    final groups = mesh.faceGroups == null ? null : <int>[];
    final uvs = mesh.cornerUvs == null ? null : <double>[];
    final materials = mesh.faceMaterials == null ? null : <int>[];
    for (var f = 0; f < mesh.faceCount; f++) {
      final ids = <int>[
        mesh.indices[f * 3],
        mesh.indices[f * 3 + 1],
        mesh.indices[f * 3 + 2],
      ]..sort();
      final key = '${ids[0]}_${ids[1]}_${ids[2]}';
      if (seen.add(key)) {
        groups?.add(mesh.faceGroups![f]);
        uvs?.addAll(mesh.cornerUvs!.sublist(f * 6, f * 6 + 6));
        materials?.add(mesh.faceMaterials![f]);
        keep.addAll(<int>[
          mesh.indices[f * 3],
          mesh.indices[f * 3 + 1],
          mesh.indices[f * 3 + 2]
        ]);
      }
    }
    final removed = mesh.faceCount - keep.length ~/ 3;
    if (removed > 0) {
      mesh.indices = Uint32List.fromList(keep);
      if (groups != null) mesh.faceGroups = Uint16List.fromList(groups);
      if (uvs != null) mesh.cornerUvs = Float32List.fromList(uvs);
      if (materials != null) {
        mesh.faceMaterials = Uint16List.fromList(materials);
      }
    }
    return removed;
  }
}
