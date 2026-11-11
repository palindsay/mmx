import 'dart:math' as math;
import 'dart:typed_data';

import '../geom/bbox.dart';
import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../spatial/bvh.dart';

/// Wall-thickness measurement by inward ray casting.
///
/// Corresponds to Meshmixer's ThicknessAnalysis / "ThicknessDefectRegion":
/// each sample casts a ray along the inverted normal and records the distance
/// to the next surface crossing.
class ThicknessAnalysis {
  final Float32List perVertex;
  final double minThickness;
  final double meanThickness;
  final int belowThresholdCount;
  final List<int> defectVertices;
  final int sampledCount;
  final int unknownCount;

  ThicknessAnalysis(this.perVertex, this.minThickness, this.meanThickness,
      this.belowThresholdCount, this.defectVertices,
      {this.sampledCount = 0, this.unknownCount = 0});

  /// [threshold] flags defects. [samples] limits probing to a subset (0 = all).
  static ThicknessAnalysis run(TriMesh mesh,
      {double threshold = 0, int maxSamples = 0, double maxDist = 0}) {
    if (!threshold.isFinite ||
        threshold < 0 ||
        maxSamples < 0 ||
        !maxDist.isFinite ||
        maxDist < 0) {
      throw ArgumentError('Invalid thickness analysis settings');
    }
    final topo = MeshTopology(mesh);
    final bvh = TriangleBVH.build(mesh);
    final n = mesh.vertexCount;
    final out = Float32List(n)..fillRange(0, n, double.nan);
    final b = mesh.bounds();
    final limit = maxDist > 0 ? maxDist : b.diagonal;
    final normals = _vertexNormals(mesh, topo);
    var minT = double.infinity;
    var sum = 0.0;
    var count = 0;
    final defects = <int>[];
    var sampled = 0, unknown = 0;
    final epsilon = math.max(b.diagonal * 1e-7, 1e-12);

    final step = maxSamples > 0 && maxSamples < n ? (n / maxSamples).ceil() : 1;
    for (var v = 0; v < n; v += step) {
      final nx = normals[v * 3],
          ny = normals[v * 3 + 1],
          nz = normals[v * 3 + 2];
      sampled++;
      final px = mesh.vx(v) - nx * epsilon;
      final py = mesh.vy(v) - ny * epsilon;
      final pz = mesh.vz(v) - nz * epsilon;
      final hit = bvh
          .raycast(<double>[px, py, pz], <double>[-nx, -ny, -nz], tMax: limit);
      if (hit == null) {
        unknown++;
        continue;
      }
      final t = hit.t + epsilon;
      out[v] = t;
      if (t < minT) minT = t;
      sum += t;
      count++;
      if (threshold > 0 && t < threshold) defects.add(v);
    }
    return ThicknessAnalysis(out, count == 0 ? 0 : minT,
        count == 0 ? 0 : sum / count, defects.length, defects,
        sampledCount: sampled, unknownCount: unknown);
  }

  static Float32List _vertexNormals(TriMesh m, MeshTopology topo) {
    final out = Float32List(m.vertexCount * 3);
    for (var v = 0; v < m.vertexCount; v++) {
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (final f in topo.facesOfVertex(v)) {
        final a = m.indices[f * 3],
            bb = m.indices[f * 3 + 1],
            c = m.indices[f * 3 + 2];
        final ux = m.vx(bb) - m.vx(a),
            uy = m.vy(bb) - m.vy(a),
            uz = m.vz(bb) - m.vz(a);
        final wx = m.vx(c) - m.vx(a),
            wy = m.vy(c) - m.vy(a),
            wz = m.vz(c) - m.vz(a);
        nx += uy * wz - uz * wy;
        ny += uz * wx - ux * wz;
        nz += ux * wy - uy * wx;
      }
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l > 1e-20) {
        out[v * 3] = nx / l;
        out[v * 3 + 1] = ny / l;
        out[v * 3 + 2] = nz / l;
      } else {
        out[v * 3 + 2] = 1;
      }
    }
    return out;
  }
}

/// Overhang analysis relative to a build direction (default: -Y, i.e. the
/// print bed is the XZ plane and the model grows upward in +Y).
class OverhangAnalysis {
  final Float32List perFaceAngle;
  final Float32List perVertexSeverity;
  final double overhangArea;
  final double totalArea;
  final int faceCount;
  final List<int> overhangFaces;

  OverhangAnalysis(this.perFaceAngle, this.perVertexSeverity, this.overhangArea,
      this.totalArea, this.faceCount, this.overhangFaces);

  static OverhangAnalysis run(TriMesh mesh,
      {double angleDegrees = 45,
      List<double> buildDirection = const <double>[0, -1, 0]}) {
    final threshold = math.cos(angleDegrees * math.pi / 180);
    final perFace = Float32List(mesh.faceCount);
    final severity = Float32List(mesh.vertexCount);
    var overhangArea = 0.0;
    var total = 0.0;
    final faces = <int>[];
    final bd = buildDirection;
    final bl = math.sqrt(bd[0] * bd[0] + bd[1] * bd[1] + bd[2] * bd[2]);
    final bdx = bd[0] / bl, bdy = bd[1] / bl, bdz = bd[2] / bl;

    for (var f = 0; f < mesh.faceCount; f++) {
      final a = mesh.indices[f * 3],
          b = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ux = mesh.vx(b) - mesh.vx(a),
          uy = mesh.vy(b) - mesh.vy(a),
          uz = mesh.vz(b) - mesh.vz(a);
      final wx = mesh.vx(c) - mesh.vx(a),
          wy = mesh.vy(c) - mesh.vy(a),
          wz = mesh.vz(c) - mesh.vz(a);
      var nx = uy * wz - uz * wy,
          ny = uz * wx - ux * wz,
          nz = ux * wy - uy * wx;
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len < 1e-20) continue;
      nx /= len;
      ny /= len;
      nz /= len;
      final area = 0.5 * len;
      total += area;
      // Angle between the face normal and the downward build direction.
      final d = nx * bdx + ny * bdy + nz * bdz;
      final angle = math.acos(d.clamp(-1.0, 1.0)) * 180 / math.pi;
      perFace[f] = angle;
      if (d > threshold) {
        // Face points downward more steeply than the allowed angle.
        overhangArea += area;
        faces.add(f);
        final sev = ((d - threshold) / (1 - threshold)).clamp(0.0, 1.0);
        for (final v in <int>[a, b, c]) {
          if (sev > severity[v]) severity[v] = sev;
        }
      }
    }
    return OverhangAnalysis(
        perFace, severity, overhangArea, total, faces.length, faces);
  }
}

/// Rigid-body stability: centre of mass, support polygon, tip-over margins.
class StabilityAnalysis {
  final List<double> centerOfMass;
  final List<List<double>> contactPoints;
  final bool centerInsideSupport;
  final double minTipAngleDegrees;
  final double volume;
  final double surfaceArea;
  final double bedContactArea;

  StabilityAnalysis(
      this.centerOfMass,
      this.contactPoints,
      this.centerInsideSupport,
      this.minTipAngleDegrees,
      this.volume,
      this.surfaceArea,
      this.bedContactArea);

  /// [materialDensity] is only used for reporting mass.
  static StabilityAnalysis run(TriMesh mesh,
      {double? bedTolerance, double density = 1.0}) {
    final b = mesh.bounds();
    final volume = mesh.signedVolume();
    final com = mesh.centroid();
    final topo = MeshTopology(mesh);
    // Vertices at the lowest level define the support polygon.
    final contacts = <List<double>>[];
    // Contact is a patch, not a mathematical minimum: use a tolerance
    // proportional to the model so a resting surface is detected.
    final tol = bedTolerance ?? math.max(1e-3, b.extentY * 0.005);
    final bedY = b.minY + tol;
    for (var v = 0; v < mesh.vertexCount; v++) {
      if (mesh.vy(v) <= bedY) contacts.add(<double>[mesh.vx(v), mesh.vz(v)]);
    }
    var contactArea = 0.0;
    for (var f = 0; f < mesh.faceCount; f++) {
      var allLow = true;
      for (var k = 0; k < 3; k++) {
        if (mesh.vy(mesh.indices[f * 3 + k]) > bedY) {
          allLow = false;
          break;
        }
      }
      if (!allLow) continue;
      final a = mesh.indices[f * 3],
          bb = mesh.indices[f * 3 + 1],
          c = mesh.indices[f * 3 + 2];
      final ux = mesh.vx(bb) - mesh.vx(a), uz = mesh.vz(bb) - mesh.vz(a);
      final wx = mesh.vx(c) - mesh.vx(a), wz = mesh.vz(c) - mesh.vz(a);
      contactArea += 0.5 * (ux * wz - uz * wx).abs();
    }
    final hull = _convexHull(contacts);
    final inside = _pointInPolygon(<double>[com[0], com[2]], hull);
    // Tip angle: worst-case rotation about a hull edge until COM leaves the base.
    var minTip = 90.0;
    if (hull.length >= 3) {
      for (var i = 0; i < hull.length; i++) {
        final p = hull[i], q = hull[(i + 1) % hull.length];
        final dx = q[0] - p[0], dz = q[1] - p[1];
        final l = math.sqrt(dx * dx + dz * dz);
        if (l < 1e-9) continue;
        // Signed distance from COM projection to the edge line.
        final dist = ((com[0] - p[0]) * dz - (com[2] - p[1]) * dx) / l;
        final height = com[1] - b.minY;
        if (height <= 0) continue;
        final angle = math.atan2(dist.abs(), height) * 180 / math.pi;
        if (angle < minTip) minTip = angle;
      }
    }
    assert(topo.vertexCount == mesh.vertexCount);
    return StabilityAnalysis(
        com, hull, inside, minTip, volume, mesh.surfaceArea(), contactArea);
  }

  static List<List<double>> _convexHull(List<List<double>> pts) {
    if (pts.length < 3) return pts;
    final sorted = pts.toList()
      ..sort(
          (a, b) => a[0] == b[0] ? a[1].compareTo(b[1]) : a[0].compareTo(b[0]));
    double cross(List<double> o, List<double> a, List<double> b) =>
        (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    final lower = <List<double>>[];
    for (final p in sorted) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <List<double>>[];
    for (final p in sorted.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return <List<double>>[...lower, ...upper];
  }

  static bool _pointInPolygon(List<double> p, List<List<double>> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i][0], zi = poly[i][1];
      final xj = poly[j][0], zj = poly[j][1];
      if (((zi > p[1]) != (zj > p[1])) &&
          (p[0] < (xj - xi) * (p[1] - zi) / (zj - zi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }
}

/// Deviation between two surfaces: sampled closest-point distances.
class DeviationAnalysis {
  final Float32List perVertexDistance;
  final double maxDistance;
  final double meanDistance;

  DeviationAnalysis(
      this.perVertexDistance, this.maxDistance, this.meanDistance);

  static DeviationAnalysis run(TriMesh target, TriMesh reference,
      {int maxSamples = 20000}) {
    final bvh = TriangleBVH.build(reference);
    final out = Float32List(target.vertexCount);
    var maxD = 0.0;
    var sum = 0.0;
    var count = 0;
    final step = target.vertexCount > maxSamples
        ? (target.vertexCount / maxSamples).ceil()
        : 1;
    for (var v = 0; v < target.vertexCount; v += step) {
      final cp = bvh.closestPoint(target.vx(v), target.vy(v), target.vz(v));
      final d = cp?.distance ?? double.infinity;
      out[v] = d;
      if (d.isFinite) {
        if (d > maxD) maxD = d;
        sum += d;
        count++;
      }
    }
    return DeviationAnalysis(out, maxD, count == 0 ? 0 : sum / count);
  }
}

/// Mass properties used by the "Mesh Query / Analyze Mass Properties" panel.
class MassProperties {
  final double volume;
  final double surfaceArea;
  final List<double> centerOfMass;
  final BBox bounds;
  MassProperties(this.volume, this.surfaceArea, this.centerOfMass, this.bounds);

  static MassProperties compute(TriMesh mesh) => MassProperties(
        mesh.signedVolume(),
        mesh.surfaceArea(),
        mesh.centroid(),
        mesh.bounds(),
      );
}
