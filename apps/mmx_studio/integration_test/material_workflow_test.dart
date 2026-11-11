import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/state/workers.dart';
import 'package:mmx_studio/ui/screen.dart';

import '../test/fixtures/texture_fixture.dart';
import '../test/support/properties_panel.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native material editor and texture project round trip', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'mmx-native-material-',
    );
    final state = StudioState(loadStartup: false);
    try {
      final mesh = Modify.fitPrimitive(
        TriMesh(Float32List.fromList([-5, -5, -5, 5, 5, 5]), Uint32List(0)),
        PrimitiveKind.box,
      );
      state.selectedObjectId = state.doc.add(mesh).id;
      state.frameSelection();
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await tester.pumpAndSettle();
      await openPropertiesPanel(tester);
      await tester.ensureVisible(find.text('Material and texture'));
      await tester.tap(find.text('Material and texture'));
      await tester.pumpAndSettle();
      final red = find.byKey(const ValueKey('material-rgba-0'));
      await tester.ensureVisible(red);
      await tester.enterText(red, '0.25');
      final apply = find.byKey(const ValueKey('apply-material'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await settleStudioInteraction(tester, state);
      expect(state.doc.undoDepth, 1, reason: state.status);
      expect(state.activeMesh!.materials.single.baseColor, [.25, 1, 1, 1]);
      await closePropertiesPanel(tester);
      final image = File('${directory.path}/色.png');
      await image.writeAsBytes(textureFixturePng());
      // Native filesystem/worker decoding; dialog routing has widget coverage.
      expect(
        await state.applySelectedMaterial(
          baseColor: [1, 1, 1, 1],
          texturePath: image.path,
          planarAxis: 2,
          textureClamp: true,
        ),
        true,
        reason: state.status,
      );
      await tester.pumpAndSettle();
      expect(state.frame, isNotNull, reason: state.renderDiagnostic);
      expect(state.doc.undoDepth, 2);
      expect(state.activeMesh!.cornerUvs, isNotNull);
      expect(state.activeMesh!.materials.single.texture!.rgba.take(4), [
        255,
        0,
        0,
        255,
      ]);
      final objPath = '${directory.path}/textured.obj';
      await state.exportSelected(objPath);
      expect(state.status, contains('companion folder'));
      final imported = await readMeshWorker(
        objPath,
        await File(objPath).readAsBytes(),
      );
      expect(imported.materials.single.texture!.bytes, textureFixturePng());
      expect(imported.cornerUvs, state.activeMesh!.cornerUvs);
      await state.importPath(objPath);
      expect(
        state.activeMesh!.materials.single.texture!.bytes,
        textureFixturePng(),
      );
      final project = '${directory.path}/textured.mmx';
      expect(await state.saveProject(project), true, reason: state.status);
      expect(await state.removeSelectedSurfaceAttributes(), true);
      expect(state.activeMesh!.hasSurfaceAttributes, false);
      await state.undo();
      expect(
        state.activeMesh!.materials.single.texture!.bytes,
        textureFixturePng(),
      );
      expect(await state.openProject(project), true, reason: state.status);
      expect(
        state.activeMesh!.materials.single.texture!.bytes,
        textureFixturePng(),
      );
      expect(state.activeMesh!.materials.single.textureClamp, true);
      expect(state.activeMesh!.cornerUvs!.every((v) => v >= 0 && v <= 1), true);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    } finally {
      state.dispose();
      await directory.delete(recursive: true);
    }
  });
}
