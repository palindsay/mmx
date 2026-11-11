import 'dart:typed_data';

import '../mesh/limits.dart';
import '../mesh/tri_mesh.dart';
import 'voxel.dart';

/// Dual-contouring style polygonization ("surface nets") of a signed-distance
/// grid.
///
/// Meshmixer ships ImplicitPolygonizer.cpp for the same job. Surface nets are
/// used here to connect sign-changing grid edges without marching-cubes tables.
/// Vertices lie at average edge crossings. Ambiguous sign configurations can
/// still produce non-manifold topology; callers must validate their output.
class SurfaceNets {
  static TriMesh polygonize(VoxelGrid grid, {int? maximumFaces}) {
    if (maximumFaces != null) {
      checkGeneratedSize(0, 0, maximumFaces, 'Surface nets');
    }
    final nx = grid.nx, ny = grid.ny, nz = grid.nz;
    final cellVertex = Int32List(nx * ny * nz);
    for (var i = 0; i < cellVertex.length; i++) {
      cellVertex[i] = -1;
    }
    final pos = <double>[];
    final tris = <int>[];
    final cs = grid.cellSize;
    final ox = grid.originX, oy = grid.originY, oz = grid.originZ;

    const cornerOff = <List<int>>[
      <int>[0, 0, 0],
      <int>[1, 0, 0],
      <int>[1, 1, 0],
      <int>[0, 1, 0],
      <int>[0, 0, 1],
      <int>[1, 0, 1],
      <int>[1, 1, 1],
      <int>[0, 1, 1],
    ];
    const edges = <List<int>>[
      <int>[0, 1],
      <int>[1, 2],
      <int>[2, 3],
      <int>[3, 0],
      <int>[4, 5],
      <int>[5, 6],
      <int>[6, 7],
      <int>[7, 4],
      <int>[0, 4],
      <int>[1, 5],
      <int>[2, 6],
      <int>[3, 7],
    ];

    for (var i = 0; i < nx - 1; i++) {
      for (var j = 0; j < ny - 1; j++) {
        for (var k = 0; k < nz - 1; k++) {
          final vals = Float64List(8);
          var neg = 0;
          for (var c = 0; c < 8; c++) {
            final o = cornerOff[c];
            final v = grid.valueAt(i + o[0], j + o[1], k + o[2]);
            vals[c] = v;
            if (v < 0) neg++;
          }
          if (neg == 0 || neg == 8) continue;
          var sx = 0.0, sy = 0.0, sz = 0.0;
          var crossings = 0;
          for (final e in edges) {
            final v0 = vals[e[0]], v1 = vals[e[1]];
            if ((v0 < 0) == (v1 < 0)) continue;
            final t = v0 / (v0 - v1);
            final o0 = cornerOff[e[0]], o1 = cornerOff[e[1]];
            sx += (i + o0[0] + (o1[0] - o0[0]) * t) * cs + ox;
            sy += (j + o0[1] + (o1[1] - o0[1]) * t) * cs + oy;
            sz += (k + o0[2] + (o1[2] - o0[2]) * t) * cs + oz;
            crossings++;
          }
          if (crossings == 0) continue;
          final id = pos.length ~/ 3;
          if (maximumFaces != null) {
            checkGeneratedSize(0, id + 1, maximumFaces, 'Surface nets');
          }
          pos.add(sx / crossings);
          pos.add(sy / crossings);
          pos.add(sz / crossings);
          cellVertex[(i * ny + j) * nz + k] = id;
        }
      }
    }

    int vid(int i, int j, int k) {
      if (i < 0 ||
          j < 0 ||
          k < 0 ||
          i >= nx - 1 ||
          j >= ny - 1 ||
          k >= nz - 1) {
        return -1;
      }
      return cellVertex[(i * ny + j) * nz + k];
    }

    void emitQuad(int a, int b, int c, int d, int axis, bool insideToOutside) {
      if (a < 0 || b < 0 || c < 0 || d < 0) return;
      if (maximumFaces != null) {
        checkGeneratedSize(tris.length ~/ 3 + 2, pos.length ~/ 3, maximumFaces,
            'Surface nets');
      }
      // Use the grid's cyclic cell ordering, not a geometric cross product:
      // distinct cell vertices can coincide at sharp corners, where the cross
      // product is zero and cannot determine orientation.
      final forward = axis == 1 ? !insideToOutside : insideToOutside;
      if (forward) {
        tris.addAll(<int>[a, b, c]);
        tris.addAll(<int>[a, c, d]);
      } else {
        tris.addAll(<int>[a, c, b]);
        tris.addAll(<int>[a, d, c]);
      }
    }

    for (var i = 0; i < nx; i++) {
      for (var j = 0; j < ny; j++) {
        for (var k = 0; k < nz; k++) {
          final v0 = grid.valueAt(i, j, k);
          final inside = v0 < 0;
          // +X edge: four adjacent cells in the (y,z) plane.
          if (i + 1 < nx) {
            final v1 = grid.valueAt(i + 1, j, k);
            if (inside != (v1 < 0)) {
              emitQuad(vid(i, j - 1, k - 1), vid(i, j, k - 1), vid(i, j, k),
                  vid(i, j - 1, k), 0, inside);
            }
          }
          // +Y edge.
          if (j + 1 < ny) {
            final v1 = grid.valueAt(i, j + 1, k);
            if (inside != (v1 < 0)) {
              emitQuad(vid(i - 1, j, k - 1), vid(i, j, k - 1), vid(i, j, k),
                  vid(i - 1, j, k), 1, inside);
            }
          }
          // +Z edge.
          if (k + 1 < nz) {
            final v1 = grid.valueAt(i, j, k + 1);
            if (inside != (v1 < 0)) {
              emitQuad(vid(i - 1, j - 1, k), vid(i, j - 1, k), vid(i, j, k),
                  vid(i - 1, j, k), 2, inside);
            }
          }
        }
      }
    }

    final mesh = TriMesh(Float32List.fromList(pos), Uint32List.fromList(tris));
    mesh.removeDegenerateFaces(minArea: -1);
    mesh.compact();
    return mesh;
  }
}
