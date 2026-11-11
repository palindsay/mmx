import 'dart:typed_data';
import 'dart:io';
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';
import '../tool/corpus/analytic_meshes.dart';

TriMesh thinPatch() {
  final grid = [-1.0, .67, .70, 1.0];
  final positions = <double>[];
  for (var layer = 0; layer < 2; layer++) {
    for (var z = 0; z < 4; z++) {
      for (var x = 0; x < 4; x++) {
        positions.addAll([
          grid[x],
          layer == 0 ? 0.0 : (x == 1 && z == 1 ? .02 : .4),
          grid[z]
        ]);
      }
    }
  }
  final indices = <int>[];
  void quad(int a, int b, int c, int d) {
    indices.addAll([a, b, c, a, c, d]);
  }

  for (var z = 0; z < 3; z++) {
    for (var x = 0; x < 3; x++) {
      final a = z * 4 + x, b = a + 1, c = a + 5, d = a + 4;
      quad(a, b, c, d);
      quad(a + 16, d + 16, c + 16, b + 16);
    }
  }
  for (var x = 0; x < 3; x++) {
    quad(x, x + 16, x + 17, x + 1);
    quad(12 + x, 13 + x, 29 + x, 28 + x);
  }
  for (var z = 0; z < 3; z++) {
    quad(z * 4, z * 4 + 4, z * 4 + 20, z * 4 + 16);
    quad(z * 4 + 3, z * 4 + 19, z * 4 + 23, z * 4 + 7);
  }
  return TriMesh(Float32List.fromList(positions), Uint32List.fromList(indices));
}

void main() {
  test(
      'continuous box clearance is scale invariant and reports threshold uncertainty',
      () {
    for (final scale in [.001, 1.0, 1000.0]) {
      final cube = analyticCube(scale: scale);
      final passed = WallThickness.certify(cube, scale * 1.9);
      expect(passed.passed, isTrue, reason: passed.diagnostic);
      expect(passed.verifiedLowerBound, scale * 1.9);
      final failed = WallThickness.certify(cube, scale * 2.1);
      expect(failed.status, WallClearanceStatus.violated);
      expect(failed.witnessClearance, closeTo(scale * 2, scale * 1e-6));
      expect(failed.witnessPoint, isNotNull);
      expect(
          WallThickness.certify(cube, cube.bounds().extentX).passed, isFalse);
    }
  });
  test('a narrow off-centre thin region cannot hide between ray samples', () {
    final mesh = thinPatch();
    expect(MeshTopology(mesh).boundaryEdges(), isEmpty);
    expect(mesh.signedVolume(), greaterThan(0));
    final certificate = WallThickness.certify(mesh, .1);
    expect(certificate.status, WallClearanceStatus.violated,
        reason: certificate.diagnostic);
    expect(certificate.witnessClearance, lessThan(.1));
  });
  test('cavity orientation is checked and external gaps are not wall material',
      () {
    final outer = analyticCube(),
        inner = Modify.flipNormals(analyticCube(scale: .8));
    final hollow = Modify.combine([outer, inner]);
    final good = WallThickness.certify(hollow, .15);
    expect(good.passed, isTrue, reason: good.diagnostic);
    expect(WallThickness.certify(hollow, .25).status,
        WallClearanceStatus.violated);
    final wrong = Modify.combine([outer, analyticCube(scale: .8)]);
    expect(WallThickness.certify(wrong, .15).status,
        WallClearanceStatus.indeterminate);
    final nearby = analyticCube()..transform(translation4(2.01, 0, 0));
    expect(WallThickness.certify(Modify.combine([outer, nearby]), .1).passed,
        isTrue);
  });
  test('invalid, inverted, degenerate and over-budget surfaces cannot certify',
      () {
    final cube = analyticCube();
    expect(
        WallThickness.certify(cube.extractFaces([0, 1]), .1).passed, isFalse);
    expect(WallThickness.certify(Modify.flipNormals(cube), .1).diagnostic,
        contains('winding'));
    final degenerate = cube.clone();
    degenerate.positions.setRange(0, 3, degenerate.positions.sublist(3, 6));
    expect(WallThickness.certify(degenerate, .1).diagnostic,
        contains('Degenerate'));
    expect(WallThickness.certify(cube, .1, maxCandidatePairs: 1).diagnostic,
        contains('candidate pairs'));
    expect(WallThickness.certify(cube, .1, maxFaces: 4).passed, isFalse);
    expect(() => WallThickness.certify(cube, double.nan), throwsArgumentError);
    expect(() => WallThickness.certify(cube, .1, maxCandidatePairs: 0),
        throwsArgumentError);
  });
  test('manifold, winding, conditioning and shell-count guards explain failure',
      () {
    final cube = analyticCube();
    expect(
        WallThickness.certify(
                cube.extractFaces(List.generate(11, (i) => i)), .1)
            .diagnostic,
        contains('closed edge/vertex manifold'));
    final inconsistent = cube.clone();
    final swap = inconsistent.indices[0];
    inconsistent.indices[0] = inconsistent.indices[1];
    inconsistent.indices[1] = swap;
    expect(WallThickness.certify(inconsistent, .1).diagnostic,
        contains('consistent face winding'));
    final translated = cube.clone()..transform(translation4(1e6, 1e6, 1e6));
    expect(WallThickness.certify(translated, 1e-6).diagnostic,
        contains('conditioning'));
    expect(WallThickness.certify(translated, .1).passed, isTrue);
    final shells = Modify.combine([
      for (var i = 0; i < 65; i++)
        analyticCube()..transform(translation4(i * 4.0, 0, 0)),
    ]);
    expect(WallThickness.certify(shells, .1).diagnostic,
        contains('at most 64 closed shells'));
    final touching = Modify.combine([
      cube,
      analyticCube()..transform(translation4(1 / 3, -1 / 3, 0)),
    ]);
    expect(WallThickness.certify(touching, .1).diagnostic,
        contains('Touching/ambiguous'));
  });
  test('sharp tetrahedral tips conservatively have zero normal clearance', () {
    final tetra = TriMesh(
        Float32List.fromList([1, 1, 1, -1, -1, 1, -1, 1, -1, 1, -1, -1]),
        Uint32List.fromList([0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]));
    final mesh = tetra.signedVolume() > 0 ? tetra : Modify.flipNormals(tetra);
    final certificate = WallThickness.certify(mesh, .01);
    expect(certificate.status, WallClearanceStatus.violated,
        reason: certificate.diagnostic);
    expect(certificate.witnessClearance, closeTo(0, 1e-8));
  });

  test('normals at the tangent cutoff produce uncertainty, never a false pass',
      () {
    TriMesh nearTangent(double rise, {double height = 2}) {
      final mesh = analyticCube();
      for (var v = 0; v < mesh.vertexCount; v++) {
        final top = mesh.vy(v) > 0;
        mesh.positions[v * 3 + 1] = top ? height : 0;
        mesh.positions[v * 3] += 1;
        if (mesh.positions[v * 3] == 0) {
          mesh.positions[v * 3] = top ? rise : 0;
        }
      }
      return mesh;
    }

    expect(WallThickness.certify(nearTangent(1e-4), .1).passed, isTrue);
    // These exactly representable Float32 coordinates place the unit normal
    // dot product within 4e-18 of the documented -1e-4 metric cutoff.
    final uncertain = WallThickness.certify(
        nearTangent(0.00020023567776661366, height: 2.002356767654419), .1);
    expect(uncertain.status, WallClearanceStatus.indeterminate);
    expect(uncertain.diagnostic, contains('tangent cutoff'));
    expect(WallThickness.certify(nearTangent(4e-4), .1).status,
        WallClearanceStatus.violated);
  });

  test('Float32 rotated and nonuniformly scaled boxes retain useful clearance',
      () {
    for (final radians in [.1, .5, 1.7, 3.1]) {
      for (final scaled in [false, true]) {
        final box = analyticCube();
        if (scaled) {
          for (var v = 0; v < box.vertexCount; v++) {
            box.positions[v * 3] *= 2;
            box.positions[v * 3 + 1] *= .5;
            box.positions[v * 3 + 2] *= 3;
          }
        }
        box.transform(rotation4(1, 2, 3, radians));
        final certificate = WallThickness.certify(box, .8);
        expect(certificate.passed, isTrue,
            reason:
                'rotation=$radians, scaled=$scaled: ${certificate.diagnostic}');
        expect(WallThickness.certify(box, scaled ? 1.1 : 2.1).passed, isFalse);
      }
    }
  });

  test('unused vertices cannot bypass the verifier allocation budget', () {
    final cube = analyticCube();
    final positions = Float32List(10000 * 3)
      ..setRange(0, cube.positions.length, cube.positions);
    final bloated = TriMesh(positions, Uint32List.fromList(cube.indices));
    expect(bloated.validate(), isEmpty);
    final certificate = WallThickness.certify(bloated, .1, maxFaces: 12);
    expect(certificate.status, WallClearanceStatus.indeterminate);
    expect(certificate.candidatePairs, 0);
    expect(certificate.diagnostic, contains('36-vertex budget'));
    bloated.compact();
    expect(WallThickness.certify(bloated, .1, maxFaces: 12).passed, isTrue);
  });

  test('near-edge overlapping projections preserve a thin-region witness', () {
    final mesh = thinPatch();
    // Put the thin patch within 10^-7 of its neighboring grid boundary.
    for (var v = 0; v < mesh.vertexCount; v++) {
      if ((mesh.vx(v) - .70).abs() < 1e-5) mesh.positions[v * 3] = .6700001;
      if ((mesh.vz(v) - .70).abs() < 1e-5) mesh.positions[v * 3 + 2] = .6700001;
    }
    expect(WallThickness.certify(mesh, .1).passed, isFalse);
  });

  void expectClosed(TriMesh mesh) {
    expect(mesh.validate(), isEmpty);
    final topology = MeshTopology(mesh);
    expect(topology.boundaryEdges(), isEmpty);
    expect(topology.nonManifoldEdges(), isEmpty);
    expect(topology.nonManifoldVertices(), isEmpty);
    expect(consistentWinding(mesh), isTrue);
    expect(mesh.signedVolume(), greaterThan(0));
  }

  test('positive offset never creates a phantom shell on the grid boundary',
      () {
    final slab = analyticCube();
    for (var v = 0; v < slab.vertexCount; v++) {
      slab.positions[v * 3 + 1] *= .1;
    }
    final result = Solidifier.makeSolid(slab, offset: .1, resolution: 32);
    final output =
        Weld.weldVertices(result.mesh, tolerance: result.cellSize * 1e-6);
    expectClosed(output);
    expect(MeshTopology(output).components().$2, 1);
    final bounds = output.bounds();
    expect(bounds.minX, closeTo(-1.1, 1e-6));
    expect(bounds.maxX, closeTo(1.1, 1e-6));
    expect(bounds.extentY, closeTo(.4, 1e-6));
    expect(output.signedVolume(), inExclusiveRange(slab.signedVolume(), 2));
  });

  test(
      'Make Solid grows a thin slab within its explicit bound and certifies final output',
      () {
    for (final scale in [.01, 1.0, 100.0]) {
      final slab = analyticCube(scale: scale);
      for (var v = 0; v < slab.vertexCount; v++) {
        slab.positions[v * 3 + 1] *= .1;
      }
      final original = Float32List.fromList(slab.positions);
      final result = Solidifier.makeSolid(slab,
          minThickness: .3 * scale,
          resolution: 32,
          maxAdditionalOffset: .3 * scale);
      expectClosed(result.mesh);
      expect(result.thicknessAttempts, greaterThan(1));
      expect(result.thicknessAttempts, lessThanOrEqualTo(6));
      expect(result.appliedOffset, inExclusiveRange(0, .3 * scale));
      expect(result.wallCertificate!.passed, isTrue);
      expect(WallThickness.certify(result.mesh, .3 * scale).passed, isTrue);
      expect(result.mesh.signedVolume(),
          inExclusiveRange(slab.signedVolume(), 4 * scale * scale * scale));
      expect(slab.positions, original);
    }
  });

  test(
      'Make Solid supports rounded boxes and spheres without unnecessary growth',
      () {
    final sphere = MeshIO.readBytes('sphere.obj',
        File('test/fixtures/models/sphere.obj').readAsBytesSync());
    for (final (mesh, minimum, mode) in [
      (analyticCube(), .2, SolidMode.accurate),
      (analyticCube(), .2, SolidMode.blocky),
      (sphere, 3.0, SolidMode.accurate),
    ]) {
      final result = Solidifier.makeSolid(mesh,
          minThickness: minimum, mode: mode, resolution: 24);
      expectClosed(result.mesh);
      expect(result.thicknessAttempts, 1);
      expect(result.appliedOffset, 0);
      expect(result.wallCertificate!.verifiedLowerBound, minimum);
      expect(result.mesh.signedVolume(),
          closeTo(mesh.signedVolume(), mesh.signedVolume() * .05));
    }
  });

  test(
      'Hollow grows an enclosed wall, preserves its cavity and verifies the final mesh',
      () {
    final mesh = analyticCube();
    final result = Solidifier.hollow(mesh,
        thickness: .1, minThickness: .2, holes: 0, resolution: 24);
    expectClosed(result.mesh);
    expect(result.appliedShellThickness, inInclusiveRange(.2, .4));
    expect(result.thicknessAttempts, greaterThan(1));
    expect(result.wallCertificate!.passed, isTrue);
    expect(WallThickness.certify(result.mesh, .2).passed, isTrue);
    expect(MeshTopology(result.mesh).components().$2, 2);
    expect(result.mesh.signedVolume(), lessThan(mesh.signedVolume()));
  });

  test(
      'Hollow growth is bounded from the requested thickness, including zero growth',
      () {
    final cube = analyticCube();
    expect(
        () => Solidifier.hollow(cube,
            thickness: .1,
            minThickness: .3,
            holes: 0,
            resolution: 24,
            maxAdditionalThickness: 0),
        throwsStateError);
    expect(
        () => Solidifier.hollow(cube,
            thickness: .1,
            minThickness: .3,
            holes: 0,
            resolution: 24,
            maxAdditionalThickness: .1),
        throwsStateError);
    final result = Solidifier.hollow(cube,
        thickness: .1,
        minThickness: .3,
        holes: 0,
        resolution: 24,
        maxAdditionalThickness: .2);
    expect(result.wallCertificate!.passed, isTrue);
    expect(result.appliedShellThickness, lessThanOrEqualTo(.1 + .2));
    expect(result.appliedShellThickness, closeTo(.3, 1e-12));
    expectClosed(result.mesh);
    final noGrowth = Solidifier.hollow(cube,
        thickness: .4,
        minThickness: .2,
        holes: 0,
        resolution: 24,
        maxAdditionalThickness: 0);
    expect(noGrowth.wallCertificate!.passed, isTrue);
    expect(noGrowth.appliedShellThickness, .4);
  });

  test(
      'bounded solvers fail explicitly for unsupported, unresolved and exhausted requests',
      () {
    final cube = analyticCube();
    expect(
        () =>
            Solidifier.makeSolid(cube, mode: SolidMode.fast, minThickness: .2),
        throwsUnsupportedError);
    expect(
        () => Solidifier.makeSolid(cube,
            minThickness: 3, resolution: 24, maxAdditionalOffset: 0),
        throwsStateError);
    expect(
        () => Solidifier.makeSolid(cube,
            minThickness: .2, resolution: 24, maxThicknessCandidatePairs: 1),
        throwsStateError);
    expect(
        () => Solidifier.makeSolid(cube,
            minThickness: .2, maxThicknessAttempts: 0),
        throwsArgumentError);
    expect(
        () => Solidifier.makeSolid(cube,
            minThickness: .2, maxAdditionalOffset: double.infinity),
        throwsArgumentError);
    expect(() => Solidifier.hollow(cube, minThickness: .2),
        throwsUnsupportedError);
    expect(
        () =>
            Solidifier.hollow(cube, minThickness: .2, holes: 0, openTop: true),
        throwsUnsupportedError);
    expect(
        () =>
            Solidifier.hollow(cube, minThickness: 3, holes: 0, resolution: 24),
        throwsStateError);
    expect(
        () => Solidifier.hollow(cube,
            thickness: .2,
            minThickness: .2,
            holes: 0,
            resolution: 24,
            maxAdditionalThickness: 0),
        throwsStateError);
    expect(
        () => Solidifier.hollow(cube,
            thickness: .2,
            minThickness: .2,
            holes: 0,
            resolution: 24,
            maxThicknessCandidatePairs: 1),
        throwsStateError);
  });
}
