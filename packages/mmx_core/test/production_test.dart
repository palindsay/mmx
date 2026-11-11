import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';

TriMesh triangle() => TriMesh(Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
    Uint32List.fromList([0, 1, 2]),
    faceGroups: Uint16List.fromList([7]), vertexColors: Float32List(9));

void main() {
  test('truncated STL and invalid OBJ indices are rejected', () {
    final stl = StlIO.writeBinary(triangle());
    expect(
        () => MeshIO.readBytes(
            'a.stl', Uint8List.sublistView(stl, 0, stl.length - 1)),
        throwsFormatException);
    for (final index in [0, 9, -9]) {
      expect(() => ObjIO.read('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 $index'),
          throwsFormatException);
    }
  });
  test('degenerate face removal preserves corresponding groups', () {
    final m = triangle()
      ..indices = Uint32List.fromList([0, 0, 1, 0, 1, 2])
      ..faceGroups = Uint16List.fromList([10, 20]);
    m.removeDegenerateFaces();
    expect(m.faceGroups, [20]);
    expect(m.validate(), isEmpty);
  });
  test('voxel allocation rejects invalid and oversized requests', () {
    expect(
        () => VoxelGrid(10000, 10000, 10000, 1, 0, 0, 0), throwsArgumentError);
    expect(() => VoxelGrid(8, 8, 8, double.nan, 0, 0, 0), throwsArgumentError);
  });
  test('minimum hollow thickness changes the measured shell separation', () {
    final mesh = MeshIO.readBytes('sphere.obj',
        File('test/fixtures/models/sphere.obj').readAsBytesSync());
    final requested = mesh.bounds().extentX * .08;
    final result = Solidifier.hollow(mesh,
        thickness: requested / 2,
        minThickness: requested,
        holes: 0,
        resolution: 64);
    final shells = ShellSeparator.separate(result.mesh);
    expect(shells.length, 2);
    final widths = shells.map((m) => m.bounds().extentX).toList()..sort();
    expect(
        (widths[1] - widths[0]) / 2, closeTo(requested, result.cellSize * 2));
    expect(MeshTopology(result.mesh).nonManifoldEdges(), isEmpty);
    expect(MeshTopology(result.mesh).boundaryLoops(), isEmpty);
  });
  test('project preserves scene, pivot, attributes and camera', () {
    final d = Document();
    final a = d.add(triangle(), name: 'a & b')
      ..transform = translation4(2, 3, 4)
      ..visible = false
      ..isTarget = true
      ..pivot = Pivot.atPoint([1, 2, 3]);
    d.add(triangle(), name: 'second');
    final data = ProjectIO.read(ProjectIO.write(
        ProjectData(d.objects, selectedId: a.id, camera: Camera(yaw: 1.2))));
    expect(data.objects.length, 2);
    final o = data.objects.first;
    expect(o.name, 'a & b');
    expect(o.transform, a.transform);
    expect(o.visible, false);
    expect(o.isTarget, true);
    expect(o.pivot!.position, [1, 2, 3]);
    expect(o.mesh.faceGroups, [7]);
    expect(o.mesh.vertexColors, a.mesh.vertexColors);
    expect(data.camera.yaw, 1.2);
    expect(data.selectedId, a.id);
    d.replaceObjects(data.objects);
    expect(d.add(triangle()).id, 3);
  });
  test('project rejects future versions and malformed buffers', () {
    final entries = ZipArchive.read(
        ProjectIO.write(ProjectData([SceneObject(1, 'test', triangle())])));
    final manifest =
        jsonDecode(utf8.decode(entries.first.data)) as Map<String, dynamic>;
    manifest['version'] = 4;
    entries[0] = ZipEntry(
        'manifest.json', Uint8List.fromList(utf8.encode(jsonEncode(manifest))));
    expect(
        () => ProjectIO.read(ZipArchive.write(entries)), throwsFormatException);
    expect(() => ProjectIO.read(Uint8List(0)), throwsFormatException);
  });
  test('undo deep copies pivots and counts all buffers', () {
    final d = Document();
    final o = d.add(triangle())..pivot = Pivot.atPoint([1, 2, 3]);
    d.snapshot('pivot');
    o.pivot!.position[0] = 9;
    expect(
        d.historyBytes,
        greaterThan(
            o.mesh.positions.lengthInBytes + o.mesh.indices.lengthInBytes));
    d.undo();
    expect(d.objects.first.pivot!.position[0], 1);
    d.redo();
    expect(d.objects.first.pivot!.position[0], 9);
    d.maxUndoBytes = 1;
    d.snapshot('trim');
    expect(d.historyBytes, 0);
  });
  test('ZIP enforces CRC and declared expanded budget', () {
    final bytes = ZipArchive.write([
      ZipEntry('a', Uint8List.fromList([1, 2, 3]))
    ]);
    expect(() => ZipArchive.read(bytes, maxExpandedBytes: 2),
        throwsFormatException);
    final corrupt = Uint8List.fromList(bytes);
    for (var i = 0; i < corrupt.length - 4; i++) {
      if (ByteData.sublistView(corrupt).getUint32(i, Endian.little) ==
          0x02014b50) {
        corrupt[i + 16] ^= 1;
        break;
      }
    }
    expect(() => ZipArchive.read(corrupt), throwsFormatException);
    expect(() => ZipArchive.read(Uint8List(10)), throwsFormatException);
  });
  test('OFF comments and unsupported formats are explicit', () {
    final mesh = MeshIO.readBytes(
        't.off',
        Uint8List.fromList(utf8.encode(
            'OFF\n# full comment\n3 1 0 # counts\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n')));
    expect(mesh.validate(), isEmpty);
    expect(mesh.faceCount, 1);
    expect(
        () => MeshIO.readBytes('a.amf', Uint8List(0)), throwsFormatException);
    expect(() => MeshIO.writeBytes('a.unknown', mesh), throwsFormatException);
  });
  test('3MF handles separate index spaces, units and repeated instances', () {
    final base = ZipArchive.read(ThreeMfIO.write(triangle(), name: 'a & <b>'));
    final xml = '''<model unit="inch"><resources>
<object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
<object id="2"><components><component objectid="1" transform="1 0 0 0 1 0 0 0 1 2 0 0"/></components></object>
</resources><build><item objectid="1"/><item objectid="2"/></build></model>''';
    final entries = base
        .map((e) => e.name.endsWith('.model')
            ? ZipEntry(e.name, Uint8List.fromList(utf8.encode(xml)))
            : e)
        .toList();
    final mesh = ThreeMfIO.read(ZipArchive.write(entries));
    expect(mesh.vertexCount, 6);
    expect(mesh.faceCount, 2);
    expect(mesh.indices.skip(3), [3, 4, 5]);
    expect(mesh.bounds().maxX, closeTo(76.2, 0.0001));
    expect(mesh.validate(), isEmpty);
  });
  test('atomic save leaves existing destination intact on failure', () async {
    final dir = await Directory.systemTemp.createTemp('mmx-test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/scene.mmx';
    await writeFileAtomically(path, Uint8List.fromList([1]));
    await writeFileAtomically(path, Uint8List.fromList([2]));
    expect(await File(path).readAsBytes(), [2]);
    await expectLater(
        writeFileAtomically('${dir.path}/missing/scene', Uint8List(0)),
        throwsA(isA<FileSystemException>()));
    expect(await File(path).readAsBytes(), [2]);
  });
  // Each real CLI launch gets its own test deadline. Cold Dart startup on
  // shared native runners can exhaust a single deadline for the entire list.
  for (final args in [
    ['info'],
    ['reduce', 'a', 'b', '--percent', 'NaN'],
    ['render', 'a', 'b', '--width', '999999'],
    ['wat'],
    ['flip', 'a', 'b', '--unknown']
  ]) {
    test('CLI rejects ${args.join(' ')} with usage exit code', () async {
      final r = await Process.run(
          Platform.resolvedExecutable, ['run', 'bin/mmx.dart', ...args]);
      expect(r.exitCode, 2, reason: '$args: ${r.stderr}');
      expect(r.stderr, isNot(contains('Unhandled exception')));
    });
  }
}
