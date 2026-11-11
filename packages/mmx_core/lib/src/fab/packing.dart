import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/tri_mesh.dart';

class PlacedObject {
  final int index;
  final List<double> transform;
  final double width;
  final double depth;
  final double height;
  final double x;
  final double z;
  final double yawDegrees;

  PlacedObject(this.index, this.transform, this.width, this.depth, this.height,
      this.x, this.z, this.yawDegrees);
}

class PackResult {
  final List<PlacedObject> placed;
  final List<int> unplaced;
  final double bedUtilization;
  final int elapsedMs;

  PackResult(this.placed, this.unplaced, this.bedUtilization, this.elapsedMs);
}

/// Print-bed packing.
///
/// The shipped binary exposes "Packing Mode: Stacked | Optimized",
/// "Packing Style: Square | Left-to-Right", "Packing Quality:
/// Fastest | Medium Quality | Max Quality", border width and origin. This
/// implementation does raster-occupancy first-fit with optional yaw search,
/// which is the same family of algorithm (ObjectPacker_2DRasterizeJob).
class Packer {
  static PackResult pack(
    List<TriMesh> meshes, {
    double bedWidth = 200,
    double bedDepth = 200,
    double border = 2,
    double spacing = 2,
    int quality = 1,
    bool allowRotation = true,
    double rotationStepDegrees = 90,
  }) {
    if (![bedWidth, bedDepth, border, spacing, rotationStepDegrees]
            .every((v) => v.isFinite) ||
        bedWidth <= 0 ||
        bedDepth <= 0 ||
        border < 0 ||
        spacing < 0 ||
        border * 2 >= math.min(bedWidth, bedDepth) ||
        quality < 0 ||
        quality > 3 ||
        (allowRotation &&
            (rotationStepDegrees < 0.1 || rotationStepDegrees > 360))) {
      throw ArgumentError('Invalid bed dimensions, margins or packing quality');
    }
    final sw = Stopwatch()..start();
    // Raster resolution scales with quality: 1 = 4 mm cells, 3 = 1 mm cells.
    final cellSize = switch (quality) {
      0 => 6.0,
      1 => 3.0,
      2 => 1.5,
      _ => 1.0,
    };
    final usableWidth = bedWidth - 2 * border;
    final usableDepth = bedDepth - 2 * border;
    // Reserve spacing after each occupied footprint. The last object's
    // trailing reservation may extend beyond the usable bed; its actual
    // footprint is checked independently before acceptance.
    final nx = ((usableWidth + spacing) / cellSize).ceil();
    final nz = ((usableDepth + spacing) / cellSize).ceil();
    if (nx * nz > 4000000) throw StateError('Packing grid exceeds 4M cells');
    final occupied = Uint8List(nx * nz);

    bool fits(int x0, int z0, int w, int h) {
      if (x0 < 0 || z0 < 0 || x0 + w > nx || z0 + h > nz) return false;
      for (var x = x0; x < x0 + w; x++) {
        for (var z = z0; z < z0 + h; z++) {
          if (occupied[x * nz + z] != 0) return false;
        }
      }
      return true;
    }

    void mark(int x0, int z0, int w, int h) {
      for (var x = x0; x < x0 + w; x++) {
        for (var z = z0; z < z0 + h; z++) {
          occupied[x * nz + z] = 1;
        }
      }
    }

    final order = List<int>.generate(meshes.length, (i) => i);
    order.sort((a, b) {
      final fa = meshes[a].bounds().extentX * meshes[a].bounds().extentZ;
      final fb = meshes[b].bounds().extentX * meshes[b].bounds().extentZ;
      return fb.compareTo(fa);
    });

    final placed = <PlacedObject>[];
    final unplaced = <int>[];
    final margin = border;

    for (final idx in order) {
      final mesh = meshes[idx];
      final b = mesh.bounds();
      if (b.isEmpty || mesh.validate().isNotEmpty) {
        unplaced.add(idx);
        continue;
      }
      final angles = <double>[0];
      if (allowRotation && rotationStepDegrees > 0) {
        for (var a = rotationStepDegrees; a < 360; a += rotationStepDegrees) {
          angles.add(a);
        }
      }
      _Candidate? best;
      for (final angle in angles) {
        final rot = _yawMatrix(angle);
        final corners = <List<double>>[
          <double>[b.minX, b.minZ],
          <double>[b.maxX, b.minZ],
          <double>[b.maxX, b.maxZ],
          <double>[b.minX, b.maxZ],
        ].map((p) {
          final x = rot[0] * p[0] + rot[8] * p[1];
          final z = rot[2] * p[0] + rot[10] * p[1];
          return <double>[x, z];
        }).toList();
        var minX = double.infinity, maxX = double.negativeInfinity;
        var minZ = double.infinity, maxZ = double.negativeInfinity;
        for (final c in corners) {
          minX = math.min(minX, c[0]);
          maxX = math.max(maxX, c[0]);
          minZ = math.min(minZ, c[1]);
          maxZ = math.max(maxZ, c[1]);
        }
        final width = maxX - minX, depth = maxZ - minZ;
        final w = math.max(1, ((width + spacing) / cellSize).ceil());
        final h = math.max(1, ((depth + spacing) / cellSize).ceil());
        if (w > nx || h > nz) continue;
        // Scan positions, preferring the rear-left origin.
        for (var z0 = 0; z0 + h <= nz; z0++) {
          for (var x0 = 0; x0 + w <= nx; x0++) {
            if (x0 * cellSize + width > usableWidth + 1e-9 ||
                z0 * cellSize + depth > usableDepth + 1e-9 ||
                !fits(x0, z0, w, h)) {
              continue;
            }
            final cand =
                _Candidate(angle, x0, z0, w, h, minX, minZ, width, depth);
            // Prefer the lowest z, then lowest x (left-to-right, rear-first).
            if (best == null ||
                cand.z0 < best.z0 ||
                (cand.z0 == best.z0 && cand.x0 < best.x0)) {
              best = cand;
            }
            break;
          }
          if (best != null) break;
        }
      }
      if (best == null) {
        unplaced.add(idx);
        continue;
      }
      mark(best.x0, best.z0, best.w, best.h);
      final rot = _yawMatrix(best.angle);
      // Translate so the rotated footprint sits at the chosen cell, with the
      // model resting on the bed.
      final targetX = margin + best.x0 * cellSize - best.minX;
      final targetZ = margin + best.z0 * cellSize - best.minZ;
      final targetY = -b.minY;
      final m = List<double>.from(rot);
      m[12] = targetX;
      m[13] = targetY;
      m[14] = targetZ;
      placed.add(PlacedObject(idx, m, best.width, best.depth, b.extentY,
          targetX, targetZ, best.angle));
    }

    var used = 0.0;
    for (final o in placed) {
      used += o.width * o.depth;
    }
    sw.stop();
    return PackResult(
        placed, unplaced, used / (bedWidth * bedDepth), sw.elapsedMilliseconds);
  }

  static List<double> _yawMatrix(double degrees) {
    final a = degrees * math.pi / 180;
    final c = math.cos(a), s = math.sin(a);
    return <double>[
      c,
      0,
      -s,
      0,
      0,
      1,
      0,
      0,
      s,
      0,
      c,
      0,
      0,
      0,
      0,
      1,
    ];
  }
}

class _Candidate {
  final double angle;
  final int x0, z0, w, h;
  final double minX, minZ, width, depth;
  _Candidate(this.angle, this.x0, this.z0, this.w, this.h, this.minX, this.minZ,
      this.width, this.depth);
}
