import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/gizmo.dart';
import 'package:mmx_studio/ui/screen.dart';
import 'package:mmx_studio/ui/viewport.dart';

import 'support/properties_panel.dart';

class _LayoutState extends StudioState {
  _LayoutState() : super(loadStartup: false);

  @override
  Future<void> render() async {}
}

void main() {
  testWidgets(
    'native macOS Tab uses the IME selector before Apply handles Enter',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Match integration_test: no mock IME is registered to translate the
      // framework's synthetic Tab into Cocoa's insertTab: selector.
      tester.testTextInput.unregister();
      addTearDown(tester.testTextInput.register);
      final state = _LayoutState();
      addTearDown(state.dispose);
      final mesh = Modify.fitPrimitive(
        TriMesh(Float32List.fromList([-1, -1, -1, 1, 1, 1]), Uint32List(0)),
        PrimitiveKind.box,
      );
      state.selectedObjectId = state.doc.add(mesh).id;
      state.setManipulatorMode(ManipulatorMode.translate);
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await tester.pumpAndSettle();
      await openPropertiesPanel(tester);
      final amount = find.byKey(const ValueKey('manipulator-amount'));
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '1.3');
      final editable = tester.widget<EditableText>(
        find.descendant(of: amount, matching: find.byType(EditableText)),
      );
      expect(editable.controller.text, '1.3');
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isFalse);
      await tester.pumpAndSettle();
      expect(editable.focusNode.hasPrimaryFocus, isTrue);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      await tester.pumpAndSettle();
      expect(state.doc.undoDepth, 0, reason: 'Raw synthetic keys omit the IME');
      await tabFromFieldToButton(
        tester,
        field: amount,
        button: find.byKey(const ValueKey('apply-manipulator')),
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
      await settleStudioInteraction(tester, state);
      expect(state.doc.undoDepth, 1);
      expect(state.selected!.transform[12], closeTo(1.3, 1e-8));
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
  for (final size in [const Size(800, 600), const Size(1280, 720)]) {
    testWidgets('properties workflows at $size logical pixels', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _LayoutState();
      addTearDown(state.dispose);
      final mesh = Modify.fitPrimitive(
        TriMesh(Float32List.fromList([-1, -1, -1, 1, 1, 1]), Uint32List(0)),
        PrimitiveKind.box,
      );
      state.selectedObjectId = state.doc.add(mesh).id;
      state.frameSelection();
      state.setManipulatorMode(ManipulatorMode.translate);
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await tester.pumpAndSettle();
      final amount = find.byKey(const ValueKey('manipulator-amount'));
      expect(amount, size.width < 900 ? findsNothing : findsOneWidget);
      await openPropertiesPanel(tester);
      await tester.ensureVisible(amount);
      await tester.enterText(amount, '0.5');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleStudioInteraction(tester, state);
      expect(state.selected!.transform[12], .5);
      expect(state.doc.undoDepth, 1);
      await closePropertiesPanel(tester);
      final viewport = find.byType(MeshViewport);
      final projection = GizmoProjection.forState(
        state,
        tester.getSize(viewport),
      )!;
      final start = tester.getTopLeft(viewport) + projection.handles[0]!;
      final before = Float64List.fromList(state.selected!.transform);
      final drag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(25, 0));
      expect(state.manipulatorGestureActive, isTrue);
      expect(state.selected!.transform, isNot(before));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await drag.up();
      await settleStudioInteraction(tester, state);
      expect(state.selected!.transform, before);
      expect(state.interactionLocked, isFalse);
      expect(state.doc.undoDepth, 1);
      await openPropertiesPanel(tester);
      final material = find.text('Material and texture');
      await tester.ensureVisible(material);
      await tester.pumpAndSettle();
      await tester.tap(material);
      await tester.pumpAndSettle();
      final red = find.byKey(const ValueKey('material-rgba-0'));
      await tester.ensureVisible(red);
      await tester.enterText(red, '0.25');
      final apply = find.byKey(const ValueKey('apply-material'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await settleStudioInteraction(tester, state);
      expect(state.activeMesh!.materials.single.baseColor, [.25, 1, 1, 1]);
      expect(state.doc.undoDepth, 2);
      await closePropertiesPanel(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
