import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/analysis.dart';
import '../mesh/topology.dart';
import '../mesh/tri_mesh.dart';
import '../repair/inspector.dart';
import '../spatial/bvh.dart';

enum PrintProcess { fdm, resin }

enum ScanSeverity { error, warning, unknown }

/// Editable starting values, not a certification for a printer or material.
class PrintProfile {
  final PrintProcess process;
  final double width, depth, height, border, minimumWall, overhangAngle;
  const PrintProfile(
      {this.process = PrintProcess.fdm,
      this.width = 200,
      this.depth = 200,
      this.height = 200,
      this.border = 2,
      this.minimumWall = 0.8,
      this.overhangAngle = 45});
  factory PrintProfile.fromJson(Map<String, dynamic> value) {
    double number(String key, double fallback) =>
        (value[key] as num?)?.toDouble() ?? fallback;
    final process = value['process'] ?? 'fdm';
    if (!['fdm', 'resin'].contains(process)) {
      throw const FormatException('Unknown print process');
    }
    final result = PrintProfile(
        process: process == 'resin' ? PrintProcess.resin : PrintProcess.fdm,
        width: number('widthMm', 200),
        depth: number('depthMm', 200),
        height: number('heightMm', 200),
        border: number('borderMm', 2),
        minimumWall: number('minimumWallMm', .8),
        overhangAngle: number('overhangAngle', 45));
    result.validate();
    return result;
  }
  void validate() {
    if (![width, depth, height, border, minimumWall, overhangAngle]
            .every((v) => v.isFinite) ||
        width <= 0 ||
        depth <= 0 ||
        height <= 0 ||
        border < 0 ||
        border * 2 >= math.min(width, depth) ||
        minimumWall <= 0 ||
        overhangAngle <= 0 ||
        overhangAngle >= 90) {
      throw ArgumentError('Invalid printer dimensions or process settings');
    }
  }

  Map<String, Object> toJson() => {
        'process': process.name,
        'widthMm': width,
        'depthMm': depth,
        'heightMm': height,
        'borderMm': border,
        'minimumWallMm': minimumWall,
        'overhangAngle': overhangAngle
      };
}

class ScanFinding {
  final String code, message;
  final ScanSeverity severity;
  final List<int> faces, vertices;
  const ScanFinding(this.code, this.message, this.severity,
      {this.faces = const [], this.vertices = const []});
  Map<String, Object> toJson() => {
        'code': code,
        'message': message,
        'severity': severity.name,
        'faces': faces,
        'vertices': vertices
      };
}

class ScanReport {
  final List<ScanFinding> findings;
  final List<MeshDefect> defects;
  final List<double> dimensions;
  final double area, signedVolume;
  final int components;
  final PrintProfile profile;
  ScanReport(this.findings, this.defects, this.dimensions, this.area,
      this.signedVolume, this.components, this.profile);
  bool get hasErrors => findings.any((f) => f.severity == ScanSeverity.error);
  Map<String, Object> toJson() => {
        'units': 'mm',
        'status': hasErrors ? 'needsRepair' : 'reviewRequired',
        'checks': [
          'boundary',
          'nonManifold',
          'selfIntersections',
          'duplicateFaces',
          'degenerateFaces',
          'winding',
          'bedBounds',
          'sampledWall',
          'overhang'
        ],
        'dimensionsMm': dimensions,
        'areaMm2': area,
        'signedVolumeMm3': signedVolume,
        'components': components,
        'profile': profile.toJson(),
        'findings': findings.map((f) => f.toJson()).toList(),
        'limitations': [
          'Ray-sampled wall clearance is not a global minimum thickness certificate.',
          'Intentional cavities, fit, support removal and process/material behavior require review.'
        ]
      };
}

/// Mesh inspection and preflight in physical millimeters. All expensive work
/// belongs in a cancellable worker. Unknown measurements are never marked safe.
class ScanWorkflow {
  static ScanReport inspect(TriMesh mesh,
      {PrintProfile profile = const PrintProfile(), double fragmentArea = 1}) {
    profile.validate();
    if (!fragmentArea.isFinite || fragmentArea < 0) {
      throw ArgumentError('Invalid fragment area');
    }
    final errors = mesh.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join('; '));
    final findings = <ScanFinding>[];
    final defects = MeshInspector.scan(mesh,
        smallComponentArea: fragmentArea, checkSelfIntersections: true);
    for (final d in defects) {
      final warning = d.kind == DefectKind.smallComponent;
      findings.add(ScanFinding(
          d.kind.name,
          switch (d.kind) {
            DefectKind.hole =>
              'Open boundary (${d.metric.toStringAsFixed(2)} mm perimeter). Fill only if this opening is unintended.',
            DefectKind.smallComponent =>
              'Small disconnected surface (${d.metric.toStringAsFixed(2)} mm²). Review before removing.',
            DefectKind.selfIntersection =>
              'Intersecting triangles require repair.',
            _ => 'Non-manifold connectivity requires repair.',
          },
          warning ? ScanSeverity.warning : ScanSeverity.error,
          faces: d.faces,
          vertices: d.vertices));
    }
    if (mesh.faceCount == 0) {
      findings.add(const ScanFinding(
          'empty', 'No printable faces.', ScanSeverity.error));
    }
    final duplicates = <int>[];
    final seen = <String>{};
    final degenerate = <int>[];
    final topo = MeshTopology(mesh);
    for (var f = 0; f < mesh.faceCount; f++) {
      final ids = mesh.indices.sublist(f * 3, f * 3 + 3).toList()..sort();
      if (!seen.add(ids.join(':'))) duplicates.add(f);
      final a = ids[0], b = ids[1], c = ids[2];
      final n = _normal(mesh, a, b, c);
      if (_length(n) <= 1e-20) degenerate.add(f);
    }
    if (duplicates.isNotEmpty) {
      findings.add(ScanFinding('duplicateFaces',
          'Duplicate faces overlap the same surface.', ScanSeverity.error,
          faces: duplicates));
    }
    if (degenerate.isNotEmpty) {
      findings.add(ScanFinding(
          'degenerateFaces',
          'Zero-area faces cannot form a printable surface.',
          ScanSeverity.error,
          faces: degenerate));
    }
    final winding = <int>{};
    for (final edge in topo.edgeFaces.entries) {
      if (edge.value.length != 2) continue;
      final a = edge.key ~/ mesh.vertexCount, b = edge.key % mesh.vertexCount;
      bool forward(int f) => List.generate(3, (k) => k).any((k) =>
          mesh.indices[f * 3 + k] == a &&
          mesh.indices[f * 3 + (k + 1) % 3] == b);
      if (forward(edge.value[0]) == forward(edge.value[1])) {
        winding.addAll(edge.value);
      }
    }
    if (winding.isNotEmpty) {
      findings.add(ScanFinding('winding',
          'Adjacent faces have inconsistent winding.', ScanSeverity.error,
          faces: winding.toList()));
    }
    final b = mesh.bounds();
    final volume = mesh.signedVolume();
    if (mesh.faceCount > 0 && volume <= 0 && topo.boundaryEdges().isEmpty) {
      findings.add(const ScanFinding(
          'signedVolume',
          'Closed mesh has non-positive signed volume; review shell orientation.',
          ScanSeverity.error));
    }
    if (!b.isEmpty &&
        (b.minX < profile.border - 1e-5 ||
            b.minZ < profile.border - 1e-5 ||
            b.maxX > profile.width - profile.border + 1e-5 ||
            b.maxZ > profile.depth - profile.border + 1e-5 ||
            b.minY < -1e-5 ||
            b.maxY > profile.height + 1e-5)) {
      findings.add(const ScanFinding(
          'bedBounds',
          'Model extends outside the usable build volume. Orient or arrange it before export.',
          ScanSeverity.error));
    }
    if (mesh.faceCount > 0) {
      final wall = ThicknessAnalysis.run(mesh,
          threshold: profile.minimumWall, maxSamples: 10000);
      if (wall.belowThresholdCount > 0) {
        findings.add(ScanFinding(
            'thinWall',
            '${wall.belowThresholdCount} sampled vertices below ${profile.minimumWall} mm inward-ray clearance.',
            ScanSeverity.warning,
            vertices: wall.defectVertices));
      }
      findings.add(ScanFinding(
          'wallCoverage',
          '${wall.sampledCount} wall probes; ${wall.unknownCount} have no opposing hit. Unsampled regions and narrow features remain unverified.',
          ScanSeverity.unknown));
      final overhang =
          OverhangAnalysis.run(mesh, angleDegrees: profile.overhangAngle);
      final faces = overhang.overhangFaces
          .where((f) =>
              List.generate(3, (k) => mesh.vy(mesh.indices[f * 3 + k]))
                  .any((y) => y > 1e-4))
          .toList();
      if (faces.isNotEmpty) {
        findings.add(ScanFinding(
            'overhang',
            '${faces.length} downward-facing faces may need support for this orientation.',
            ScanSeverity.warning,
            faces: faces));
      }
    }
    if (profile.process == PrintProcess.resin) {
      findings.add(const ScanFinding(
          'resinDrainage',
          'Review cavities, drain/vent connectivity and suction using cross sections; automatic drainage verification has not been performed.',
          ScanSeverity.unknown));
    }
    return ScanReport(findings, defects, [b.extentX, b.extentY, b.extentZ],
        mesh.surfaceArea(), volume, topo.components().$2, profile);
  }

  /// Returns a removable face mask without deleting anything. Protected faces
  /// protect their entire component. The largest component is always retained.
  static Uint8List fragments(TriMesh mesh,
      {required double maximumArea, Uint8List? protectedFaces}) {
    if (!maximumArea.isFinite ||
        maximumArea < 0 ||
        (protectedFaces != null && protectedFaces.length != mesh.faceCount)) {
      throw ArgumentError('Invalid fragment filter');
    }
    final (ids, count) = MeshTopology(mesh).components();
    final areas = List<double>.filled(count, 0);
    final protected = List<bool>.filled(count, false);
    for (var f = 0; f < mesh.faceCount; f++) {
      areas[ids[f]] += _length(_normal(mesh, mesh.indices[f * 3],
              mesh.indices[f * 3 + 1], mesh.indices[f * 3 + 2])) /
          2;
      if (protectedFaces != null && protectedFaces[f] != 0) {
        protected[ids[f]] = true;
      }
    }
    var largest = 0;
    for (var c = 1; c < count; c++) {
      if (areas[c] > areas[largest]) largest = c;
    }
    return Uint8List.fromList([
      for (var f = 0; f < mesh.faceCount; f++)
        ids[f] != largest && !protected[ids[f]] && areas[ids[f]] <= maximumArea
            ? 1
            : 0
    ]);
  }

  /// Bounded two-pass smoothing with fixed boundaries, crease vertices and
  /// unselected vertices. A displacement budget limits drift from the input.
  /// It preserves colors, groups, UVs and material assignments exactly.
  static TriMesh denoise(TriMesh input,
      {double maximumDisplacement = .1,
      int iterations = 5,
      double creaseAngle = 45,
      Uint8List? faceMask}) {
    if (!maximumDisplacement.isFinite ||
        maximumDisplacement < 0 ||
        iterations < 0 ||
        iterations > 100 ||
        !creaseAngle.isFinite ||
        creaseAngle < 0 ||
        creaseAngle > 180 ||
        (faceMask != null && faceMask.length != input.faceCount)) {
      throw ArgumentError('Invalid denoise settings');
    }
    final out = input.clone();
    final topo = MeshTopology(input);
    final fixed = <int>{for (final e in topo.boundaryEdges()) ...e.take(2)};
    final normals = [
      for (var f = 0; f < input.faceCount; f++)
        _normal(input, input.indices[f * 3], input.indices[f * 3 + 1],
            input.indices[f * 3 + 2])
    ];
    final threshold = math.cos(creaseAngle * math.pi / 180);
    for (final e in topo.edgeFaces.entries) {
      if (e.value.length != 2) {
        fixed.add(e.key ~/ input.vertexCount);
        fixed.add(e.key % input.vertexCount);
        continue;
      }
      final a = normals[e.value[0]], b = normals[e.value[1]];
      final length = _length(a) * _length(b);
      if (length == 0 || _dot(a, b) / length < threshold) {
        fixed.add(e.key ~/ input.vertexCount);
        fixed.add(e.key % input.vertexCount);
      }
    }
    if (faceMask != null) {
      for (var v = 0; v < input.vertexCount; v++) {
        if (topo.facesOfVertex(v).any((f) => faceMask[f] == 0)) fixed.add(v);
      }
    }
    for (var iteration = 0; iteration < iterations; iteration++) {
      for (final weight in [.5, -.53]) {
        final next = Float32List.fromList(out.positions);
        for (var v = 0; v < out.vertexCount; v++) {
          if (fixed.contains(v)) continue;
          final neighbors = topo.neighborsOfVertex(v);
          if (neighbors.isEmpty) continue;
          final point = [out.vx(v), out.vy(v), out.vz(v)];
          final delta = List<double>.filled(3, 0);
          for (final w in neighbors) {
            for (var k = 0; k < 3; k++) {
              delta[k] +=
                  (out.positions[w * 3 + k] - point[k]) / neighbors.length;
            }
          }
          final displacement = [
            for (var k = 0; k < 3; k++)
              point[k] + weight * delta[k] - input.positions[v * 3 + k]
          ];
          final distance = _length(displacement);
          final factor = distance > maximumDisplacement
              ? maximumDisplacement / distance
              : 1.0;
          for (var k = 0; k < 3; k++) {
            next[v * 3 + k] =
                input.positions[v * 3 + k] + displacement[k] * factor;
          }
        }
        out.positions = next;
      }
    }
    for (var f = 0; f < out.faceCount; f++) {
      final n = _normal(out, out.indices[f * 3], out.indices[f * 3 + 1],
          out.indices[f * 3 + 2]);
      if (_dot(normals[f], n) <= 0 && _length(normals[f]) > 0) {
        throw StateError(
            'Denoising would invert or collapse a face; reduce displacement');
      }
    }
    return out;
  }

  static List<double> _normal(TriMesh m, int a, int b, int c) {
    final x = m.vx(b) - m.vx(a), y = m.vy(b) - m.vy(a), z = m.vz(b) - m.vz(a);
    final u = m.vx(c) - m.vx(a), v = m.vy(c) - m.vy(a), w = m.vz(c) - m.vz(a);
    return [y * w - z * v, z * u - x * w, x * v - y * u];
  }

  static double _dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  static double _length(List<double> a) => math.sqrt(_dot(a, a));
}

/// Deterministic bidirectional samples of vertices and face centroids. These
/// measured statistics are not a certified Hausdorff bound between samples.
class SurfaceDeviation {
  final double maximum, rms, p95;
  final int samples;
  SurfaceDeviation(this.maximum, this.rms, this.p95, this.samples);
  Map<String, Object> toJson() => {
        'metric': 'bidirectional sampled surface distance',
        'maximumMm': maximum,
        'rmsMm': rms,
        'p95Mm': p95,
        'samples': samples,
        'certifiedBound': false
      };
  static SurfaceDeviation measure(TriMesh a, TriMesh b,
      {int maximumSamples = 60000}) {
    if (maximumSamples < 4 || maximumSamples > 1000000) {
      throw ArgumentError('Invalid deviation sample budget');
    }
    if (a.faceCount == 0 || b.faceCount == 0) {
      throw StateError('Deviation requires two non-empty surfaces');
    }
    final distances = <double>[];
    void sample(TriMesh source, TriMesh target) {
      final bvh = TriangleBVH.build(target);
      final budget = maximumSamples ~/ 4;
      final vs = math.max(1, (source.vertexCount / budget).ceil());
      final fs = math.max(1, (source.faceCount / budget).ceil());
      for (var v = 0; v < source.vertexCount; v += vs) {
        distances.add(bvh
            .closestPoint(source.vx(v), source.vy(v), source.vz(v))!
            .distance);
      }
      for (var f = 0; f < source.faceCount; f += fs) {
        final a = source.indices[f * 3],
            b = source.indices[f * 3 + 1],
            c = source.indices[f * 3 + 2];
        distances.add(bvh
            .closestPoint(
                (source.vx(a) + source.vx(b) + source.vx(c)) / 3,
                (source.vy(a) + source.vy(b) + source.vy(c)) / 3,
                (source.vz(a) + source.vz(b) + source.vz(c)) / 3)!
            .distance);
      }
    }

    sample(a, b);
    sample(b, a);
    distances.sort();
    final rms = math.sqrt(
        distances.fold<double>(0, (s, d) => s + d * d) / distances.length);
    return SurfaceDeviation(distances.last, rms,
        distances[((distances.length - 1) * .95).floor()], distances.length);
  }
}
