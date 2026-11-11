import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';
import '../tool/corpus/analytic_meshes.dart';
import '../tool/validate_corpus.dart' as corpus;

void expectClosed(TriMesh mesh) {
  expect(mesh.validate(), isEmpty);
  final topo = MeshTopology(mesh);
  expect(topo.boundaryLoops(), isEmpty);
  expect(topo.nonManifoldEdges(), isEmpty);
  expect(consistentWinding(mesh), isTrue,
      reason: 'adjacent faces must have opposite edge winding');
}

void main() {
  test('boolean empty identity and disjoint cases are exact sets', () {
    final a = analyticCube();
    final b = analyticCube()..transform(translation4(10, 0, 0));
    for (final compute in [
      (TriMesh a, TriMesh b, BooleanOp op) =>
          PreciseBoolean.computeDetailed(a, b, op).mesh,
      (TriMesh a, TriMesh b, BooleanOp op) =>
          Solidifier.boolean(a, b, op, resolution: 32).mesh,
    ]) {
      expect(compute(a, b, BooleanOp.intersection).faceCount, 0);
      expect(compute(a, a.clone(), BooleanOp.difference).faceCount, 0);
      expect(compute(TriMesh.empty(), a, BooleanOp.difference).faceCount, 0);
      final union = compute(a, b, BooleanOp.union);
      expectClosed(union);
      expect(union.signedVolume(), closeTo(16, 1e-6));
      expect(MeshTopology(union).components().$2, 2);
      expect(
          compute(a, TriMesh.empty(), BooleanOp.difference).signedVolume(), 8);
    }
    expect(
        PreciseBoolean.computeDetailed(a, b, BooleanOp.intersection)
            .usedFallback,
        false);
  });
  test(
      'Fast Make Solid rejects minimum clearance incompatible with reprojection',
      () {
    expect(
        () => Solidifier.makeSolid(analyticCube(),
            minThickness: .5, mode: SolidMode.fast),
        throwsUnsupportedError);
    expect(() => Solidifier.makeSolid(analyticCube(), offset: double.nan),
        throwsArgumentError);
  });
  test(
      'affine transforms preserve orientation and reject invalid matrices atomically',
      () {
    final mesh = analyticCube();
    final m = identity4()
      ..[0] = -2
      ..[5] = 3
      ..[10] = .5;
    mesh.transform(m);
    expectClosed(mesh);
    expect(mesh.signedVolume(), closeTo(24, 1e-6));
    final before = mesh.positions.toList();
    for (final m in [
      Float64List(16),
      identity4()..[0] = double.nan,
      identity4()..[3] = .1,
      identity4()..[0] = 1e100
    ]) {
      expect(() => mesh.transform(m), throwsArgumentError);
      expect(mesh.positions, before);
    }
  });
  test(
      'seeded plane cuts preserve orientation and complementary volume at different scales',
      () {
    final rng = math.Random(813);
    for (final scale in [.001, 1.0, 1000.0]) {
      final mesh = analyticCube(scale: scale);
      for (var i = 0; i < 6; i++) {
        final point = [0.0, (rng.nextDouble() - .5) * scale, 0.0];
        final normal = [
          rng.nextDouble() + .1,
          rng.nextDouble() + .1,
          rng.nextDouble() + .1
        ];
        final a = PlaneCut.cut(mesh, point: point, normal: normal);
        final b = PlaneCut.cut(mesh,
            point: point, normal: normal, keepPositive: false);
        expectClosed(a);
        expectClosed(b);
        expect(a.signedVolume() + b.signedVolume(),
            closeTo(mesh.signedVolume(), math.pow(scale, 3) * 1e-4));
      }
    }
  });
  test('split combine extract weld and cut preserve color/group domains', () {
    final a = analyticCube()
      ..faceGroups = Uint16List.fromList(List.filled(12, 4))
      ..vertexColors = Float32List.fromList(List.filled(24, .25));
    final b = analyticCube()..transform(translation4(4, 0, 0));
    final combined = Modify.combine([a, b]);
    expect(combined.vertexColors!.length, combined.positions.length);
    expect(combined.vertexColors!.take(24), everyElement(.25));
    expect(combined.vertexColors!.skip(24), everyElement(1));
    expect(combined.faceGroups!.length, 24);
    for (final part in ShellSeparator.separate(combined)) {
      expect(part.vertexColors, isNotNull);
      expect(part.faceGroups, isNotNull);
      expectClosed(part);
    }
    expect(ComplexTools.extract(a, {0, 1}).vertexColors, everyElement(.25));
    final cut = PlaneCut.cut(a, point: [0, 0, 0], normal: [0, 1, 0]);
    expectClosed(cut);
    expect(cut.vertexColors, everyElement(.25));
    expect(cut.faceGroups!.length, cut.faceCount);
    final welded = Weld.weldVertices(combined, tolerance: .0001);
    expect(welded.faceGroups, combined.faceGroups);
    expect(welded.vertexColors, combined.vertexColors);
    final mirror = Mirror.mirror(a,
        point: [3, 0, 0], normal: [1, 0, 0], weldTolerance: .0001);
    expectClosed(mirror);
    expect(mirror.vertexColors, everyElement(.25));
    expect(mirror.faceGroups, everyElement(4));
    final extrude = Extruder.extrude(a,
        faceMask: Uint8List(12)
          ..[0] = 1
          ..[1] = 1,
        distance: .2);
    expectClosed(extrude);
    expect(extrude.vertexColors, everyElement(.25));
    expect(extrude.faceGroups, everyElement(4));
    final slices = PlaneCut.cut(a,
        point: [0, 0, 0],
        normal: [0, 1, 0],
        keepPositive: false,
        sliceBoth: true);
    expectClosed(slices);
    expect(slices.signedVolume(), closeTo(8, 1e-6));
    expect(slices.vertexColors, everyElement(.25));
    expect(slices.faceGroups!.length, slices.faceCount);
  });
  test(
      'welding uses distance and does not alias coordinates separated by hash period',
      () {
    final a = analyticCube(scale: .01),
        b = analyticCube(scale: .01)..transform(translation4(2097.152, 0, 0));
    final out = Weld.weldVertices(Modify.combine([a, b]), tolerance: .001);
    expectClosed(out);
    expect(MeshTopology(out).components().$2, 2);
    expect(out.vertexCount, 16);
    final m = TriMesh(
        Float32List.fromList([.49, 0, 0, .51, 0, 0, 0, 1, 0, 0, 0, 1]),
        Uint32List.fromList([0, 2, 3, 1, 3, 2]));
    expect(Weld.weldVertices(m, tolerance: .1).vertexCount, 3);
  });
  test(
      'seeded repair extrusion and sculpt retain closed topology and bounded volume',
      () {
    final rng = math.Random(44);
    for (var i = 0; i < 5; i++) {
      final mesh = analyticCube(scale: .5 + rng.nextDouble());
      final removed = mesh.extractFaces(List.generate(10, (f) => f));
      final repaired = HoleFiller.fill(removed);
      expectClosed(repaired);
      expect(repaired.signedVolume(),
          closeTo(mesh.signedVolume(), mesh.signedVolume() * 1e-5));
      final mask = Uint8List(12)
        ..[0] = 1
        ..[1] = 1;
      final extruded = Extruder.extrude(mesh,
          faceMask: mask, distance: .1, smoothBoundary: false);
      expectClosed(extruded);
      expect(extruded.signedVolume(), greaterThan(mesh.signedVolume()));
      final sculpt = Sculptor.apply(mesh,
          op: BrushOp.inflate,
          center: [0, 0, 0],
          radius: 10,
          strength: .01,
          refine: false);
      expectClosed(sculpt);
      expect((sculpt.signedVolume() - mesh.signedVolume()).abs(),
          lessThan(mesh.signedVolume() * .5));
    }
  });
  test('analytical corpus satisfies explicit geometry tolerances', () {
    final records = corpus.validateAnalyticalCorpus();
    expect(records.length, 22);
    for (final record in records) {
      expect(record['passed'], isTrue, reason: jsonEncode(record));
    }
  });
  test(
      'seeded reduction remeshing hollowing and grid booleans conserve expected material',
      () {
    final rng = math.Random(407);
    for (var i = 0; i < 3; i++) {
      final scale = .75 + rng.nextDouble();
      final cube = analyticCube(scale: scale);
      final dense = IsotropicRemesher.linearSubdivide(
          IsotropicRemesher.linearSubdivide(cube));
      final reduced =
          Decimator.reduce(dense, percentage: .4 + rng.nextDouble() * .2);
      expectClosed(reduced);
      expect(reduced.faceCount, lessThan(dense.faceCount));
      expect(reduced.signedVolume(),
          closeTo(cube.signedVolume(), cube.signedVolume() * .01));
      final remeshed = IsotropicRemesher.remesh(dense,
          targetEdgeLength: scale * (.35 + rng.nextDouble() * .15),
          iterations: 2,
          preserveSharp: true);
      expectClosed(remeshed);
      expect(remeshed.signedVolume(),
          closeTo(cube.signedVolume(), cube.signedVolume() * .05));
      final wall = scale * .25;
      final shell =
          Solidifier.hollow(cube, thickness: wall, holes: 0, resolution: 40)
              .mesh;
      expectClosed(shell);
      final material = 8 * (math.pow(scale, 3) - math.pow(scale - wall, 3));
      expect(shell.signedVolume(), closeTo(material, material * .08));
      final shift = scale * (.5 + rng.nextDouble());
      final other = cube.clone()..transform(translation4(shift, 0, 0));
      final intersection = Solidifier.boolean(
              cube, other, BooleanOp.intersection,
              resolution: 40)
          .mesh;
      final difference =
          Solidifier.boolean(cube, other, BooleanOp.difference, resolution: 40)
              .mesh;
      expectClosed(intersection);
      expectClosed(difference);
      expect(intersection.signedVolume() + difference.signedVolume(),
          closeTo(cube.signedVolume(), cube.signedVolume() * .05));
    }
  });
  test('ray queries and solidification remain proportional at tiny scales', () {
    for (final scale in [1e-9, 1e-6, 1.0, 1e6]) {
      final cube = analyticCube(scale: scale);
      final bvh = TriangleBVH.build(cube);
      for (final speed in [1e-8, 1.0, 1e8]) {
        final hit = bvh.raycast([3 * scale, 0, 0], [-speed, 0, 0]);
        expect(hit, isNotNull);
        expect(hit!.point[0], closeTo(scale, scale * 1e-5));
      }
      final solid = Solidifier.makeSolid(cube, resolution: 24).mesh;
      expectClosed(solid);
      expect(solid.signedVolume() / cube.signedVolume(), closeTo(1, .03));
    }
  });
  test('subdivision reduction and remeshing interpolate RGB and retain groups',
      () {
    final cube = analyticCube()
      ..faceGroups = Uint16List.fromList(List.generate(12, (f) => f ~/ 2))
      ..vertexColors = Float32List.fromList([
        for (final coordinate in analyticCube().positions)
          (coordinate + 1) * .5,
      ]);
    final subdivided = IsotropicRemesher.linearSubdivide(cube);
    final reduced = Decimator.reduce(subdivided, percentage: .75);
    final remeshed = IsotropicRemesher.remesh(subdivided,
        targetEdgeLength: .6, iterations: 2, preserveSharp: true);
    for (final result in [subdivided, reduced, remeshed]) {
      expectClosed(result);
      expect(result.vertexColors!.length, result.positions.length);
      expect(result.faceGroups!.length, result.faceCount);
      expect(result.faceGroups, everyElement(inInclusiveRange(0, 5)));
      for (var k = 0; k < result.positions.length; k++) {
        expect(result.vertexColors![k],
            closeTo((result.positions[k] + 1) * .5, 1e-5));
      }
    }
  });
  test('geometry growth budgets reject products before allocating output', () {
    final cube = analyticCube();
    expect(() => Modify.makePattern(cube, countX: 1 << 62, countZ: 1 << 62),
        throwsStateError);
    expect(() => Modify.makePattern(cube, countX: -1), throwsArgumentError);
    expect(
        () => Modify.makePattern(cube, maximumFaces: 0), throwsArgumentError);
    expect(() => IsotropicRemesher.linearSubdivide(cube, maximumFaces: 47),
        throwsStateError);
    expect(() => IsotropicRemesher.remesh(cube, targetEdgeLength: 1e-100),
        throwsStateError);
    expect(() => IsotropicRemesher.remesh(cube, targetEdgeLength: double.nan),
        throwsArgumentError);
    expect(
        () => IsotropicRemesher.remesh(cube,
            targetEdgeLength: 1, maximumFaces: 11),
        throwsStateError);
    final repeated = Modify.makePattern(cube, countX: 2, maximumFaces: 24);
    expectClosed(repeated);
    expect(repeated.faceCount, 24);
    expect(IsotropicRemesher.linearSubdivide(cube, maximumFaces: 48).faceCount,
        48);
  });
  test('large reduction keeps topology after float32 output quantization', () {
    final sphere = MeshIO.readBytes('sphere.obj',
        File('test/fixtures/models/sphere.obj').readAsBytesSync());
    final subdivided = IsotropicRemesher.linearSubdivide(
        IsotropicRemesher.linearSubdivide(sphere));
    final large = Decimator.reduce(subdivided, targetFaceCount: 100000);
    final reduced = Decimator.reduce(large, percentage: .5);
    for (final mesh in [large, reduced]) {
      expectClosed(mesh);
      final topology = MeshTopology(mesh);
      expect(topology.nonManifoldVertices(), isEmpty);
      expect(mesh.vertexCount - topology.edgeFaces.length + mesh.faceCount, 2,
          reason: 'sphere Euler characteristic must survive reduction');
      expect(mesh.signedVolume(),
          closeTo(sphere.signedVolume(), sphere.signedVolume() * .001));
      // Checking the actual float32 output must not discover hidden faces
      // that a late cleanup could delete and turn into holes.
      expect(mesh.clone().removeDegenerateFaces(minArea: 0), 0);
    }
    expect(large.faceCount, lessThanOrEqualTo(100000));
    expect(reduced.faceCount, lessThanOrEqualTo(50000));
  });
  test('reference corpus honors provenance, tolerances and topology', () {
    final directory = Directory.systemTemp.createTempSync('mmx-corpus-');
    addTearDown(() => directory.deleteSync(recursive: true));
    void writeMesh(String name, TriMesh mesh) => File('${directory.path}/$name')
        .writeAsBytesSync(MeshIO.writeBytes(name, mesh));
    writeMesh('input.obj', analyticCube());
    writeMesh('operand.obj', TriMesh.empty());
    writeMesh('reference.obj', analyticCube());
    final manifest = File('${directory.path}/manifest.json');
    final document = <String, Object>{
      'schema': 1,
      'source': 'Synthetic test of runner; not external oracle evidence',
      'cases': [
        {
          'name': 'identity',
          'operation': 'boolean',
          'input': 'input.obj',
          'operand': 'operand.obj',
          'reference': 'reference.obj',
          'parameters': {'op': 'union', 'resolution': 32},
          'tolerances': {
            'volumeAbsolute': 0,
            'areaAbsolute': 0,
            'surfaceDistance': 0
          },
        }
      ],
    };
    manifest.writeAsStringSync(jsonEncode(document));
    final initial = corpus.validateReferenceCorpus(manifest).single;
    expect(initial['passed'], isTrue);
    expect(initial['manifestSha256'],
        sha256.convert(manifest.readAsBytesSync()).toString());
    expect(initial['operation'], 'boolean');
    expect(initial['parameters'], {'op': 'union', 'resolution': 32});
    for (final name in ['input', 'operand', 'reference']) {
      expect(initial[name], '$name.obj');
      expect(
          initial['${name}Sha256'],
          sha256
              .convert(File('${directory.path}/$name.obj').readAsBytesSync())
              .toString());
    }
    writeMesh('reference.obj', analyticCube(scale: .5));
    final changed = corpus.validateReferenceCorpus(manifest).single;
    expect(changed['passed'], isFalse);
    expect(changed['referenceSha256'], isNot(initial['referenceSha256']));
    expect(changed['manifestSha256'], initial['manifestSha256']);
    expect(changed['inputSha256'], initial['inputSha256']);
    document['source'] = '';
    manifest.writeAsStringSync(jsonEncode(document));
    expect(
        () => corpus.validateReferenceCorpus(manifest), throwsFormatException);
  });
}
