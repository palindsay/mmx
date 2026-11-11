import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/manipulator.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/gizmo.dart';
import 'package:mmx_studio/ui/screen.dart';
import 'package:mmx_studio/ui/viewport.dart';

import '../test/support/properties_panel.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native numeric and pointer transforms preserve pivot and undo', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'mmx-native-transform-',
    );
    final state = StudioState(loadStartup: false);
    try {
      final mesh = Modify.fitPrimitive(
        TriMesh(Float32List.fromList([-1, -1, -1, 1, 1, 1]), Uint32List(0)),
        PrimitiveKind.box,
      );
      final scale = identity4()
        ..[0] = 2
        ..[5] = 3
        ..[10] = 4;
      final object = state.doc.add(mesh)
        ..transform = multiply4(
          translation4(4, 6, 8),
          multiply4(rotation4(0, 0, 1, math.pi / 2), scale),
        )
        ..pivot = Pivot.atPoint([.5, -.5, .25]);
      state.selectedObjectId = object.id;
      state.frameSelection();
      state.setManipulatorSpace(ManipulatorSpace.local);
      state.setManipulatorMode(ManipulatorMode.translate);
      state.setManipulatorSnap(
        const ManipulatorSnap(enabled: true, translation: .5),
      );
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await tester.pumpAndSettle();
      await openPropertiesPanel(tester);
      final amount = find.byKey(const ValueKey('manipulator-amount'));
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '1.3');
      final amountEditable = tester.widget<EditableText>(
        find.descendant(of: amount, matching: find.byType(EditableText)),
      );
      expect(amountEditable.controller.text, '1.3');
      debugPrint(
        'Before Apply: status=${state.status}; undo=${state.doc.undoDepth}',
      );
      // A keyboard user can reach Apply immediately after the amount field.
      await tabFromFieldToButton(
        tester,
        field: amount,
        button: find.byKey(const ValueKey('apply-manipulator')),
      );
      final enterHandled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleStudioInteraction(tester, state);
      debugPrint(
        'After Enter: handled=$enterHandled; value=${amountEditable.controller.text}; '
        'status=${state.status}; undo=${state.doc.undoDepth}; '
        '${keyboardFocusDescription()}',
      );
      expect(enterHandled, isTrue, reason: 'Focused Apply must handle Enter');
      expect(state.doc.undoDepth, 1);
      expect(state.selected!.transform[12], closeTo(4, 1e-8));
      expect(state.selected!.transform[13], closeTo(4.5, 1e-8));
      final pivot = objectPivotWorld(state.selected!);
      await closePropertiesPanel(tester);
      state.setManipulatorMode(ManipulatorMode.scale);
      state.setManipulatorSnap(
        const ManipulatorSnap(enabled: true, scale: .25),
      );
      state.setManipulatorScaleMode(ManipulatorScaleMode.axis);
      await tester.pumpAndSettle();
      final viewport = find.byType(MeshViewport);
      final projection = GizmoProjection.forState(
        state,
        tester.getSize(viewport),
      )!;
      final offset = tester.getTopLeft(viewport),
          handle = projection.handles[0]!;
      final drag = await tester.startGesture(
        offset + handle,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(offset + handle + (handle - projection.origin) * .3);
      await drag.up();
      await settleStudioInteraction(tester, state);
      expect(state.doc.undoDepth, 2);
      for (var i = 0; i < 3; i++) {
        expect(objectPivotWorld(state.selected!)[i], closeTo(pivot[i], 1e-8));
      }
      final savedTransform = Float64List.fromList(state.selected!.transform);
      final project = '${directory.path}/transformed.mmx';
      expect(await state.saveProject(project), true, reason: state.status);
      final nextProjection = GizmoProjection.forState(
        state,
        tester.getSize(viewport),
      )!;
      final cancel = await tester.startGesture(
        offset + nextProjection.handles[0]!,
        kind: PointerDeviceKind.mouse,
      );
      await cancel.moveTo(
        offset + nextProjection.handles[0]! + const Offset(35, 0),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await cancel.up();
      await settleStudioInteraction(tester, state);
      expect(state.selected!.transform, savedTransform);
      expect(state.interactionLocked, false);
      expect(state.dirty, false);
      expect(await state.openProject(project), true, reason: state.status);
      expect(state.selected!.transform, savedTransform);
      expect(state.selected!.pivot!.position, [.5, -.5, .25]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    } finally {
      state.dispose();
      await directory.delete(recursive: true);
    }
  });
}
