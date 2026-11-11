import 'dart:math' as math;

import '../mesh/tri_mesh.dart';

class SliceLoop {
  final List<List<double>> points; // x, z at this layer
  final bool closed;
  SliceLoop(this.points, this.closed);
}

class SliceLayer {
  final double y;
  final List<SliceLoop> loops;
  SliceLayer(this.y, this.loops);
}

class SliceResult {
  final List<SliceLayer> layers;
  final double layerHeight;
  final int elapsedMs;
  SliceResult(this.layers, this.layerHeight, this.elapsedMs);
}

/// Planar slicing into closed contours.
///
/// Matches the "Make Slices" tool (MeshPlaneSlicer / MeshStepSlicer) with a
/// configurable layer height and slicing direction (+Y by default).
class Slicer {
  static SliceResult slice(TriMesh mesh,
      {double layerHeight = 0.2, double startY = 0, double? endY}) {
    if (!layerHeight.isFinite ||
        layerHeight <= 0 ||
        !startY.isFinite ||
        (endY != null && !endY.isFinite)) {
      throw ArgumentError('Invalid slice height or range');
    }
    final sw = Stopwatch()..start();
    final b = mesh.bounds();
    final y0 = math.max(b.minY, startY);
    final y1 = endY ?? b.maxY;
    final layers = <SliceLayer>[];
    if (b.isEmpty) return SliceResult(layers, layerHeight, 0);
    if ((y1 - y0) / layerHeight > 100000 ||
        (y1 - y0) / layerHeight * mesh.faceCount > 200000000) {
      throw StateError('Slice report exceeds the layer/triangle work budget');
    }

    for (var y = y0 + layerHeight * 0.5; y < y1; y += layerHeight) {
      final segments = <List<List<double>>>[];
      for (var f = 0; f < mesh.faceCount; f++) {
        final ids = <int>[
          mesh.indices[f * 3],
          mesh.indices[f * 3 + 1],
          mesh.indices[f * 3 + 2]
        ];
        final ys = <double>[mesh.vy(ids[0]), mesh.vy(ids[1]), mesh.vy(ids[2])];
        final xs = <double>[mesh.vx(ids[0]), mesh.vx(ids[1]), mesh.vx(ids[2])];
        final zs = <double>[mesh.vz(ids[0]), mesh.vz(ids[1]), mesh.vz(ids[2])];
        final pts = <List<double>>[];
        for (var i = 0; i < 3; i++) {
          final j = (i + 1) % 3;
          final ya = ys[i], yb = ys[j];
          if ((ya < y && yb > y) || (yb < y && ya > y)) {
            final t = (y - ya) / (yb - ya);
            pts.add(<double>[
              xs[i] + (xs[j] - xs[i]) * t,
              zs[i] + (zs[j] - zs[i]) * t
            ]);
          }
        }
        if (pts.length == 2) segments.add(pts);
      }
      if (segments.isEmpty) continue;
      final loops = _chain(segments);
      layers.add(SliceLayer(y, loops));
    }
    sw.stop();
    return SliceResult(layers, layerHeight, sw.elapsedMilliseconds);
  }

  /// Chains segments into closed loops by matching endpoints.
  static List<SliceLoop> _chain(List<List<List<double>>> segments) {
    final unused = List<List<List<double>>>.from(segments);
    final loops = <SliceLoop>[];
    const eps = 1e-6;
    while (unused.isNotEmpty) {
      final start = unused.removeLast();
      final pts = <List<double>>[start[0], start[1]];
      var closed = false;
      var guard = 0;
      while (guard++ < segments.length * 2) {
        final tail = pts.last;
        var found = -1;
        var reversed = false;
        for (var i = 0; i < unused.length; i++) {
          final s = unused[i];
          if (_close(s[0], tail, eps)) {
            found = i;
            reversed = false;
            break;
          }
          if (_close(s[1], tail, eps)) {
            found = i;
            reversed = true;
            break;
          }
        }
        if (found < 0) break;
        final s = unused.removeAt(found);
        pts.add(reversed ? s[0] : s[1]);
        if (_close(pts.last, pts.first, eps)) {
          pts.removeLast();
          closed = true;
          break;
        }
      }
      if (pts.length >= 3) loops.add(SliceLoop(pts, closed));
    }
    return loops;
  }

  static bool _close(List<double> a, List<double> b, double eps) =>
      (a[0] - b[0]).abs() < eps && (a[1] - b[1]).abs() < eps;
}
