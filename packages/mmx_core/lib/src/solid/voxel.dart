import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import '../mesh/tri_mesh.dart';
import '../spatial/bvh.dart';

/// Signed-distance voxel grid.
///
/// Construction follows the ray-cast voxelization used by Meshmixer's
/// MeshRasterizer (`RasterizeVolume_RayCast`): a narrow band of exact
/// point-to-triangle distances, an inside/outside classification by ray
/// parity, and a flood fill for the far field.
class VoxelGrid {
  final int nx, ny, nz;
  final double cellSize;
  final double originX, originY, originZ;

  /// Signed distance in world units: negative inside, positive outside.
  /// Far field is clamped to +/- (band * 4) to keep polygonisation local.
  final Float32List values;

  /// 0 = unknown, 1 = outside, 2 = inside, 3 = narrow band.
  final Uint8List state;

  VoxelGrid(this.nx, this.ny, this.nz, this.cellSize, this.originX,
      this.originY, this.originZ)
      : values = Float32List(
            _checkedCells(nx, ny, nz, cellSize, originX, originY, originZ)),
        state = Uint8List(nx * ny * nz);

  static int _checkedCells(
      int x, int y, int z, double cell, double ox, double oy, double oz) {
    if (x <= 0 ||
        y <= 0 ||
        z <= 0 ||
        x * y * z > 32 * 1024 * 1024 ||
        !cell.isFinite ||
        cell <= 0 ||
        !ox.isFinite ||
        !oy.isFinite ||
        !oz.isFinite) {
      throw ArgumentError('Invalid grid or more than 32 million voxel cells');
    }
    return x * y * z;
  }

  int index(int i, int j, int k) => (i * ny + j) * nz + k;

  double valueAt(int i, int j, int k) => values[index(i, j, k)];

  BBox get bounds => BBox.fromBounds(
        originX,
        originY,
        originZ,
        originX + nx * cellSize,
        originY + ny * cellSize,
        originZ + nz * cellSize,
      );

  /// Rasterizes [mesh] into this grid. [bandCells] controls how many cells of
  /// exact distance are computed around the surface.
  void rasterize(TriMesh mesh, {double bandCells = 2.5}) {
    final bvh = TriangleBVH.build(mesh);
    final band = bandCells * cellSize;
    final bandSq = band * band;

    // 1. Narrow band: exact unsigned distance to the nearest triangle.
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ax = mesh.vx(a), ay = mesh.vy(a), az = mesh.vz(a);
      final bx = mesh.vx(b), by = mesh.vy(b), bz = mesh.vz(b);
      final cx = mesh.vx(c), cy = mesh.vy(c), cz = mesh.vz(c);
      var tminx = math.min(ax, math.min(bx, cx)) - band;
      var tmaxx = math.max(ax, math.max(bx, cx)) + band;
      var tminy = math.min(ay, math.min(by, cy)) - band;
      var tmaxy = math.max(ay, math.max(by, cy)) + band;
      var tminz = math.min(az, math.min(bz, cz)) - band;
      var tmaxz = math.max(az, math.max(bz, cz)) + band;
      var i0 = ((tminx - originX) / cellSize).floor();
      var i1 = ((tmaxx - originX) / cellSize).ceil();
      var j0 = ((tminy - originY) / cellSize).floor();
      var j1 = ((tmaxy - originY) / cellSize).ceil();
      var k0 = ((tminz - originZ) / cellSize).floor();
      var k1 = ((tmaxz - originZ) / cellSize).ceil();
      if (i0 < 0) i0 = 0;
      if (j0 < 0) j0 = 0;
      if (k0 < 0) k0 = 0;
      if (i1 >= nx) i1 = nx - 1;
      if (j1 >= ny) j1 = ny - 1;
      if (k1 >= nz) k1 = nz - 1;
      final bary = Float64List(3);
      for (var i = i0; i <= i1; i++) {
        final px = originX + i * cellSize;
        for (var j = j0; j <= j1; j++) {
          final py = originY + j * cellSize;
          for (var k = k0; k <= k1; k++) {
            final pz = originZ + k * cellSize;
            final d2 = closestPointTriangleSq(
                px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz, bary);
            if (d2 > bandSq) continue;
            final idx = index(i, j, k);
            final d = math.sqrt(d2);
            if (state[idx] != 3 || d < values[idx].abs()) {
              values[idx] = d;
              state[idx] = 3;
            }
          }
        }
      }
    }

    // 2. Inside/outside for band cells by ray parity.
    for (var i = 0; i < nx; i++) {
      for (var j = 0; j < ny; j++) {
        for (var k = 0; k < nz; k++) {
          final idx = index(i, j, k);
          if (state[idx] != 3) continue;
          final px = originX + i * cellSize;
          final py = originY + j * cellSize;
          final pz = originZ + k * cellSize;
          final hits =
              bvh.raycastAll(<double>[px, py, pz], <double>[1.0, 1e-4, 1e-4]);
          // A ray through a shared edge can hit two triangles at the same
          // surface crossing. Count that crossing once for parity.
          var crossings = 0;
          double? previous;
          for (final hit in hits) {
            if (previous == null ||
                (hit - previous).abs() > 1e-7 * math.max(cellSize, hit.abs())) {
              crossings++;
              previous = hit;
            }
          }
          final inside = crossings.isOdd;
          // Treat roundoff at a lattice-aligned surface as exactly zero.
          // Mixed +/- sub-ulp distances create alternating signs and spurious
          // non-manifold cells along otherwise planar boundaries.
          values[idx] = values[idx] <= cellSize * 1e-7
              ? 0
              : inside
                  ? -values[idx]
                  : values[idx];
          state[idx] = inside ? 2 : 1;
        }
      }
    }

    // 3. Flood fill the exterior, then mark the rest as interior far field.
    final stack = <int>[];
    for (var i = 0; i < nx; i++) {
      for (var j = 0; j < ny; j++) {
        for (final k in <int>[0, nz - 1]) {
          final idx = index(i, j, k);
          if (state[idx] == 0) {
            state[idx] = 1;
            stack.add(idx);
          }
        }
      }
    }
    for (var i = 0; i < nx; i++) {
      for (var k = 0; k < nz; k++) {
        for (final j in <int>[0, ny - 1]) {
          final idx = index(i, j, k);
          if (state[idx] == 0) {
            state[idx] = 1;
            stack.add(idx);
          }
        }
      }
    }
    for (var j = 0; j < ny; j++) {
      for (var k = 0; k < nz; k++) {
        for (final i in <int>[0, nx - 1]) {
          final idx = index(i, j, k);
          if (state[idx] == 0) {
            state[idx] = 1;
            stack.add(idx);
          }
        }
      }
    }
    final far = band * 4;
    while (stack.isNotEmpty) {
      final idx = stack.removeLast();
      // Seeds were marked outside when queued, just like their neighbors.
      // They also need a positive distance: leaving their initial zero value
      // creates an artificial boundary shell whenever a positive offset is
      // applied to the field.
      values[idx] = far;
      final k = idx % nz;
      final j = (idx ~/ nz) % ny;
      final i = idx ~/ (nz * ny);
      if (state[idx] == 0) {
        state[idx] = 1;
        values[idx] = far;
      }
      for (final d in _neighbors) {
        final ni = i + d[0], nj = j + d[1], nk = k + d[2];
        if (ni < 0 || nj < 0 || nk < 0 || ni >= nx || nj >= ny || nk >= nz) {
          continue;
        }
        final nidx = index(ni, nj, nk);
        if (state[nidx] != 0) continue;
        state[nidx] = 1;
        values[nidx] = far;
        stack.add(nidx);
      }
    }
    for (var idx = 0; idx < values.length; idx++) {
      if (state[idx] == 0) {
        state[idx] = 2;
        values[idx] = -far;
      }
    }
  }

  /// Applies a uniform offset to the field (positive grows the solid).
  void offset(double distance) {
    for (var i = 0; i < values.length; i++) {
      values[i] -= distance;
    }
  }

  /// Smooths the field with a separable 3x3x3 box blur; used by the
  /// "Smoothing" slider on Make Solid.
  void smooth(int iterations) {
    for (var it = 0; it < iterations; it++) {
      final next = Float32List(values.length);
      for (var i = 1; i < nx - 1; i++) {
        for (var j = 1; j < ny - 1; j++) {
          for (var k = 1; k < nz - 1; k++) {
            var s = 0.0;
            for (final d in _neighbors) {
              s += values[index(i + d[0], j + d[1], k + d[2])];
            }
            final idx = index(i, j, k);
            next[idx] = 0.25 * values[idx] + 0.75 * (s / 6.0);
          }
        }
      }
      // Copy interior back, keep the boundary fixed.
      for (var i = 1; i < nx - 1; i++) {
        for (var j = 1; j < ny - 1; j++) {
          for (var k = 1; k < nz - 1; k++) {
            final idx = index(i, j, k);
            values[idx] = next[idx];
          }
        }
      }
    }
  }

  /// Copies another grid's field into this one using trilinear sampling at
  /// world-space alignment (used for CSG between differently-sized grids).
  void sampleFrom(VoxelGrid other) {
    for (var i = 0; i < nx; i++) {
      final x = originX + i * cellSize;
      for (var j = 0; j < ny; j++) {
        final y = originY + j * cellSize;
        for (var k = 0; k < nz; k++) {
          final z = originZ + k * cellSize;
          values[index(i, j, k)] = other.sampleWorld(x, y, z);
        }
      }
    }
  }

  double sampleWorld(double x, double y, double z) {
    final fx = (x - originX) / cellSize;
    final fy = (y - originY) / cellSize;
    final fz = (z - originZ) / cellSize;
    if (fx < 0 ||
        fy < 0 ||
        fz < 0 ||
        fx >= nx - 1 ||
        fy >= ny - 1 ||
        fz >= nz - 1) {
      // Outside the sampled volume: treat as fully exterior.
      return math.max(cellSize * 4, 1e-6);
    }
    final i = fx.floor(), j = fy.floor(), k = fz.floor();
    final tx = fx - i, ty = fy - j, tz = fz - k;
    double c(int di, int dj, int dk) => values[index(i + di, j + dj, k + dk)];
    final c00 = c(0, 0, 0) * (1 - tx) + c(1, 0, 0) * tx;
    final c01 = c(0, 0, 1) * (1 - tx) + c(1, 0, 1) * tx;
    final c10 = c(0, 1, 0) * (1 - tx) + c(1, 1, 0) * tx;
    final c11 = c(0, 1, 1) * (1 - tx) + c(1, 1, 1) * tx;
    final c0 = c00 * (1 - ty) + c10 * ty;
    final c1 = c01 * (1 - ty) + c11 * ty;
    return c0 * (1 - tz) + c1 * tz;
  }

  static const List<List<int>> _neighbors = <List<int>>[
    <int>[1, 0, 0],
    <int>[-1, 0, 0],
    <int>[0, 1, 0],
    <int>[0, -1, 0],
    <int>[0, 0, 1],
    <int>[0, 0, -1],
  ];
}
