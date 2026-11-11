import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';

class ScanTestState extends StudioState {
  @override
  Future<void> render() async {}
}

TriMesh box(double half) => Modify.fitPrimitive(
  TriMesh(
    Float32List.fromList([-half, -half, -half, half, half, half]),
    Uint32List(0),
  ),
  PrimitiveKind.box,
);
ScanTestState scene() {
  final state = ScanTestState();
  final small = box(.1)..transform(translation4(5, 0, 0));
  state.selectedObjectId = state.doc
      .add(Modify.combine([box(1), small]), name: 'Scan')
      .id;
  return state;
}

void main() {
  test('scan reports and reusable recipes retain hashes; unrecorded edits cannot silently replay', () async {
    final state = scene();
    addTearDown(state.dispose);
    final directory = await Directory.systemTemp.createTemp('mmx-report-');
    addTearDown(() => directory.delete(recursive: true));
    await state.previewScan(ScanStep('fragments', {'areaMm2': 1}));
    await state.applyScanPreview();
    final report = '${directory.path}/report.json',
        recipe = '${directory.path}/recipe.json';
    expect(await state.exportScanData(report), isTrue, reason: state.status);
    final data = jsonDecode(await File(report).readAsString());
    expect(data['originalMeshSha256'], hasLength(64));
    expect(data['history'][0]['inputMeshSha256'], data['originalMeshSha256']);
    expect(
      await state.exportScanData(recipe, recipe: true),
      isTrue,
      reason: state.status,
    );
    final decoded = ScanRecipe.fromJson(
      jsonDecode(await File(recipe).readAsString()),
    );
    expect(decoded.steps.single.operation, 'fragments');
    await state.transformSelected(translation4(5, 0, 0));
    expect(
      await state.exportScanData('${directory.path}/broken.json', recipe: true),
      isFalse,
    );
    expect(File('${directory.path}/broken.json').existsSync(), isFalse);
  });
  test(
    'hollow thickness is invariant to baked versus object transforms',
    () async {
      final a = ScanTestState(), b = ScanTestState();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.selectedObjectId = a.doc.add(box(1)).id;
      a.selected!.transform = scale4(20);
      b.selectedObjectId = b.doc.add(box(20)).id;
      for (final state in [a, b]) {
        state.solidResolution = 32;
        state.hollowThickness = 2;
        state.hollowHoles = 0;
        await state.doHollow();
      }
      expect(a.activeMesh!.faceCount, greaterThan(12), reason: a.status);
      expect(a.activeMesh!.positions, b.activeMesh!.positions);
      expect(a.activeMesh!.indices, b.activeMesh!.indices);
      expect(a.selected!.transform, identity4());
      expect(MeshTopology(a.activeMesh!).boundaryEdges(), isEmpty);
      expect(MeshTopology(a.activeMesh!).nonManifoldEdges(), isEmpty);
      expect(
        a.activeMesh!.signedVolume(),
        closeTo(b.activeMesh!.signedVolume(), .001),
      );
    },
  );
  test('preview cancel is transactional; Apply preserves a persistent protected original', () async {
    final state = scene();
    addTearDown(state.dispose);
    final before = state.activeMesh!.clone();
    final revision = state.doc.revision;
    await state.previewScan(ScanStep('fragments', {'areaMm2': 1}));
    expect(state.scanPreview, isNotNull, reason: state.status);
    expect(state.doc.revision, revision);
    expect(state.doc.canUndo, isFalse);
    expect(state.dirty, isFalse);
    expect(state.activeMesh!.faceCount, before.faceCount);
    await state.cancelScanPreview();
    expect(state.scanPreview, isNull);
    expect(state.doc.revision, revision);
    await state.previewScan(ScanStep('fragments', {'areaMm2': 1}));
    await state.applyScanPreview();
    expect(state.activeMesh!.faceCount, 12, reason: state.status);
    expect(state.doc.objects, hasLength(2));
    expect(state.scanPreview, isNull);
    final original = state.doc.byId(state.selected!.scanSourceId!)!;
    expect(original.locked, isTrue);
    expect(original.visible, isFalse);
    expect(original.mesh.positions, before.positions);
    expect(original.mesh.indices, before.indices);
    expect(state.selected!.scanHistory, hasLength(1));
    expect(state.scanReportCurrent, isTrue);
    state.printProfile = const PrintProfile(
      width: 250,
      depth: 220,
      height: 300,
      minimumWall: 1.2,
    );
    final directory = await Directory.systemTemp.createTemp('mmx-scan-state-');
    addTearDown(() => directory.delete(recursive: true));
    expect(await state.saveProject('${directory.path}/scan.mmx'), isTrue);
    final reopened = ScanTestState();
    addTearDown(reopened.dispose);
    expect(await reopened.openProject('${directory.path}/scan.mmx'), isTrue);
    expect(reopened.doc.byId(reopened.selected!.scanSourceId!)!.locked, isTrue);
    expect(reopened.selected!.scanHistory, hasLength(1));
    expect(reopened.printProfile.width, 250);
    await state.undo();
    expect(state.doc.objects, hasLength(1));
    expect(state.activeMesh!.faceCount, before.faceCount);
    await state.redo();
    expect(state.doc.objects, hasLength(2));
    expect(state.selected!.scanSourceId, isNotNull);
  });
  test(
    'originals cannot be transformed, sculpted, deleted or combined',
    () async {
      final state = scene();
      addTearDown(state.dispose);
      await state.previewScan(ScanStep('fragments', {'areaMm2': 1}));
      await state.applyScanPreview();
      final source = state.doc.byId(state.selected!.scanSourceId!)!;
      state.selectedObjectId = source.id;
      await state.transformSelected(translation4(5, 0, 0));
      expect(source.transform, identity4());
      expect(state.beginSculptStroke(), isFalse);
      await state.sceneAction(source.id, 'delete');
      expect(state.doc.byId(source.id), isNotNull);
      expect(state.status, contains('failed'));
      state.selectedObjectId = state.doc.objects
          .firstWhere((o) => !o.locked)
          .id;
      final before = source.mesh.positions.toList();
      await state.packAll();
      expect(source.mesh.positions, before);
      expect(source.transform, identity4());
    },
  );
  test('failed preview leaves source geometry and history intact', () async {
    final state = scene();
    addTearDown(state.dispose);
    final before = state.activeMesh!.positions.toList();
    await state.previewScan(
      ScanStep('reduce', {'keepFraction': .1, 'deviationMm': .00001}),
    );
    expect(state.scanPreview, isNull);
    expect(state.activeMesh!.positions, before);
    expect(state.doc.canUndo, isFalse);
    expect(state.dirty, isFalse);
    expect(state.status, contains('failed'));
  });
  test('scene metadata is undoable and findings expire after edits', () async {
    final state = scene();
    addTearDown(state.dispose);
    final id = state.selectedObjectId!;
    await state.inspectScan();
    expect(state.scanReportCurrent, isTrue);
    final finding = state.scanReport!.findings.firstWhere(
      (f) => f.code == 'smallComponent',
    );
    state.selectScanFinding(finding);
    expect(state.selection!.faceMask.where((v) => v != 0), hasLength(12));
    await state.sceneAction(id, 'rename', name: 'Cleaned scan');
    expect(state.selected!.name, 'Cleaned scan');
    expect(state.scanReportCurrent, isFalse);
    await state.undo();
    expect(state.selected!.name, 'Scan');
    await state.sceneAction(id, 'visibility');
    expect(state.selected!.visible, isFalse);
    await state.undo();
    expect(state.selected!.visible, isTrue);
    await state.sceneAction(id, 'delete');
    expect(state.doc.objects, isEmpty);
    await state.undo();
    expect(state.doc.objects, hasLength(1));
  });
  for (final size in [const Size(800, 600), const Size(1280, 720)]) {
    testWidgets('scan preview Apply and Cancel remain visible at $size', (
      tester,
    ) async {
      final state = scene();
      addTearDown(state.dispose);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => state.previewScan(ScanStep('fragments', {'areaMm2': 1})),
      );
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await tester.pumpAndSettle();
      if (size.width < 900) {
        await tester.tap(find.byTooltip('Tool properties'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Apply scan edit'), findsOneWidget);
      final cancel = find.text('Cancel preview');
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(state.scanPreview, isNull);
      expect(state.doc.canUndo, isFalse);
      expect(state.activeMesh!.faceCount, 24);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
