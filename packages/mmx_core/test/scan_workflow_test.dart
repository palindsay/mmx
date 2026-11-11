import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';
import 'scan_production_test.dart' show cube;

void main() {
  test('fragment preview respects protected small parts and keeps largest', () {
    final small = cube(half: .1)..transform(translation4(4, 0, 0));
    final mesh = Modify.combine([cube(), small]);
    final mask = ScanWorkflow.fragments(mesh, maximumArea: 1);
    expect(mask.take(12).every((v) => v == 0), isTrue);
    expect(mask.skip(12).every((v) => v == 1), isTrue);
    final protect = Uint8List(mesh.faceCount)..[12] = 1;
    expect(
        ScanWorkflow.fragments(mesh, maximumArea: 1, protectedFaces: protect)
            .every((v) => v == 0),
        isTrue);
    final changed =
        ScanRecipe.apply(mesh, ScanStep('fragments', {'areaMm2': 1}));
    expect(changed.mesh.faceCount, 12);
    expect(changed.mesh.signedVolume(), closeTo(8, 1e-6));
    expect(MeshTopology(changed.mesh).boundaryEdges(), isEmpty);
  });
  test(
      'denoise bounds physical displacement and preserves crease geometry and attributes',
      () {
    final sharp = cube()
      ..vertexColors = Float32List(24)
      ..faceGroups = Uint16List(12);
    final preserved = ScanWorkflow.denoise(sharp, maximumDisplacement: .1);
    expect(preserved.positions, sharp.positions);
    expect(preserved.vertexColors, sharp.vertexColors);
    expect(preserved.faceGroups, sharp.faceGroups);
    final noisy = IsotropicRemesher.linearSubdivide(
        IsotropicRemesher.linearSubdivide(cube()));
    for (var v = 0; v < noisy.vertexCount; v++) {
      if (noisy.vy(v) == 1 &&
          noisy.vx(v).abs() < .9 &&
          noisy.vz(v).abs() < .9) {
        noisy.positions[v * 3 + 1] += .03 * math.cos(v.toDouble());
      }
    }
    final result =
        ScanWorkflow.denoise(noisy, maximumDisplacement: .02, iterations: 3);
    var moved = 0;
    for (var v = 0; v < noisy.vertexCount; v++) {
      var d = 0.0;
      for (var k = 0; k < 3; k++) {
        d += math
            .pow(result.positions[v * 3 + k] - noisy.positions[v * 3 + k], 2)
            .toDouble();
      }
      expect(math.sqrt(d), lessThanOrEqualTo(.020001));
      if (d > 1e-10) moved++;
    }
    expect(moved, greaterThan(0));
    expect(MeshTopology(result).boundaryEdges(), isEmpty);
    expect(MeshTopology(result).nonManifoldEdges(), isEmpty);
    expect(result.signedVolume(), closeTo(8, .15));
    expect(() => ScanWorkflow.denoise(noisy, iterations: 1001),
        throwsArgumentError);
  });
  test('denoise selection pins every unselected face vertex', () {
    final mesh = IsotropicRemesher.linearSubdivide(cube());
    final mask = Uint8List(mesh.faceCount)..fillRange(0, 4, 1);
    final result = ScanWorkflow.denoise(mesh,
        maximumDisplacement: .2, creaseAngle: 180, faceMask: mask);
    for (var f = 4; f < mesh.faceCount; f++) {
      for (final v in mesh.indices.sublist(f * 3, f * 3 + 3)) {
        expect(result.positions.sublist(v * 3, v * 3 + 3),
            mesh.positions.sublist(v * 3, v * 3 + 3));
      }
    }
  });
  test('hole preview preserves existing vertices and marks inferred faces', () {
    final input = cube().extractFaces([
      for (var f = 0; f < 12; f++)
        if (f != 8 && f != 9) f
    ]);
    for (final smooth in [0, 1]) {
      final result = ScanRecipe.apply(
          input, ScanStep('fillHole', {'loop': 0, 'smooth': smooth}));
      expect(
          result.mesh.positions.take(input.positions.length), input.positions);
      expect(MeshTopology(result.mesh).boundaryEdges(), isEmpty);
      expect(MeshTopology(result.mesh).nonManifoldEdges(), isEmpty);
      expect(result.mesh.signedVolume(), closeTo(8, 1e-6));
      expect(
          result.mesh.faceGroups!
              .skip(input.faceCount)
              .every((v) => v == result.inferredGroup),
          isTrue);
      expect(result.note, contains('Inferred'));
    }
  });
  test('preflight flags bed bounds and preserves unknown wall/drainage states',
      () {
    final report = ScanWorkflow.inspect(cube(),
        profile: const PrintProfile(process: PrintProcess.resin));
    expect(report.findings.any((f) => f.code == 'bedBounds'), isTrue);
    expect(
        report.findings.any((f) =>
            f.code == 'wallCoverage' && f.severity == ScanSeverity.unknown),
        isTrue);
    expect(report.findings.any((f) => f.code == 'resinDrainage'), isTrue);
    expect(jsonDecode(jsonEncode(report.toJson()))['status'], 'needsRepair');
    final placed = cube()..transform(translation4(10, 1, 10));
    final ready = ScanWorkflow.inspect(placed);
    expect(ready.hasErrors, isFalse);
    expect(ready.toJson()['status'], 'reviewRequired');
    expect(ready.findings.any((f) => f.code == 'overhang'), isFalse);
  });
  test('overhang flags downward normals rather than upward normals', () {
    final m = cube();
    final result = OverhangAnalysis.run(m);
    expect(result.overhangFaces.toSet(), {4, 5});
    final sheet = TriMesh(Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 0, 1]),
        Uint32List.fromList([0, 1, 2]));
    final wall = ThicknessAnalysis.run(sheet, threshold: 1);
    expect(wall.unknownCount, 3);
    expect(wall.perVertex.every((v) => v.isNaN), isTrue);
  });
  test('sampled deviation is symmetric and reduction respects its budget', () {
    final a = cube(), b = cube()..transform(translation4(.1, 0, 0));
    final ab = SurfaceDeviation.measure(a, b),
        ba = SurfaceDeviation.measure(b, a);
    expect(ab.maximum, closeTo(.1, 1e-6));
    expect(ab.maximum, ba.maximum);
    expect(ab.rms, ba.rms);
    expect(ab.toJson()['certifiedBound'], isFalse);
    expect(
        () => ScanRecipe.apply(
            a, ScanStep('reduce', {'keepFraction': .25, 'deviationMm': .001})),
        throwsStateError);
    expect(a.signedVolume(), closeTo(8, 1e-6));
  });
  test('recipes round trip and reject unknown operations and settings', () {
    final recipe = ScanRecipe([
      ScanStep('denoise', {'displacementMm': .1}),
      ScanStep('repair', {'weldMm': .001})
    ]);
    expect(
        ScanRecipe.fromJson(jsonDecode(jsonEncode(recipe.toJson()))).toJson(),
        recipe.toJson());
    expect(() => ScanStep('denoise', {'iterations': double.nan}),
        throwsArgumentError);
    expect(() => ScanStep('inventSurface'), throwsArgumentError);
    expect(
        () => ScanRecipe.fromJson({'version': 2, 'units': 'mm', 'steps': []}),
        throwsFormatException);
  });
  test(
      'project v3 persists protected originals and provenance; history restores them',
      () {
    final doc = Document();
    final original = doc.add(cube(), name: 'Original')
      ..locked = true
      ..visible = false
      ..isTarget = true;
    final edit = doc.add(cube(), name: 'Working')
      ..scanSourceId = original.id
      ..scanHistory = ['step one'];
    final bytes =
        ProjectIO.write(ProjectData(doc.objects, selectedId: edit.id));
    final back = ProjectIO.read(bytes);
    expect(back.objects.first.locked, isTrue);
    expect(back.objects.last.scanSourceId, original.id);
    expect(back.objects.last.scanHistory, ['step one']);
    doc.snapshot('next');
    edit.scanHistory.add('step two');
    original.locked = false;
    doc.undo();
    expect(doc.objects.first.locked, isTrue);
    expect(doc.objects.last.scanHistory, ['step one']);
    final legacy = ProjectIO.read(
        ProjectIO.write(ProjectData([SceneObject(1, 'Legacy', cube())])));
    expect(legacy.objects.single.locked, isFalse);
    expect(legacy.objects.single.scanSourceId, isNull);
  });
  test('geometry fingerprints include attributes without mutating input',
      () async {
    final m = cube(), copy = m.clone();
    expect(await meshFingerprint(m), await meshFingerprint(copy));
    copy.faceGroups = Uint16List(12);
    expect(await meshFingerprint(m), isNot(await meshFingerprint(copy)));
  });
}
