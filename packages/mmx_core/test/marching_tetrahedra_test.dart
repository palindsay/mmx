import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_core/src/solid/marching_tetrahedra.dart';
import 'package:test/test.dart';

import '../tool/corpus/analytic_meshes.dart';

VoxelGrid sampleField(double Function(double, double, double) field,
    {int intervals = 16}) {
  final cell = 2.4 / intervals;
  final grid = VoxelGrid(
      intervals + 1, intervals + 1, intervals + 1, cell, -1.2, -1.2, -1.2);
  for (var x = 0; x < grid.nx; x++) {
    for (var y = 0; y < grid.ny; y++) {
      for (var z = 0; z < grid.nz; z++) {
        final value = field(-1.2 + x * cell, -1.2 + y * cell, -1.2 + z * cell);
        grid.values[grid.index(x, y, z)] = value.abs() < 1e-12 ? 0 : value;
      }
    }
  }
  return grid;
}

void expectClosed(TriMesh mesh) {
  expect(mesh.validate(), isEmpty);
  final topology = MeshTopology(mesh);
  expect(topology.boundaryEdges(), isEmpty);
  expect(topology.nonManifoldEdges(), isEmpty);
  expect(topology.nonManifoldVertices(), isEmpty);
  expect(consistentWinding(mesh), isTrue);
  expect(mesh.signedVolume(), greaterThan(0));
}

TriMesh transformedBox() => Modify.fitPrimitive(
    TriMesh(Float32List.fromList([-2, -2, -2, 2, 2, 2]), Uint32List(0)),
    PrimitiveKind.box)
  ..transform(multiply4(
      translation4(2, 3, 4),
      multiply4(
          rotation4(1, 2, 3, .7),
          identity4()
            ..[0] = 1.5
            ..[5] = .25
            ..[10] = .75)));

void main() {
  test(
      'tetrahedral sphere is closed, consistently wound and analytically accurate',
      () {
    final grid =
        sampleField((x, y, z) => math.sqrt(x * x + y * y + z * z) - .7);
    final mesh = MarchingTetrahedra.polygonize(grid);
    expectClosed(mesh);
    final volume = 4 * math.pi * .7 * .7 * .7 / 3;
    expect(mesh.signedVolume(), closeTo(volume, volume * .035));
    expect(MeshTopology(mesh).components().$2, 1);
  });

  test('zero lattice nodes share one vertex and preserve box topology', () {
    final grid = sampleField(
        (x, y, z) => math.max(x.abs(), math.max(y.abs(), z.abs())) - .6);
    expect(grid.values.where((v) => v == 0), isNotEmpty);
    final mesh = MarchingTetrahedra.polygonize(grid);
    expectClosed(mesh);
    final certificate = WallThickness.certify(mesh, .2);
    expect(certificate.passed, isTrue, reason: certificate.diagnostic);
    // Piecewise-linear interpolation bevels nonsmooth SDF corners. Refinement
    // must converge toward the analytic cube volume, rather than claim exact
    // corner recovery from a coarse sampled distance field.
    final fine = MarchingTetrahedra.polygonize(sampleField(
        (x, y, z) => math.max(x.abs(), math.max(y.abs(), z.abs())) - .6,
        intervals: 32));
    expectClosed(fine);
    const volume = 1.2 * 1.2 * 1.2;
    expect(fine.signedVolume(), closeTo(volume, .02));
    expect((volume - fine.signedVolume()).abs(),
        lessThan((volume - mesh.signedVolume()).abs() / 3));
  });

  test('empty, invalid and excessive output requests are bounded explicitly',
      () {
    final grid = sampleField((x, y, z) => 1);
    expect(MarchingTetrahedra.polygonize(grid).faceCount, 0);
    expect(() => MarchingTetrahedra.polygonize(grid, maximumFaces: 0),
        throwsArgumentError);
    grid.values[grid.index(8, 8, 8)] = -1;
    expect(() => MarchingTetrahedra.polygonize(grid, maximumFaces: 1),
        throwsStateError);
    expect(
        () => SurfaceNets.polygonize(grid, maximumFaces: 1), throwsStateError);
    expect(() => SurfaceNets.polygonize(grid, maximumFaces: 0),
        throwsArgumentError);
    grid.values[0] = double.nan;
    expect(() => MarchingTetrahedra.polygonize(grid), throwsArgumentError);
  });

  test(
      'verified rotated nonuniform box uses same-grid fallback and bounded growth',
      () {
    final input = transformedBox();
    final original = Float32List.fromList(input.positions);
    final ordinary = Solidifier.makeSolid(input, resolution: 32);
    expect(ordinary.reconstruction, 'surface-nets');
    expect(ordinary.reconstructionDiagnostic, isNull);
    // Reproduces the actual ambiguity: ordinary surface nets collapses four
    // incident sheets onto one edge even though voxel signs are correct.
    expect(MeshTopology(ordinary.mesh).nonManifoldEdges(), isNotEmpty);
    final verified = Solidifier.makeSolid(input,
        resolution: 32, minThickness: 1.2, maxAdditionalOffset: .4);
    expect(verified.gridResolution, ordinary.gridResolution);
    expect(verified.cellSize, ordinary.cellSize);
    expect(verified.reconstruction, 'marching-tetrahedra');
    expect(verified.reconstructionDiagnostic, contains('same SDF grid'));
    expect(verified.appliedOffset, inExclusiveRange(0, .4));
    expect(verified.thicknessAttempts, 2);
    expect(verified.wallCertificate!.passed, isTrue);
    expect(WallThickness.certify(verified.mesh, 1.2).passed, isTrue);
    expectClosed(verified.mesh);
    final initialVolume = input.signedVolume().abs();
    expect(verified.mesh.signedVolume(),
        inExclusiveRange(initialVolume, initialVolume * 2.5));
    expect(input.positions, original);
  });
}
