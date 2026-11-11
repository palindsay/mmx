import 'dart:typed_data';

import '../mesh/limits.dart';
import '../mesh/tri_mesh.dart';
import 'voxel.dart';

/// Piecewise-linear tetrahedral isosurface extraction. Each cube uses the same
/// six tetrahedra around its 0–6 diagonal, so neighboring faces agree exactly.
/// Unlike one-vertex surface nets, disconnected crossings in a cube do not
/// collapse onto a shared nonmanifold edge. Final topology still needs checking
/// after Float32 storage, especially for exact-zero and under-resolved features.
class MarchingTetrahedra {
  static TriMesh polygonize(VoxelGrid grid, {int maximumFaces = 500000}) {
    checkGeneratedSize(0, 0, maximumFaces, 'Marching tetrahedra');
    if (grid.values.any((v) => !v.isFinite)) {
      throw ArgumentError('Marching tetrahedra requires finite voxel values');
    }
    final positions = <double>[];
    final indices = <int>[];
    final edgeVertices = <(int, int), int>{};
    final cornerIds = Int32List(8);
    final cornerValues = Float64List(8);
    final cornerPositions = Float64List(24);
    const offsets = [
      [0, 0, 0],
      [1, 0, 0],
      [1, 1, 0],
      [0, 1, 0],
      [0, 0, 1],
      [1, 0, 1],
      [1, 1, 1],
      [0, 1, 1],
    ];
    const tetrahedra = [
      [0, 5, 1, 6],
      [0, 1, 2, 6],
      [0, 2, 3, 6],
      [0, 3, 7, 6],
      [0, 7, 4, 6],
      [0, 4, 5, 6],
    ];

    int crossing(int a, int b) {
      var first = cornerIds[a], second = cornerIds[b];
      // Exact-zero endpoints use a grid-vertex key shared by every incident
      // edge, avoiding duplicate points when a surface passes a lattice node.
      if (cornerValues[a] == 0) second = first;
      if (cornerValues[b] == 0) first = second;
      final key = first < second ? (first, second) : (second, first);
      final existing = edgeVertices[key];
      if (existing != null) return existing;
      final vertex = positions.length ~/ 3;
      checkGeneratedSize(
          indices.length ~/ 3, vertex + 1, maximumFaces, 'Marching tetrahedra');
      final t = cornerValues[a] / (cornerValues[a] - cornerValues[b]);
      for (var k = 0; k < 3; k++) {
        final start = cornerPositions[a * 3 + k];
        positions.add(start + (cornerPositions[b * 3 + k] - start) * t);
      }
      edgeVertices[key] = vertex;
      return vertex;
    }

    void triangle(int a, int b, int c, int inside, int outside) {
      if (a == b || b == c || c == a) return;
      checkGeneratedSize(indices.length ~/ 3 + 1, positions.length ~/ 3,
          maximumFaces, 'Marching tetrahedra');
      final ux = positions[b * 3] - positions[a * 3];
      final uy = positions[b * 3 + 1] - positions[a * 3 + 1];
      final uz = positions[b * 3 + 2] - positions[a * 3 + 2];
      final vx = positions[c * 3] - positions[a * 3];
      final vy = positions[c * 3 + 1] - positions[a * 3 + 1];
      final vz = positions[c * 3 + 2] - positions[a * 3 + 2];
      final dx = cornerPositions[outside * 3] - cornerPositions[inside * 3];
      final dy =
          cornerPositions[outside * 3 + 1] - cornerPositions[inside * 3 + 1];
      final dz =
          cornerPositions[outside * 3 + 2] - cornerPositions[inside * 3 + 2];
      final outward = (uy * vz - uz * vy) * dx +
          (uz * vx - ux * vz) * dy +
          (ux * vy - uy * vx) * dz;
      indices.addAll(outward >= 0 ? [a, b, c] : [a, c, b]);
    }

    for (var x = 0; x < grid.nx - 1; x++) {
      for (var y = 0; y < grid.ny - 1; y++) {
        for (var z = 0; z < grid.nz - 1; z++) {
          var negatives = 0;
          for (var c = 0; c < 8; c++) {
            final o = offsets[c];
            final id = grid.index(x + o[0], y + o[1], z + o[2]);
            cornerIds[c] = id;
            cornerValues[c] = grid.values[id];
            if (cornerValues[c] < 0) negatives++;
          }
          if (negatives == 0 || negatives == 8) continue;
          for (var c = 0; c < 8; c++) {
            final o = offsets[c];
            cornerPositions[c * 3] = grid.originX + (x + o[0]) * grid.cellSize;
            cornerPositions[c * 3 + 1] =
                grid.originY + (y + o[1]) * grid.cellSize;
            cornerPositions[c * 3 + 2] =
                grid.originZ + (z + o[2]) * grid.cellSize;
          }
          for (final tet in tetrahedra) {
            final inside = <int>[], outside = <int>[];
            for (final c in tet) {
              (cornerValues[c] < 0 ? inside : outside).add(c);
            }
            if (inside.isEmpty || outside.isEmpty) continue;
            if (inside.length == 1 || outside.length == 1) {
              final single = inside.length == 1 ? inside : outside;
              final other = inside.length == 1 ? outside : inside;
              triangle(
                  crossing(single[0], other[0]),
                  crossing(single[0], other[1]),
                  crossing(single[0], other[2]),
                  inside[0],
                  outside[0]);
            } else {
              // Two negative and two positive vertices: a convex quad, with
              // cyclic order determined by which tetrahedral edges intersect.
              final a = crossing(inside[0], outside[0]);
              final b = crossing(inside[0], outside[1]);
              final c = crossing(inside[1], outside[1]);
              final d = crossing(inside[1], outside[0]);
              triangle(a, b, c, inside[0], outside[0]);
              triangle(a, c, d, inside[0], outside[0]);
            }
          }
        }
      }
    }
    return TriMesh(
        Float32List.fromList(positions), Uint32List.fromList(indices));
  }
}
