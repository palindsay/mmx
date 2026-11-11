import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';

class NewProjectState extends StudioState {
  bool failRender = false;
  @override
  Future<void> render() async {
    if (failRender) throw StateError('Preview unavailable');
  }
}

class HeldNewProjectState extends NewProjectState {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> render() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

TriMesh triangle() => TriMesh(
  Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
  Uint32List.fromList([0, 1, 2]),
);

void populate(StudioState state) {
  state.selectedObjectId = state.doc.add(triangle(), name: 'My scan').id;
  state.doc.snapshot('Edit');
  state.dirty = true;
  state.sourceAttachments.add(
    ProjectSourceAttachment(
      name: 'source.mix',
      bytes: Uint8List.fromList([1, 2]),
    ),
  );
}

Future<void> showScreen(
  WidgetTester tester,
  StudioState state, {
  TargetPlatform platform = TargetPlatform.linux,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(platform: platform),
    home: StudioScreen(state: state, enableRecovery: false),
  ),
);

Future<void> chooseNew(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Project'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New project'));
  await tester.pumpAndSettle();
}

void main() {
  test('New project locks its preview and preserves edits from completion listeners', () async {
    final state = HeldNewProjectState();
    addTearDown(state.dispose);
    populate(state);
    state.addListener(() {
      if (!state.busy && state.doc.objects.isEmpty) {
        state.doc.snapshot('New edit');
        state.doc.add(triangle(), name: 'Next scan');
        state.dirty = true;
      }
    });
    final pending = state.newProject();
    await state.entered.future;
    expect(state.interactionLocked, true);
    expect(await state.newProject(), false);
    state.release.complete();
    expect(await pending, true);
    expect(state.doc.objects.single.name, 'Next scan');
    expect(state.doc.undoDepth, 1);
    expect(state.dirty, true);
  });

  test(
    'startup and New project are empty and independent of prior history',
    () async {
      final state = NewProjectState();
      addTearDown(state.dispose);
      expect(state.doc.objects, isEmpty);
      expect(state.dirty, false);
      populate(state);
      state.projectPath = '/prior/project.mmx';
      state.selection = Selection(Uint8List.fromList([1]), 1);
      state.overlay = AnalysisOverlay.thickness;
      state.overlayColors = Uint8List(3);
      state.camera.target = [10, 20, 30];
      state.tool = StudioTool.sculpt;
      state.manipulatorMode = ManipulatorMode.translate;
      state.refreshShellCount();
      expect(await state.newProject(), true);
      expect(state.doc.objects, isEmpty);
      expect(state.doc.canUndo, false);
      expect(state.doc.canRedo, false);
      expect(state.doc.historyBytes, 0);
      expect(state.sourceAttachments, isEmpty);
      expect(state.projectPath, isNull);
      expect(state.selectedObjectId, isNull);
      expect(state.selection, isNull);
      expect(state.overlay, AnalysisOverlay.none);
      expect(state.overlayColors, isNull);
      expect(state.shellCount, 0);
      expect(state.camera.target, [0, 0, 0]);
      expect(state.tool, StudioTool.navigate);
      expect(state.manipulatorMode, ManipulatorMode.none);
      expect(state.dirty, false);
      await state.undo();
      expect(state.doc.objects, isEmpty);
      // The replacement remains complete even if only its preview fails.
      populate(state);
      state.failRender = true;
      expect(await state.newProject(), true);
      expect(state.doc.objects, isEmpty);
      expect(state.interactionLocked, false);
      expect(state.status, contains('Preview failed'));
    },
  );

  test('New project cannot interrupt an operation or sculpt stroke', () async {
    final state = NewProjectState();
    addTearDown(state.dispose);
    populate(state);
    state.busy = true;
    expect(await state.newProject(), false);
    state.busy = false;
    expect(state.beginSculptStroke(), true);
    expect(await state.newProject(), false);
    expect(state.doc.objects.single.name, 'My scan');
    await state.endSculptStroke(cancel: true);
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('New project shortcut on $platform skips clean confirmation', (
      tester,
    ) async {
      final state = NewProjectState();
      addTearDown(state.dispose);
      populate(state);
      state.dirty = false;
      await showScreen(tester, state, platform: platform);
      await tester.pumpAndSettle();
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(state.doc.objects, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Empty project'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('empty-project-import')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('empty-project-open')), findsOneWidget);
    });
  }

  for (final choice in ['Cancel', 'Escape', 'Discard']) {
    testWidgets('New project unsaved changes choice $choice', (tester) async {
      final state = NewProjectState();
      addTearDown(state.dispose);
      populate(state);
      state.projectPath = '/projects/扫描.mmx';
      await showScreen(tester, state);
      await tester.pumpAndSettle();
      await chooseNew(tester);
      expect(
        find.text('Save changes before starting a new project?'),
        findsOneWidget,
      );
      expect(find.textContaining('扫描.mmx'), findsOneWidget);
      // Repeated shortcuts must not stack confirmation dialogs.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      if (choice == 'Escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tap(find.text(choice));
      }
      await tester.pumpAndSettle();
      if (choice == 'Discard') {
        expect(state.doc.objects, isEmpty);
        expect(state.projectPath, isNull);
        expect(state.dirty, false);
      } else {
        expect(state.doc.objects.single.name, 'My scan');
        expect(state.projectPath, '/projects/扫描.mmx');
        expect(state.doc.canUndo, true);
        expect(state.sourceAttachments.single.bytes, [1, 2]);
        expect(state.dirty, true);
      }
    });
  }

  for (final result in ['saved', 'cancelled', 'failed']) {
    testWidgets('Save before New project: $result', (tester) async {
      final state = NewProjectState();
      addTearDown(state.dispose);
      populate(state);
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('mmx-new-save-');
      });
      addTearDown(() => dir.delete(recursive: true));
      final path = result == 'failed'
          ? '${dir.path}/missing/project.mmx'
          : '${dir.path}/project.mmx';
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      var dialogCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method != 'getSavePath') return null;
        dialogCalls++;
        return result == 'cancelled' ? null : path;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await showScreen(tester, state);
      await tester.pumpAndSettle();
      await chooseNew(tester);
      // Enter activates Save, never the destructive Discard action.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < const Duration(seconds: 10)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (dialogCalls > 0 &&
            !state.busy &&
            (result == 'cancelled' ||
                state.status.contains('failed') ||
                state.doc.objects.isEmpty)) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(dialogCalls, 1);
      if (result == 'saved') {
        final saved = await tester.runAsync(
          () async => ProjectIO.read(await File(path).readAsBytes()),
        );
        expect(saved!.objects.single.name, 'My scan');
        expect(saved.sourceAttachments.single.bytes, [1, 2]);
        expect(state.doc.objects, isEmpty);
        expect(state.projectPath, isNull);
      } else {
        expect(state.doc.objects.single.name, 'My scan');
        expect(state.dirty, true);
        expect(state.doc.canUndo, true);
      }
    });
  }
}
