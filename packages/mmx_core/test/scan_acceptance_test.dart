import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';

TriMesh cube(double half) => Modify.fitPrimitive(
    TriMesh(Float32List.fromList([-half, -half, -half, half, half, half]),
        Uint32List(0)),
    PrimitiveKind.box);
void closed(TriMesh m, double volume) {
  expect(m.validate(), isEmpty);
  expect(MeshTopology(m).boundaryEdges(), isEmpty);
  expect(MeshTopology(m).nonManifoldEdges(), isEmpty);
  expect(m.signedVolume(), closeTo(volume, .0001));
}

void main() {
  test(
      'selection edits preserve attributes and refuse changed boundaries or lost data',
      () {
    final source = cube(1)
      ..vertexColors = Float32List.fromList(List.generate(24, (i) => i / 24))
      ..faceGroups = Uint16List.fromList(List.generate(12, (i) => i));
    final mask = Uint8List(12)..[0] = 1;
    final edited = editSelection(source, mask, (patch) => patch.clone());
    closed(edited, 8);
    expect(edited.positions, source.positions);
    expect(edited.vertexColors, source.vertexColors);
    expect(edited.faceGroups, [...source.faceGroups!.skip(1), 0]);
    final all = editSelection(source, Uint8List.fromList(List.filled(12, 1)),
        (patch) => patch.clone());
    for (var v = 0; v < all.vertexCount; v++) {
      final original = List.generate(source.vertexCount, (i) => i).singleWhere(
          (i) =>
              source.vx(i) == all.vx(v) &&
              source.vy(i) == all.vy(v) &&
              source.vz(i) == all.vz(v));
      expect(all.vertexColors!.sublist(v * 3, v * 3 + 3),
          source.vertexColors!.sublist(original * 3, original * 3 + 3));
    }
    closed(all, 8);
    expect(
        editSelection(
                source, Uint8List(12), (_) => throw StateError('must not run'))
            .indices,
        source.indices);
    expect(() => editSelection(source, Uint8List(1), (p) => p),
        throwsArgumentError);
    expect(
        () => editSelection(
            source, mask, (p) => p..transform(translation4(.1, 0, 0))),
        throwsStateError);
    expect(() => editSelection(source, mask, (p) => p..vertexColors = null),
        throwsStateError);
    expect(() => editSelection(source, mask, (p) => p..faceGroups = null),
        throwsStateError);
    final coincident = Modify.combine([
      source.extractFaces([0]),
      source.extractFaces([0])
    ]);
    expect(
        () => editSelection(coincident, Uint8List.fromList([1, 1]), (p) => p),
        throwsStateError);
    closed(source, 8);
  });
  test(
      'fingerprints distinguish consumed textures, UVs, assignments and vertex colors',
      () async {
    final pixels = img.Image(width: 2, height: 2)
      ..clear(img.ColorRgb8(20, 30, 40));
    final mesh = cube(1)
      ..vertexColors = Float32List.fromList(List.filled(24, .5))
      ..cornerUvs = Float32List(72)
      ..faceMaterials = Uint16List(12)
      ..materials = [
        MeshMaterial(texture: TextureIO.decode(img.encodePng(pixels)))
      ];
    final hash = await meshFingerprint(mesh);
    expect(
        await meshFingerprint(ProjectIO.read(ProjectIO.write(
                ProjectData([SceneObject(1, 'textured', mesh)])))
            .objects
            .single
            .mesh),
        hash);
    final altered = mesh.clone()..cornerUvs![0] = .25;
    expect(await meshFingerprint(altered), isNot(hash));
    pixels.setPixelRgb(0, 0, 200, 30, 40);
    altered.cornerUvs = mesh.cornerUvs;
    altered.materials = [
      MeshMaterial(texture: TextureIO.decode(img.encodePng(pixels)))
    ];
    expect(await meshFingerprint(altered), isNot(hash));
    ProjectIO.checkBudget(ProjectData([SceneObject(1, 'textured', mesh)]));
  });
  test('nested cap handles multiple cavities, islands and oblique planes', () {
    final outer = cube(4);
    final first = Modify.flipNormals(cube(1));
    first.transform(translation4(-2, 0, 0));
    final second = Modify.flipNormals(cube(1));
    second.transform(translation4(2, 0, 0));
    final holes = Modify.combine([outer, first, second]);
    closed(PlaneCut.cut(holes, point: [0, 0, 0], normal: [0, 1, 0]), 248);
    final nested =
        Modify.combine([cube(4), Modify.flipNormals(cube(3)), cube(1)]);
    closed(PlaneCut.cut(nested, point: [0, 0, 0], normal: [0, 1, 0]), 152);
    closed(PlaneCut.cut(holes, point: [0, 0, 0], normal: [.2, 1, .3]), 248);
  });
  test('repair and bridge leave valid topology and identify inferred surfaces',
      () {
    final input = cube(1);
    final repaired = ScanRecipe.apply(input, ScanStep('repair', {'weldMm': 0}));
    closed(repaired.mesh, 8);
    final caps = input.extractFaces([0, 1, 2, 3]);
    expect(MeshTopology(caps).boundaryLoops(), hasLength(2));
    final bridge = ScanRecipe.apply(caps, ScanStep('bridgeHoles'));
    closed(bridge.mesh, 8);
    expect(bridge.inferredGroup, 1);
    expect(bridge.mesh.faceGroups!.where((v) => v == 1), hasLength(8));
    expect(bridge.note, contains('Inferred'));
    final trimmed = ScanRecipe.apply(input,
        ScanStep('trim', {'nx': 1, 'ny': 0, 'nz': 0, 'keepPositive': 0}));
    closed(trimmed.mesh, 4);
  });
  test('whole and regional remesh/reduce retain valid physical output', () {
    final input = cube(1);
    for (final step in [
      ScanStep('reduce', {'keepFraction': .9, 'deviationMm': 3}),
      ScanStep('remesh', {'edgeMm': 1, 'deviationMm': 3})
    ]) {
      final result = ScanRecipe.apply(input, step);
      expect(result.mesh.validate(), isEmpty);
      expect(MeshTopology(result.mesh).nonManifoldEdges(), isEmpty);
      expect(MeshTopology(result.mesh).boundaryEdges(), isEmpty);
      expect(result.mesh.signedVolume(), greaterThan(0));
      final mask = Uint8List(input.faceCount)..[0] = 1;
      final local = ScanRecipe.apply(input, step, selection: mask);
      closed(local.mesh, 8);
    }
  });
  test(
      'invalid settings, incomplete surfaces and budget exhaustion are explicit',
      () {
    final input = cube(1), empty = TriMesh.empty();
    for (final step in [
      ScanStep('repair', {'weldMm': -1}),
      ScanStep('reduce', {'keepFraction': 0}),
      ScanStep('reduce', {'keepFraction': 1, 'deviationMm': 0}),
      ScanStep('fillHole', {'smooth': 2}),
      ScanStep('bridgeHoles', {'first': 0, 'second': 0}),
      ScanStep('trim', {'keepPositive': 2}),
      ScanStep('denoise', {'iterations': 1.5}),
      ScanStep('denoise', {'creaseDegrees': 181})
    ]) {
      expect(() => ScanRecipe.apply(input, step), throwsArgumentError,
          reason: step.operation);
    }
    expect(() => ScanRecipe.apply(empty, ScanStep('repair')), throwsStateError);
    expect(() => ScanStep.fromJson({'operation': 'repair', 'unknown': 1}),
        throwsFormatException);
    expect(() => ScanRecipe([]), throwsArgumentError);
    expect(() => SurfaceDeviation.measure(empty, input), throwsStateError);
    expect(() => SurfaceDeviation.measure(input, input, maximumSamples: 2),
        throwsArgumentError);
    expect(SurfaceDeviation.measure(input, input, maximumSamples: 4).samples,
        lessThanOrEqualTo(4));
    expect(
        () => ScanWorkflow.fragments(input,
            maximumArea: 1, protectedFaces: Uint8List(1)),
        throwsArgumentError);
    expect(() => ScanWorkflow.inspect(input, fragmentArea: -1),
        throwsArgumentError);
    expect(() => PrintProfile.fromJson({'process': 'laser'}),
        throwsFormatException);
    expect(
        () => ScanWorkflow.inspect(input,
            profile: const PrintProfile(border: 101)),
        throwsArgumentError);
    expect(() => Decimator.reduce(input, percentage: double.nan),
        throwsArgumentError);
    expect(() => Decimator.reduce(input, percentage: 2), throwsArgumentError);
  });
  test(
      'project v1/v2 migration supplies defaults and v3 budget is checked before allocation',
      () {
    final p = ProjectData([SceneObject(1, 'scan', cube(1))],
        printProfile: const PrintProfile(width: 230));
    final entries = ZipArchive.read(ProjectIO.write(p));
    final manifest =
        jsonDecode(utf8.decode(entries.first.data)) as Map<String, dynamic>;
    manifest.remove('printProfile');
    for (final object in manifest['objects']) {
      object.remove('locked');
      object.remove('scanSourceId');
      object.remove('scanHistory');
    }
    for (final version in [1, 2]) {
      manifest['version'] = version;
      final old = ProjectIO.read(ZipArchive.write([
        ZipEntry('manifest.json',
            Uint8List.fromList(utf8.encode(jsonEncode(manifest)))),
        ...entries.skip(1)
      ]));
      expect(old.printProfile.width, 200);
      expect(old.objects.single.locked, isFalse);
      expect(old.objects.single.scanHistory, isEmpty);
      closed(old.objects.single.mesh, 8);
    }
    ProjectIO.checkBudget(p);
    final oneMiB = Uint8List(1024 * 1024);
    expect(
        () => ProjectIO.checkBudget(ProjectData(p.objects,
            sourceAttachments: List.generate(241,
                (i) => ProjectSourceAttachment(name: '$i', bytes: oneMiB)))),
        throwsFormatException);
    expect(
        () => ProjectIO.checkBudget(
            ProjectData(List.filled(1025, p.objects.single))),
        throwsFormatException);
    final hugeName = SceneObject(1, 'x' * 1500000, cube(1));
    expect(() => ProjectIO.checkBudget(ProjectData([hugeName])),
        throwsFormatException);
    final metadata = cube(1)
      ..vertexColors = Float32List(24)
      ..cornerUvs = Float32List(72)
      ..faceMaterials = Uint16List(12)
      ..faceGroups = Uint16List(12);
    expect(
        () => ProjectIO.checkBudget(ProjectData(
            List.generate(700, (i) => SceneObject(i + 1, 'part', metadata)))),
        throwsFormatException);
  });
}
