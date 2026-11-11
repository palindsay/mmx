import 'dart:math' as math;

/// Triangulates nested planar contours with even/odd filling. This is a
/// clean-room visibility-bridge / ear-clipping implementation. Boundary
/// vertices are retained (including collinear vertices) to avoid T-junctions.
/// Ambiguous/touching contours or exhausted complexity budgets fail atomically.
List<int> triangulatePlanarRegion(
    List<double> positions, List<List<int>> contours, List<double> normal) {
  if (contours.isEmpty) return [];
  final count = contours.fold<int>(0, (n, c) => n + c.length);
  if (count > 16384 || contours.any((c) => c.length < 3)) {
    throw StateError('Planar cap requires 3–16384 contour vertices');
  }
  final drop =
      normal[0].abs() >= normal[1].abs() && normal[0].abs() >= normal[2].abs()
          ? 0
          : normal[1].abs() >= normal[2].abs()
              ? 1
              : 2;
  final u = (drop + 1) % 3, v = (drop + 2) % 3;
  final origin = contours.first.first * 3;
  var scale = 0.0;
  for (final c in contours) {
    for (final id in c) {
      scale = math.max(
          scale,
          math.max((positions[id * 3 + u] - positions[origin + u]).abs(),
              (positions[id * 3 + v] - positions[origin + v]).abs()));
    }
  }
  if (!scale.isFinite || scale == 0) {
    throw StateError('Degenerate cap contours');
  }
  final xy = <int, List<double>>{
    for (final c in contours)
      for (final id in c)
        id: [
          (positions[id * 3 + u] - positions[origin + u]) / scale,
          (positions[id * 3 + v] - positions[origin + v]) / scale
        ],
  };
  const eps = 1e-12;
  var budget = 20000000;
  void tick() {
    if (--budget < 0) throw StateError('Planar cap complexity limit exceeded');
  }

  double cross(int a, int b, int c) =>
      (xy[b]![0] - xy[a]![0]) * (xy[c]![1] - xy[a]![1]) -
      (xy[b]![1] - xy[a]![1]) * (xy[c]![0] - xy[a]![0]);
  bool same(int a, int b) => xy[a]![0] == xy[b]![0] && xy[a]![1] == xy[b]![1];
  bool on(int a, int b, int c) =>
      cross(a, b, c).abs() <= eps &&
      xy[c]![0] >= math.min(xy[a]![0], xy[b]![0]) - eps &&
      xy[c]![0] <= math.max(xy[a]![0], xy[b]![0]) + eps &&
      xy[c]![1] >= math.min(xy[a]![1], xy[b]![1]) - eps &&
      xy[c]![1] <= math.max(xy[a]![1], xy[b]![1]) + eps;
  bool intersects(int a, int b, int c, int d) {
    tick();
    return (cross(a, b, c) * cross(a, b, d) < 0 &&
            cross(c, d, a) * cross(c, d, b) < 0) ||
        on(a, b, c) ||
        on(a, b, d) ||
        on(c, d, a) ||
        on(c, d, b);
  }

  bool inside(double x, double y, List<int> loop) {
    var result = false;
    for (var i = 0; i < loop.length; i++) {
      final a = xy[loop[i]]!, b = xy[loop[(i + 1) % loop.length]]!;
      if ((a[1] > y) != (b[1] > y) &&
          x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) {
        result = !result;
      }
    }
    return result;
  }

  double area(List<int> loop) {
    var value = 0.0;
    for (var i = 0; i < loop.length; i++) {
      final a = xy[loop[i]]!, b = xy[loop[(i + 1) % loop.length]]!;
      value += a[0] * b[1] - b[0] * a[1];
    }
    return value / 2;
  }

  // Validate all contours before stitching, including crossings between loops.
  final edges = <(int, int, int)>[];
  for (var k = 0; k < contours.length; k++) {
    final c = contours[k];
    if (c.toSet().length != c.length || area(c).abs() <= eps) {
      throw StateError('Invalid cap contour');
    }
    for (var i = 0; i < c.length; i++) {
      edges.add((c[i], c[(i + 1) % c.length], k));
    }
  }
  for (var i = 0; i < edges.length; i++) {
    final (a, b, k) = edges[i];
    for (var j = i + 1; j < edges.length; j++) {
      final (c, d, l) = edges[j];
      if (k == l && (a == c || a == d || b == c || b == d)) continue;
      if (intersects(a, b, c, d)) {
        throw StateError('Touching or crossing cap contours');
      }
    }
  }
  final parents = List<int>.filled(contours.length, -1);
  final areas = contours.map((c) => area(c).abs()).toList();
  for (var i = 0; i < contours.length; i++) {
    final p = xy[contours[i].first]!;
    for (var j = 0; j < contours.length; j++) {
      if (i != j &&
          areas[j] > areas[i] &&
          inside(p[0], p[1], contours[j]) &&
          (parents[i] < 0 || areas[j] < areas[parents[i]])) {
        parents[i] = j;
      }
    }
  }
  int depth(int i) {
    var n = 0;
    while (parents[i] >= 0) {
      n++;
      i = parents[i];
    }
    return n;
  }

  final result = <int>[];
  var expectedArea = 0.0;
  for (var i = 0; i < contours.length; i++) {
    expectedArea += (depth(i).isEven ? 1 : -1) * areas[i];
    if (depth(i).isOdd) continue;
    var polygon = List<int>.from(contours[i]);
    if (area(polygon) < 0) polygon = polygon.reversed.toList();
    final holes = [
      for (var h = 0; h < contours.length; h++)
        if (parents[h] == i) h
    ];
    for (final h in holes) {
      var hole = List<int>.from(contours[h]);
      if (area(hole) > 0) hole = hole.reversed.toList();
      var outerIndex = -1, holeIndex = -1;
      var distance = double.infinity;
      for (var a = 0; a < polygon.length; a++) {
        for (var b = 0; b < hole.length; b++) {
          tick();
          final va = polygon[a], vb = hole[b];
          final dx = xy[va]![0] - xy[vb]![0], dy = xy[va]![1] - xy[vb]![1];
          final d2 = dx * dx + dy * dy;
          if (d2 >= distance) continue;
          var visible = true;
          for (final boundary in [polygon, ...holes.map((j) => contours[j])]) {
            for (var e = 0; e < boundary.length; e++) {
              final c = boundary[e], d = boundary[(e + 1) % boundary.length];
              if (c == va || d == va || c == vb || d == vb) continue;
              if (intersects(va, vb, c, d)) {
                visible = false;
                break;
              }
            }
            if (!visible) break;
          }
          final mx = (xy[va]![0] + xy[vb]![0]) / 2,
              my = (xy[va]![1] + xy[vb]![1]) / 2;
          if (!visible ||
              !inside(mx, my, contours[i]) ||
              holes.any((j) => inside(mx, my, contours[j]))) {
            continue;
          }
          outerIndex = a;
          holeIndex = b;
          distance = d2;
        }
      }
      if (outerIndex < 0) {
        throw StateError('Cannot connect cap hole without crossing contours');
      }
      final traversal = [
        ...hole.sublist(holeIndex),
        ...hole.sublist(0, holeIndex)
      ];
      polygon = [
        ...polygon.take(outerIndex + 1),
        ...traversal,
        traversal.first,
        polygon[outerIndex],
        ...polygon.skip(outerIndex + 1)
      ];
    }
    while (polygon.length > 3) {
      var clipped = false;
      for (var k = 0; k < polygon.length; k++) {
        final a = polygon[(k + polygon.length - 1) % polygon.length],
            b = polygon[k],
            c = polygon[(k + 1) % polygon.length];
        if (cross(a, b, c) <= eps) continue;
        var blocked = false;
        for (final p in polygon) {
          tick();
          if (same(p, a) || same(p, b) || same(p, c)) continue;
          if (cross(a, b, p) >= -eps &&
              cross(b, c, p) >= -eps &&
              cross(c, a, p) >= -eps) {
            blocked = true;
            break;
          }
        }
        if (blocked) continue;
        result.addAll([a, b, c]);
        polygon.removeAt(k);
        clipped = true;
        break;
      }
      if (!clipped) {
        throw StateError(
            'Cannot triangulate cap while preserving its boundary');
      }
    }
    if (cross(polygon[0], polygon[1], polygon[2]) <= eps) {
      throw StateError('Degenerate final cap triangle');
    }
    result.addAll(polygon);
  }
  var actualArea = 0.0;
  for (var f = 0; f < result.length; f += 3) {
    actualArea += cross(result[f], result[f + 1], result[f + 2]) / 2;
  }
  if ((actualArea - expectedArea).abs() >
      math.max(1e-10, expectedArea * 1e-8)) {
    throw StateError('Cap area validation failed');
  }
  if (normal[drop] < 0) {
    for (var f = 0; f < result.length; f += 3) {
      final t = result[f + 1];
      result[f + 1] = result[f + 2];
      result[f + 2] = t;
    }
  }
  return result;
}
