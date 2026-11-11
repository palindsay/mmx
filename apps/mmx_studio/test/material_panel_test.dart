import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/state/workers.dart';
import 'package:mmx_studio/ui/renderer_controls.dart';
import 'package:mmx_studio/ui/material_panel.dart';

import 'fixtures/texture_fixture.dart';

class MaterialState extends StudioState {
  MaterialState() : super(loadStartup: false) {
    final mesh = Modify.fitPrimitive(
      TriMesh(Float32List.fromList([-1, -1, -1, 1, 1, 1]), Uint32List(0)),
      PrimitiveKind.box,
    );
    mesh.vertexColors = Float32List(mesh.vertexCount * 3)
      ..fillRange(0, mesh.vertexCount * 3, .5);
    selectedObjectId = doc.add(mesh).id;
  }
  @override
  Future<void> render() async {}
}

Future<void> settleWork(WidgetTester tester, StudioState state) async {
  for (var i = 0; i < 300 && state.busy; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(state.busy, false, reason: state.status);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'material, decoded texture and planar UVs apply as one undo and persist',
    () async {
      final state = MaterialState();
      final directory = await Directory.systemTemp.createTemp('mmx-material-');
      try {
        final file = File('${directory.path}/色.png');
        await file.writeAsBytes(textureFixturePng());
        final original = state.activeMesh!.clone();
        expect(
          await state.applySelectedMaterial(
            baseColor: [.2, .4, .6, .8],
            texturePath: file.path,
            planarAxis: 2,
            textureClamp: true,
          ),
          true,
          reason: state.status,
        );
        expect(state.doc.undoDepth, 1);
        expect(state.dirty, true);
        final mesh = state.activeMesh!;
        expect(mesh.materials.single.baseColor, [.2, .4, .6, .8]);
        expect(mesh.materials.single.textureClamp, true);
        expect(mesh.materials.single.texture!.rgba.take(4), [255, 0, 0, 255]);
        expect(mesh.materials.single.texture!.bytes, textureFixturePng());
        expect(mesh.cornerUvs!.length, mesh.indices.length * 2);
        expect(mesh.cornerUvs!.every((v) => v >= 0 && v <= 1), true);
        expect(mesh.faceMaterials, List.filled(mesh.faceCount, 0));
        expect(mesh.positions, original.positions);
        expect(mesh.vertexColors, original.vertexColors);
        await state.undo();
        expect(state.activeMesh!.hasSurfaceAttributes, false);
        await state.redo();
        expect(
          state.activeMesh!.materials.single.texture!.bytes,
          textureFixturePng(),
        );
        final exported = '${directory.path}/textured.obj';
        await state.exportSelected(exported);
        expect(state.status, contains('companion folder'));
        final imported = await readMeshWorker(
          exported,
          await File(exported).readAsBytes(),
        );
        expect(imported.materials.single.baseColor, [.2, .4, .6, .8]);
        expect(imported.materials.single.texture!.bytes, textureFixturePng());
        expect(imported.cornerUvs, state.activeMesh!.cornerUvs);
        final importedState = MaterialState();
        try {
          await importedState.importPath(exported);
          expect(
            importedState.activeMesh!.materials.single.texture!.bytes,
            textureFixturePng(),
          );
        } finally {
          importedState.dispose();
        }
        final project = '${directory.path}/material.mmx';
        expect(await state.saveProject(project), true, reason: state.status);
        expect(await state.removeSelectedSurfaceAttributes(), true);
        expect(state.activeMesh!.hasSurfaceAttributes, false);
        expect(state.activeMesh!.vertexColors, original.vertexColors);
        expect(state.doc.undoDepth, 2);
        await state.undo();
        expect(
          state.activeMesh!.materials.single.texture!.bytes,
          textureFixturePng(),
        );
        expect(await state.openProject(project), true, reason: state.status);
        expect(state.activeMesh!.materials.single.baseColor, [.2, .4, .6, .8]);
        expect(
          state.activeMesh!.materials.single.texture!.bytes,
          textureFixturePng(),
        );
      } finally {
        state.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'material failures and cancellation preserve attributes and history',
    () async {
      final state = MaterialState();
      final directory = await Directory.systemTemp.createTemp(
        'mmx-material-fail-',
      );
      try {
        final file = File('${directory.path}/valid.png');
        await file.writeAsBytes(textureFixturePng());
        expect(
          await state.applySelectedMaterial(
            baseColor: [1, 1, 1, 1],
            texturePath: file.path,
          ),
          false,
        );
        expect(state.status, contains('UV coordinates'));
        expect(
          await state.applySelectedMaterial(baseColor: [double.nan, 0, 0, 1]),
          false,
        );
        expect(state.status, contains('Invalid mesh material'));
        final oversized = await File('${directory.path}/large.png')
            .open(mode: FileMode.write);
        await oversized.truncate(MeshTexture.maxEncodedBytes + 1);
        await oversized.close();
        expect(
          await state.applySelectedMaterial(
            baseColor: [1, 1, 1, 1],
            texturePath: '${directory.path}/large.png',
            planarAxis: 1,
          ),
          false,
        );
        expect(state.status, contains('16 MiB'));
        void cancel() {
          if (state.operationPhase == 'Computing') {
            state.removeListener(cancel);
            state.cancelOperation();
          }
        }

        state.addListener(cancel);
        expect(
          await state.applySelectedMaterial(
            baseColor: [1, 1, 1, 1],
            texturePath: file.path,
            planarAxis: 1,
          ),
          false,
        );
        expect(state.status, contains('cancelled'));
        expect(state.activeMesh!.hasSurfaceAttributes, false);
        expect(state.doc.undoDepth, 0);
        expect(state.dirty, false);
        expect(state.interactionLocked, false);
      } finally {
        state.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'renderer dropdown accepts keyboard CPU choice and locks during edits',
    (tester) async {
      final state = MaterialState()
        ..renderBackend = 'CPU fallback'
        ..renderDiagnostic = 'Adapter unavailable; CPU selected';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 330,
              child: ListenableBuilder(
                listenable: state,
                builder: (_, _) => RendererControls(state: state),
              ),
            ),
          ),
        ),
      );
      expect(find.text('CPU fallback'), findsOneWidget);
      expect(
        find.byTooltip('Adapter unavailable; CPU selected'),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButton<RenderBackendPreference>));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(state.renderBackendPreference, RenderBackendPreference.cpu);
      state.busy = true;
      state.notify();
      await tester.pump();
      final dropdown = tester.widget<DropdownButton<RenderBackendPreference>>(
        find.byType(DropdownButton<RenderBackendPreference>),
      );
      expect(dropdown.onChanged, null);
      await state.setRenderBackend(RenderBackendPreference.auto);
      expect(state.renderBackendPreference, RenderBackendPreference.cpu);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'material editor stages texture, commits once, and retains failed draft',
    (tester) async {
      final state = MaterialState();
      late Directory directory;
      late File texture;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'mmx-material-panel-',
        );
        texture = File('${directory.path}/draft.png');
        await texture.writeAsBytes(textureFixturePng());
      });
      String? chosen = texture.path;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'openFile' && chosen != null ? [chosen] : null,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 330,
                  child: ListenableBuilder(
                    listenable: state,
                    builder: (_, _) => MaterialPanel(state: state),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Material and texture'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('material-rgba-0')),
          'NaN',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('apply-material')),
        );
        await tester.tap(find.byKey(const ValueKey('apply-material')));
        await tester.pump();
        expect(find.textContaining('Each RGBA channel'), findsOneWidget);
        expect(state.doc.undoDepth, 0);
        await tester.ensureVisible(
          find.byKey(const ValueKey('material-rgba-0')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('material-rgba-0')),
          '0.25',
        );
        await tester.ensureVisible(find.text('Choose texture…'));
        await tester.tap(find.text('Choose texture…'));
        await tester.pumpAndSettle();
        expect(find.text('Texture: draft.png'), findsOneWidget);
        expect(find.text('Planar Y (XZ plane)'), findsOneWidget);
        expect(
          state.activeMesh!.hasSurfaceAttributes,
          false,
          reason: 'choosing is a draft',
        );
        expect(state.doc.undoDepth, 0);
        await tester.ensureVisible(
          find.byKey(const ValueKey('apply-material')),
        );
        await tester.tap(find.byKey(const ValueKey('apply-material')));
        await settleWork(tester, state);
        expect(state.doc.undoDepth, 1, reason: state.status);
        expect(state.activeMesh!.materials.single.baseColor[0], .25);
        expect(state.activeMesh!.materials.single.texture!.name, 'draft.png');
        await tester.runAsync(() async {
          chosen = '${directory.path}/broken.png';
          await File(chosen!).writeAsString('not a texture');
        });
        await tester.ensureVisible(find.text('Choose texture…'));
        await tester.tap(find.text('Choose texture…'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('apply-material')),
        );
        await tester.tap(find.byKey(const ValueKey('apply-material')));
        await settleWork(tester, state);
        expect(find.textContaining('Only PNG/JPEG textures'), findsOneWidget);
        expect(
          find.text('Texture: broken.png'),
          findsOneWidget,
          reason: 'failed draft remains editable',
        );
        expect(state.activeMesh!.materials.single.texture!.name, 'draft.png');
        expect(state.doc.undoDepth, 1);
        chosen = null;
        await tester.ensureVisible(find.text('Choose texture…'));
        await tester.tap(find.text('Choose texture…'));
        await tester.pumpAndSettle();
        expect(
          state.doc.undoDepth,
          1,
          reason: 'native picker cancellation does not edit',
        );
        await tester.pumpWidget(const SizedBox());
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        state.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
