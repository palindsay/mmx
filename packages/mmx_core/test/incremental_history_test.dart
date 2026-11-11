import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';
import 'package:test/test.dart';

TriMesh largeMesh() {
  final positions = Float32List(90000);
  for (var i = 0; i < positions.length; i++) {
    positions[i] = (i * 0.1234567) % 9876;
  }
  return TriMesh(
      positions, Uint32List.fromList(List.generate(30000, (i) => i)));
}

void main() {
  test('metadata history shares geometry and restores every edit', () {
    final doc = Document();
    final original = largeMesh();
    final object = doc.add(original);
    final geometryBytes =
        original.positions.lengthInBytes + original.indices.lengthInBytes;
    for (var i = 0; i < 80; i++) {
      doc.snapshot('Move $i');
      doc.byId(object.id)!.transform[12] = i + 1;
      doc.byId(object.id)!.name = 'Moved ${i + 1}';
    }
    expect(doc.undoDepth, 80);
    expect(doc.historyBytes, lessThan(geometryBytes * 1.2));
    for (var i = 79; i >= 0; i--) {
      expect(doc.undo(), isTrue);
      expect(doc.byId(object.id)!.transform[12], i);
      expect(doc.byId(object.id)!.mesh, same(original));
    }
    for (var i = 1; i <= 80; i++) {
      expect(doc.redo(), isTrue);
      expect(doc.byId(object.id)!.name, 'Moved $i');
    }
    expect(doc.redo(), isFalse);
  });

  test('sparse in-place edits retain deltas and isolate live mutations', () {
    final doc = Document();
    final object = doc.add(largeMesh());
    final untouched = doc.add(largeMesh());
    final untouchedMesh = untouched.mesh;
    final original = object.mesh.positions[12000];
    doc.snapshot('Before sculpt');
    final baseline = doc.historyBytes;
    for (var i = 1; i <= 20; i++) {
      object.mesh.positions[12000] = i.toDouble();
      doc.snapshot('Sculpt $i');
    }
    // Twenty full copies would exceed 9MiB; sparse changes stay below 1MiB.
    expect(doc.historyBytes - baseline, lessThan(1024 * 1024));
    object.mesh.positions[12000] = -1;
    for (var i = 20; i >= 1; i--) {
      expect(doc.undo(), isTrue);
      expect(doc.byId(object.id)!.mesh.positions[12000], i);
      expect(doc.byId(untouched.id)!.mesh, same(untouchedMesh));
    }
    expect(doc.undo(), isTrue);
    expect(doc.byId(object.id)!.mesh.positions[12000], original);
    expect(doc.redo(), isTrue);
    expect(doc.byId(object.id)!.mesh.positions[12000], 1);
    doc.byId(object.id)!.mesh.positions[12000] = 999;
    expect(doc.undo(), isTrue);
    expect(doc.byId(object.id)!.mesh.positions[12000], original);
  });

  test('rollback restores scene, both history stacks and future IDs', () {
    final doc = Document();
    final a = doc.add(largeMesh(), name: 'A');
    doc.snapshot('Rename');
    a.name = 'B';
    doc.undo();
    final rollback = doc.checkpoint();
    doc.snapshot('Delete');
    doc.remove(a.id);
    doc.add(largeMesh(), name: 'temporary');
    rollback();
    expect(doc.objects.single.name, 'A');
    expect(doc.canUndo, isFalse);
    expect(doc.canRedo, isTrue);
    expect(doc.redo(), isTrue);
    expect(doc.objects.single.name, 'B');
    expect(doc.add(largeMesh()).id, a.id + 1);
    rollback();
    expect(doc.objects.single.name, 'A');
    expect(doc.canRedo, isTrue);
  });

  test('history budgets bound metadata, undo and redo', () {
    final doc = Document(maxUndoEntries: 3);
    final object = doc.add(largeMesh());
    for (var i = 0; i < 10; i++) {
      doc.snapshot('Rename');
      object.name = '$i';
    }
    expect(doc.undoDepth, 3);
    expect(doc.undo(), isTrue);
    expect(doc.undo(), isTrue);
    expect(doc.undo(), isTrue);
    expect(doc.undo(), isFalse);
    expect(doc.objects.single.name, '6');
    doc.maxUndoBytes = 0;
    doc.redo();
    expect(doc.historyBytes, 0);
    expect(doc.canUndo, isFalse);
    expect(doc.canRedo, isFalse);
    expect(() => Document(maxUndoEntries: -1), throwsArgumentError);
  });

  test('unaligned buffer views and all surface attributes survive undo', () {
    final data = Uint8List(64);
    final mesh = TriMesh(
        Float32List.view(data.buffer, 4, 9), Uint32List.fromList([0, 1, 2]),
        faceGroups: Uint16List.fromList([7]),
        vertexColors: Float32List.fromList(List.filled(9, 0.25)),
        cornerUvs: Float32List.fromList([0, 0, 1, 0, 0, 1]),
        faceMaterials: Uint16List.fromList([0]),
        materials: [
          MeshMaterial(baseColor: [1, 0, 0, 1])
        ]);
    mesh.positions.setAll(0, [0, 0, 0, 1, 0, 0, 0, 1, 0]);
    final doc = Document()..add(mesh);
    doc.snapshot('Edit attributes');
    mesh.cornerUvs![0] = 0.5;
    mesh.faceGroups![0] = 3;
    mesh.vertexColors![0] = 1;
    mesh.materials = [
      MeshMaterial(baseColor: [0, 1, 0, 1])
    ];
    doc.undo();
    final saved = doc.objects.single.mesh;
    expect(saved.positions, [0, 0, 0, 1, 0, 0, 0, 1, 0]);
    expect(saved.cornerUvs, [0, 0, 1, 0, 0, 1]);
    expect(saved.faceGroups, [7]);
    expect(saved.vertexColors!.first, 0.25);
    expect(saved.materials.single.baseColor, [1, 0, 0, 1]);
    doc.redo();
    expect(doc.objects.single.mesh.cornerUvs!.first, 0.5);
    expect(doc.objects.single.mesh.materials.single.baseColor, [0, 1, 0, 1]);
  });
}
