import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../spatial/bvh.dart';

enum WallClearanceStatus { passed, violated, indeterminate }

/// A certificate for a stated directional metric, not a medial-axis thickness
/// or manufacturing guarantee. Every point of every triangle is considered by
/// projected triangle clipping; this is not a collection of sampled rays.
class WallThicknessCertificate {
  static const metric = 'continuous inward-normal opposing-surface clearance';
  final WallClearanceStatus status;
  final double requestedThickness;
  final double numericalMargin;
  final int candidatePairs;

  /// Minimum for the first failing triangle pair, not a global mesh minimum.
  final double? witnessClearance;
  final int? sourceFace, targetFace;
  final List<double>? witnessPoint;
  final String diagnostic;
  const WallThicknessCertificate(
      {required this.status,
      required this.requestedThickness,
      required this.numericalMargin,
      required this.candidatePairs,
      required this.diagnostic,
      this.witnessClearance,
      this.sourceFace,
      this.targetFace,
      this.witnessPoint});
  bool get passed => status == WallClearanceStatus.passed;
  double? get verifiedLowerBound => passed ? requestedThickness : null;
}

class WallThickness {
  /// The metric excludes normals within about 0.00573 degrees of perpendicular.
  /// This explicit cutoff avoids treating Float32 perturbations of right-angle
  /// faces as opposing walls; it is not a global minimum-feature-size metric.
  static const opposingCosine = -1e-4;

  /// Check closed, consistently oriented surfaces, including correctly wound
  /// cavity shells. Sharp tips/folds can have zero normal clearance even when
  /// a sample-based estimate reports a large wall. Self-intersection freedom
  /// is not certified by this metric. Budgets fail explicitly, never pass.
  static WallThicknessCertificate certify(TriMesh mesh, double minimumThickness,
      {int maxCandidatePairs = 5000000, int maxFaces = 500000}) {
    if (!minimumThickness.isFinite ||
        minimumThickness <= 0 ||
        maxCandidatePairs <= 0 ||
        maxCandidatePairs > 100000000 ||
        maxFaces <= 0 ||
        maxFaces > 2000000) {
      throw ArgumentError('Invalid wall clearance threshold or work budget');
    }
    var pairs = 0;
    var margin = 0.0;
    WallThicknessCertificate uncertain(String message) =>
        WallThicknessCertificate(
            status: WallClearanceStatus.indeterminate,
            requestedThickness: minimumThickness,
            numericalMargin: margin,
            candidatePairs: pairs,
            diagnostic: message);
    // Topology allocates per-vertex adjacency even for unused positions. Bound
    // that work before validation/topology; face count alone cannot cap it.
    if (mesh.vertexCount > maxFaces * 3) {
      return uncertain('Wall verification exceeds the ${maxFaces * 3}-vertex '
          'budget; compact unused vertices or explicitly increase maxFaces');
    }
    if (mesh.faceCount < 4 ||
        mesh.faceCount > maxFaces ||
        mesh.validate().isNotEmpty) {
      return uncertain(
          'Wall verification needs a nonempty valid mesh within the $maxFaces-face budget');
    }
    final topology = MeshTopology(mesh);
    if (topology.boundaryEdges().isNotEmpty ||
        topology.nonManifoldEdges().isNotEmpty ||
        topology.nonManifoldVertices().isNotEmpty) {
      return uncertain(
          'Wall verification requires a closed edge/vertex manifold');
    }
    for (final entry in topology.edgeFaces.entries) {
      final a = entry.key ~/ mesh.vertexCount, b = entry.key % mesh.vertexCount;
      var winding = 0;
      for (final f in entry.value) {
        for (var k = 0; k < 3; k++) {
          final x = mesh.indices[f * 3 + k],
              y = mesh.indices[f * 3 + (k + 1) % 3];
          if (x == a && y == b) winding++;
          if (x == b && y == a) winding--;
        }
      }
      if (winding != 0) {
        return uncertain('Wall verification requires consistent face winding');
      }
    }
    final bounds = mesh.bounds(), scale = bounds.diagonal;
    final normals = Float64List(mesh.faceCount * 3);
    var poorestQuality = 1.0;
    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ux = mesh.vx(b) - mesh.vx(a),
          uy = mesh.vy(b) - mesh.vy(a),
          uz = mesh.vz(b) - mesh.vz(a);
      final vx = mesh.vx(c) - mesh.vx(a),
          vy = mesh.vy(c) - mesh.vy(a),
          vz = mesh.vz(c) - mesh.vz(a);
      final nx = uy * vz - uz * vy,
          ny = uz * vx - ux * vz,
          nz = ux * vy - uy * vx;
      final length = math.sqrt(nx * nx + ny * ny + nz * nz);
      final edgeSquared =
          math.max(ux * ux + uy * uy + uz * uz, vx * vx + vy * vy + vz * vz);
      if (length == 0 || !length.isFinite || edgeSquared == 0) {
        return uncertain(
            'Degenerate triangle $f prevents continuous wall verification');
      }
      poorestQuality = math.min(poorestQuality, length / edgeSquared);
      normals[f * 3] = nx / length;
      normals[f * 3 + 1] = ny / length;
      normals[f * 3 + 2] = nz / length;
    }
    final magnitude = [
      bounds.minX.abs(),
      bounds.minY.abs(),
      bounds.minZ.abs(),
      bounds.maxX.abs(),
      bounds.maxY.abs(),
      bounds.maxZ.abs(),
      scale
    ].reduce(math.max);
    // Account for coordinate cancellation and ill-conditioned skinny faces.
    margin = math.max(
        scale * 1e-9, 128 * 2.220446049250313e-16 * magnitude / poorestQuality);
    if (!margin.isFinite || margin > minimumThickness * .01) {
      return uncertain(
          'Coordinate/triangle conditioning exceeds the numerical clearance margin; normalize coordinates or repair slivers');
    }
    final orientation = _validateShellOrientation(mesh, topology, margin);
    if (orientation != null) return uncertain(orientation);
    final bvh = TriangleBVH.build(mesh);
    final search = minimumThickness + margin * 4;
    for (var source = 0; source < mesh.faceCount; source++) {
      final a = mesh.indices[source * 3],
          b = mesh.indices[source * 3 + 1],
          c = mesh.indices[source * 3 + 2];
      final ax = mesh.vx(a), ay = mesh.vy(a), az = mesh.vz(a);
      final nx = normals[source * 3],
          ny = normals[source * 3 + 1],
          nz = normals[source * 3 + 2];
      var ux = mesh.vx(b) - ax, uy = mesh.vy(b) - ay, uz = mesh.vz(b) - az;
      final edgeLength = math.sqrt(ux * ux + uy * uy + uz * uz);
      ux /= edgeLength;
      uy /= edgeLength;
      uz /= edgeLength;
      final vx = ny * uz - nz * uy,
          vy = nz * ux - nx * uz,
          vz = nx * uy - ny * ux;
      _Point project(int vertex) {
        final x = mesh.vx(vertex) - ax,
            y = mesh.vy(vertex) - ay,
            z = mesh.vz(vertex) - az;
        return _Point(x * ux + y * uy + z * uz, x * vx + y * vy + z * vz,
            -x * nx - y * ny - z * nz);
      }

      final sourcePolygon = [
        const _Point(0, 0, 0),
        _Point(edgeLength, 0, 0),
        project(c)
      ];
      final prism = BBox();
      for (final vertex in [a, b, c]) {
        final x = mesh.vx(vertex), y = mesh.vy(vertex), z = mesh.vz(vertex);
        prism.add(x, y, z);
        prism.add(x - nx * search, y - ny * search, z - nz * search);
      }
      prism.expand(margin * 4);
      for (final target in bvh.overlap(prism, exact: true)) {
        if (target == source) continue;
        if (++pairs > maxCandidatePairs) {
          return uncertain(
              'Wall verification exceeded $maxCandidatePairs candidate pairs; lower mesh resolution or explicitly increase the budget');
        }
        final dot = nx * normals[target * 3] +
            ny * normals[target * 3 + 1] +
            nz * normals[target * 3 + 2];
        final angularMargin = 128 * 2.220446049250313e-16 / poorestQuality;
        if (dot > opposingCosine + angularMargin) continue;
        var polygon = [
          for (var k = 0; k < 3; k++) project(mesh.indices[target * 3 + k])
        ];
        for (var k = 0; k < 3 && polygon.isNotEmpty; k++) {
          polygon = _clip(
              polygon, sourcePolygon[k], sourcePolygon[(k + 1) % 3], margin);
        }
        if (polygon.isEmpty) continue;
        final minDepth = polygon.map((p) => p.depth).reduce(math.min);
        final maxDepth = polygon.map((p) => p.depth).reduce(math.max);
        // Projection onto a nearly tangent plane magnifies lateral error in
        // ray depth by at most 1/|cos(theta)|. Apply that conditioning to the
        // acceptance margin instead of treating a small overlap as exact.
        final depthMargin = margin / dot.abs();
        // Opposing geometry behind the source face is outside this inward
        // metric. A depth interval crossing zero is a zero-clearance witness.
        if (maxDepth < -depthMargin) continue;
        final clearance = math.max(0.0, minDepth);
        if (clearance >= minimumThickness + depthMargin) continue;
        if (dot >= opposingCosine - angularMargin) {
          return uncertain('A potentially thin region has opposing normals '
              'within numerical uncertainty of the metric tangent cutoff');
        }
        final witness = polygon.reduce((a, b) => a.depth < b.depth ? a : b);
        return WallThicknessCertificate(
          status: clearance < minimumThickness - depthMargin
              ? WallClearanceStatus.violated
              : WallClearanceStatus.indeterminate,
          requestedThickness: minimumThickness,
          numericalMargin: depthMargin,
          candidatePairs: pairs,
          witnessClearance: clearance,
          sourceFace: source,
          targetFace: target,
          witnessPoint: [
            ax + witness.x * ux + witness.y * vx,
            ay + witness.x * uy + witness.y * vy,
            az + witness.x * uz + witness.y * vz
          ],
          diagnostic:
              'Opposing surface clearance $clearance is below the requested $minimumThickness plus numerical margin $depthMargin',
        );
      }
    }
    return WallThicknessCertificate(
        status: WallClearanceStatus.passed,
        requestedThickness: minimumThickness,
        numericalMargin: margin,
        candidatePairs: pairs,
        diagnostic:
            'Every triangle region passed continuous inward-normal opposing-surface clearance; this is not a medial-axis or self-intersection certificate');
  }

  /// Clipping interpolates depth along polygon edges. On a non-tangent target
  /// plane, depth is affine over the overlap polygon, so its extrema occur at
  /// polygon vertices. No finite ray sample set can provide the same coverage.
  static List<_Point> _clip(
      List<_Point> polygon, _Point a, _Point b, double margin) {
    // Expand each source half-plane. Roundoff must never erase a possible
    // overlap and produce a false pass; uncertain edge contacts fail safely.
    final edgeLength =
        math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
    double side(_Point p) =>
        (b.x - a.x) * (p.y - a.y) -
        (b.y - a.y) * (p.x - a.x) +
        margin * edgeLength;
    final out = <_Point>[];
    for (var i = 0; i < polygon.length; i++) {
      final p = polygon[i], q = polygon[(i + 1) % polygon.length];
      final dp = side(p), dq = side(q);
      if (dp >= 0) out.add(p);
      if ((dp >= 0) != (dq >= 0)) {
        final t = dp / (dp - dq);
        out.add(_Point(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t,
            p.depth + (q.depth - p.depth) * t));
      }
    }
    return out;
  }

  static String? _validateShellOrientation(
      TriMesh mesh, MeshTopology topology, double tolerance) {
    final (labels, count) = topology.components();
    if (count > 64) {
      return 'Wall verification supports at most 64 closed shells';
    }
    final faces = List.generate(count, (_) => <int>[]);
    for (var f = 0; f < labels.length; f++) {
      faces[labels[f]].add(f);
    }
    final parts = [for (final ids in faces) mesh.extractFaces(ids)];
    final trees = [for (final part in parts) TriangleBVH.build(part)];
    for (var i = 0; i < count; i++) {
      final part = parts[i];
      final a = part.indices[0], b = part.indices[1], c = part.indices[2];
      final origin = [
        (part.vx(a) + part.vx(b) + part.vx(c)) / 3,
        (part.vy(a) + part.vy(b) + part.vy(c)) / 3,
        (part.vz(a) + part.vz(b) + part.vz(c)) / 3
      ];
      var nesting = 0;
      for (var j = 0; j < count; j++) {
        if (i == j) continue;
        final close = trees[j].closestPoint(origin[0], origin[1], origin[2]);
        if (close == null || close.distance <= tolerance * 4) {
          return 'Touching/ambiguous shells prevent orientation certification';
        }
        final winding = _windingNumber(parts[j], origin).abs();
        if (!winding.isFinite ||
            (winding > 1e-6 && (winding - 1).abs() > 1e-6)) {
          return 'Ambiguous shell nesting prevents orientation certification';
        }
        if (winding > .5) nesting++;
      }
      var volume = 0.0;
      for (var f = 0; f < part.faceCount; f++) {
        final ids = [for (var k = 0; k < 3; k++) part.indices[f * 3 + k]];
        final p = [
          for (final v in ids)
            [
              part.vx(v) - origin[0],
              part.vy(v) - origin[1],
              part.vz(v) - origin[2]
            ]
        ];
        volume += p[0][0] * (p[1][1] * p[2][2] - p[1][2] * p[2][1]) +
            p[0][1] * (p[1][2] * p[2][0] - p[1][0] * p[2][2]) +
            p[0][2] * (p[1][0] * p[2][1] - p[1][1] * p[2][0]);
      }
      if (!volume.isFinite || volume == 0 || (volume > 0) != nesting.isEven) {
        return 'Shell winding must face out of material (outer shells positive; nested cavities negative)';
      }
    }
    return null;
  }

  // Analytic triangle solid angles with compensated summation. Unlike ray
  // parity, this cannot count a ray tangent to a shared edge as a crossing.
  // The van Oosterom/Strackee formula is described in Jacobson et al. 2013,
  // Robust Inside-Outside Segmentation using Generalized Winding Numbers.
  static double _windingNumber(TriMesh mesh, List<double> origin) {
    var total = 0.0, correction = 0.0;
    for (var f = 0; f < mesh.faceCount; f++) {
      final unit = <List<double>>[];
      for (var k = 0; k < 3; k++) {
        final v = mesh.indices[f * 3 + k];
        final x = mesh.vx(v) - origin[0];
        final y = mesh.vy(v) - origin[1];
        final z = mesh.vz(v) - origin[2];
        final length = math.sqrt(x * x + y * y + z * z);
        unit.add([x / length, y / length, z / length]);
      }
      final a = unit[0], b = unit[1], c = unit[2];
      final determinant = a[0] * (b[1] * c[2] - b[2] * c[1]) +
          a[1] * (b[2] * c[0] - b[0] * c[2]) +
          a[2] * (b[0] * c[1] - b[1] * c[0]);
      final denominator = 1 +
          a[0] * b[0] +
          a[1] * b[1] +
          a[2] * b[2] +
          b[0] * c[0] +
          b[1] * c[1] +
          b[2] * c[2] +
          c[0] * a[0] +
          c[1] * a[1] +
          c[2] * a[2];
      final adjusted = 2 * math.atan2(determinant, denominator) - correction;
      final next = total + adjusted;
      correction = (next - total) - adjusted;
      total = next;
    }
    return total / (4 * math.pi);
  }
}

class _Point {
  final double x, y, depth;
  const _Point(this.x, this.y, this.depth);
}
