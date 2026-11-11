import 'dart:typed_data';
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';

TriMesh cube({double half = 1}) => TriMesh(
    Float32List.fromList([
      -1,
      -1,
      -1,
      1,
      -1,
      -1,
      1,
      1,
      -1,
      -1,
      1,
      -1,
      -1,
      -1,
      1,
      1,
      -1,
      1,
      1,
      1,
      1,
      -1,
      1,
      1
    ].map((v) => v * half).toList()),
    Uint32List.fromList([
      0,
      2,
      1,
      0,
      3,
      2,
      4,
      5,
      6,
      4,
      6,
      7,
      0,
      1,
      5,
      0,
      5,
      4,
      1,
      2,
      6,
      1,
      6,
      5,
      2,
      3,
      7,
      2,
      7,
      6,
      3,
      0,
      4,
      3,
      4,
      7
    ]));

List<MeshDefect> intersections(TriMesh m) =>
    MeshInspector.scan(m, checkSelfIntersections: true)
        .where((d) => d.kind == DefectKind.selfIntersection)
        .toList();

void main() {
  test(
      'intersection inspection finds crossing and coplanar triangles at multiple scales',
      () {
    for (final scale in [1e-6, 1.0, 1e6]) {
      final crossing = TriMesh(
          Float32List.fromList([
            -1.0,
            -1,
            0,
            1,
            -1,
            0,
            0,
            1,
            0,
            0,
            -.5,
            -1,
            0,
            -.5,
            1,
            0,
            .5,
            0
          ].map((x) => x * scale).toList()),
          Uint32List.fromList([0, 1, 2, 3, 4, 5]));
      expect(intersections(crossing), hasLength(1));
      final coplanar = TriMesh(
          Float32List.fromList([
            0.0,
            0,
            0,
            2,
            0,
            0,
            0,
            2,
            0,
            .2,
            .2,
            0,
            1,
            .2,
            0,
            .2,
            1,
            0
          ].map((x) => x * scale).toList()),
          Uint32List.fromList([0, 1, 2, 3, 4, 5]));
      expect(intersections(coplanar), hasLength(1));
      coplanar.positions[9] = 1.5 * scale;
      coplanar.positions[10] = 1.5 * scale;
      coplanar.positions[12] = 3 * scale;
      coplanar.positions[13] = 1.5 * scale;
      coplanar.positions[15] = 1.5 * scale;
      coplanar.positions[16] = 3 * scale;
      expect(intersections(coplanar), isEmpty);
      expect(intersections(cube(half: scale)), isEmpty);
    }
  });
  test(
      'split non-manifold edges and bowties preserves per-corner and vertex attributes',
      () {
    final m = TriMesh(
        Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -1, 0]),
        Uint32List.fromList([0, 1, 2, 1, 0, 3, 0, 1, 4]),
        vertexColors: Float32List.fromList(List.generate(15, (i) => i / 15)),
        faceGroups: Uint16List.fromList([4, 7, 9]),
        cornerUvs: Float32List(18));
    final result = MeshInspector.splitNonManifold(m);
    expect(MeshTopology(result).nonManifoldEdges(), isEmpty);
    expect(MeshTopology(result).nonManifoldVertices(), isEmpty);
    expect(result.faceGroups, m.faceGroups);
    expect(result.cornerUvs, m.cornerUvs);
    expect(result.faceCount, m.faceCount);
    for (var i = 0; i < m.indices.length; i++) {
      final a = m.indices[i], b = result.indices[i];
      expect(result.positions.sublist(b * 3, b * 3 + 3),
          m.positions.sublist(a * 3, a * 3 + 3));
      expect(result.vertexColors!.sublist(b * 3, b * 3 + 3),
          m.vertexColors!.sublist(a * 3, a * 3 + 3));
    }
    final valid = cube()
      ..faceGroups = Uint16List.fromList(List.filled(12, 7))
      ..vertexColors = Float32List(24);
    final unchanged = MeshInspector.splitNonManifold(valid);
    expect(unchanged.indices, valid.indices);
    expect(unchanged.faceGroups, valid.faceGroups);
    expect(unchanged.vertexColors, valid.vertexColors);
    expect(unchanged.signedVolume(), closeTo(8, 1e-8));
  });
  test('cut hollow shell creates an annulus with no cap inside the cavity', () {
    final inner = cube();
    for (var f = 0; f < inner.faceCount; f++) {
      inner.reverseFace(f);
    }
    final shell = Modify.combine([cube(half: 2), inner]);
    for (final positive in [true, false]) {
      final cut = PlaneCut.cut(shell,
          point: [0, 0, 0], normal: [0, 1, 0], keepPositive: positive);
      expect(MeshTopology(cut).boundaryEdges(), isEmpty);
      expect(MeshTopology(cut).nonManifoldEdges(), isEmpty);
      expect(cut.signedVolume(), closeTo(28, 1e-6));
      final hits = TriangleBVH.build(cut).raycastAll([.2, -.5, .1], [0, 1, 0]);
      if (positive) {
        expect(hits, hasLength(2));
        expect(hits[0], closeTo(1.5, 1e-6));
      }
      expect(intersections(cut), isEmpty);
    }
  });
  test('plane cut retains pre-existing holes away from cut plane', () {
    final m = cube().extractFaces([
      for (var f = 0; f < 12; f++)
        if (f != 8 && f != 9) f
    ]);
    final cut = PlaneCut.cut(m, point: [0, 0, 0], normal: [0, 1, 0]);
    expect(MeshTopology(cut).boundaryLoops(), hasLength(1));
  });
  test('packing enforces bed border and requested spacing at every quality',
      () {
    for (var quality = 0; quality < 4; quality++) {
      expect(Packer.pack([cube(half: 98.5)], quality: quality).unplaced, [0]);
      final meshes = [cube(half: 15), cube(half: 15), cube(half: 30)];
      final result =
          Packer.pack(meshes, spacing: 10, border: 3, quality: quality);
      expect(result.unplaced, isEmpty);
      final bounds = [
        for (final p in result.placed)
          (meshes[p.index].clone()
                ..transform(Float64List.fromList(p.transform)))
              .bounds()
      ];
      for (final b in bounds) {
        expect(b.minX, greaterThanOrEqualTo(3));
        expect(b.minZ, greaterThanOrEqualTo(3));
        expect(b.maxX, lessThanOrEqualTo(197));
        expect(b.maxZ, lessThanOrEqualTo(197));
        expect(b.minY, closeTo(0, 1e-7));
      }
      for (var i = 0; i < bounds.length; i++) {
        for (var j = i + 1; j < bounds.length; j++) {
          final a = bounds[i], b = bounds[j];
          expect(
              a.maxX + 10 <= b.minX ||
                  b.maxX + 10 <= a.minX ||
                  a.maxZ + 10 <= b.minZ ||
                  b.maxZ + 10 <= a.minZ,
              isTrue);
        }
      }
    }
    expect(() => Packer.pack([], spacing: -1), throwsArgumentError);
    expect(
        () => Packer.pack([], rotationStepDegrees: 1e-10), throwsArgumentError);
  });
  for (final remesh in [false, true]) {
    test(
        'selection ${remesh ? 'remesh' : 'reduce'} leaves second shell unchanged',
        () {
      final other = cube()..transform(translation4(5, 0, 0));
      final source = Modify.combine([cube(), other]);
      final mask =
          Uint8List.fromList([...List.filled(12, 1), ...List.filled(12, 0)]);
      final result = editSelection(
          source,
          mask,
          (patch) => remesh
              ? IsotropicRemesher.remesh(patch,
                  targetEdgeLength: .7, iterations: 2)
              : Decimator.reduce(patch, percentage: .5));
      final untouched = [
        for (var f = 0; f < result.faceCount; f++)
          if (result.vx(result.indices[f * 3]) > 3) f
      ];
      expect(untouched, hasLength(12));
      expect(result.extractFaces(untouched).signedVolume(), closeTo(8, 1e-6));
      expect(MeshTopology(result).boundaryEdges(), isEmpty);
      expect(MeshTopology(result).nonManifoldEdges(), isEmpty);
    });
  }
}
