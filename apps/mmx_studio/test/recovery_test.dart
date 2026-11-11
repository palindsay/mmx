import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';

class RecoveryTestState extends StudioState {
  RecoveryTestState() : super(loadStartup: false);
  final finishAutosave = Completer<void>();
  int autosaveCount = 0;
  int completedAutosaveCount = 0;
  String? autosavePath;
  int saveCount = 0;
  @override
  Future<void> render() async {}

  @override
  Future<void> autosave(String path) async {
    if (!dirty) return;
    autosaveCount++;
    autosavePath = path;
    await finishAutosave.future;
    await File(path).writeAsString('older unsaved scene');
    completedAutosaveCount++;
  }

  @override
  Future<bool> saveProject(String path) async {
    saveCount++;
    dirty = false;
    return true;
  }
}

Future<void> flushFilesystem(WidgetTester tester) async {
  for (var i = 0; i < 32; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
}

class RecoveryPreviewState extends StudioState {
  RecoveryPreviewState() : super(loadStartup: false);
  @override
  Future<void> render() async {}
}

void main() {
  for (final interveningEdit in [false, true]) {
    testWidgets(
      'New project drains recovery and protects intervening edits ($interveningEdit)',
      (tester) async {
        late Directory dir;
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('mmx-new-recovery-');
        });
        final state = RecoveryTestState()..dirty = true;
        state.selectedObjectId = state.doc
            .add(
              TriMesh(
                Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
                Uint32List.fromList([0, 1, 2]),
              ),
              name: 'Old scan',
            )
            .id;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: StudioScreen(
                state: state,
                recoveryDirectory: () async => dir,
              ),
            ),
          );
          await flushFilesystem(tester);
          final other = File('${dir.path}/recovery-other.mmx');
          await tester.runAsync(() => other.writeAsString('another session'));
          await tester.pump(const Duration(seconds: 30));
          expect(state.autosaveCount, 1);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Discard'));
          await tester.pumpAndSettle();
          expect(
            state.doc.objects.single.name,
            'Old scan',
            reason:
                'Wait for the old recovery write before clearing the document',
          );
          if (interveningEdit) {
            state.doc.snapshot('Newer edit');
            state.doc.add(TriMesh.empty(), name: 'Newer scan');
          }
          state.finishAutosave.complete();
          final elapsed = Stopwatch()..start();
          var complete = false;
          while (elapsed.elapsed < const Duration(seconds: 10)) {
            await flushFilesystem(tester);
            complete =
                state.completedAutosaveCount == 1 &&
                (interveningEdit || state.doc.objects.isEmpty);
            if (complete) break;
          }
          expect(complete, true);
          expect(state.doc.objects.length, interveningEdit ? 2 : 0);
          expect(state.dirty, interveningEdit);
          expect(
            await tester.runAsync(() => File(state.autosavePath!).exists()),
            interveningEdit,
          );
          expect(await tester.runAsync(other.readAsString), 'another session');
        } finally {
          if (!state.finishAutosave.isCompleted) {
            state.finishAutosave.complete();
          }
          await tester.pumpWidget(const SizedBox());
          await flushFilesystem(tester);
          state.dispose();
          await tester.runAsync(() => dir.delete(recursive: true));
        }
      },
    );
  }

  for (final decision in ['Keep for later', 'Discard recovery']) {
    testWidgets('recovery choice $decision affects only its candidate', (
      tester,
    ) async {
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('mmx-recovery-choice-');
        await File('${dir.path}/recovery.mmx').writeAsString('original');
      });
      final state = RecoveryPreviewState();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StudioScreen(
              state: state,
              recoveryDirectory: () async => dir,
            ),
          ),
        );
        await flushFilesystem(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text(decision));
        await flushFilesystem(tester);
        await tester.pumpAndSettle();
        expect(
          await tester.runAsync(
            () => File('${dir.path}/recovery.mmx').exists(),
          ),
          decision == 'Keep for later',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushFilesystem(tester);
        state.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'successful recovery persists own copy before clearing candidate',
    (tester) async {
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('mmx-recovery-copy-');
        final mesh = TriMesh(
          Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
          Uint32List.fromList([0, 1, 2]),
        );
        await File('${dir.path}/recovery.mmx').writeAsBytes(
          ProjectIO.write(ProjectData([SceneObject(1, 'recovered', mesh)])),
        );
      });
      final state = RecoveryPreviewState();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: StudioScreen(
              state: state,
              recoveryDirectory: () async => dir,
            ),
          ),
        );
        await flushFilesystem(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recover'));
        await flushFilesystem(tester);
        await tester.pumpAndSettle();
        expect(state.dirty, true);
        expect(state.projectPath, isNull);
        await tester.runAsync(() async {
          expect(await File('${dir.path}/recovery.mmx').exists(), false);
          final files = await dir
              .list()
              .where((e) => e.path.endsWith('.mmx'))
              .toList();
          expect(files, hasLength(1));
          final saved = ProjectIO.read(
            await File(files.single.path).readAsBytes(),
          );
          expect(saved.objects.single.name, 'recovered');
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushFilesystem(tester);
        state.dispose();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
  testWidgets('macOS save shortcut works from the initial viewport focus', (
    tester,
  ) async {
    final state = RecoveryTestState()
      ..dirty = true
      ..projectPath = '/unused/test.mmx';
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: StudioScreen(state: state, enableRecovery: false),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(state.saveCount, 1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    }
  });

  testWidgets('saving joins an older recovery write before deleting it', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('mmx-recovery-');
    });
    final state = RecoveryTestState()
      ..dirty = true
      ..projectPath = '${dir.path}/saved.mmx';
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StudioScreen(state: state, recoveryDirectory: () async => dir),
        ),
      );
      await flushFilesystem(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(state.autosaveCount, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(state.saveCount, 1);
      state.finishAutosave.complete();
      // A fixed filesystem delay can expire between the write and queued
      // deletion on a busy runner. Require the write to finish before checking
      // absence, otherwise an unwritten file could incorrectly pass this test.
      final elapsed = Stopwatch()..start();
      var cleared = false;
      while (elapsed.elapsed < const Duration(seconds: 10)) {
        await tester.pump();
        cleared =
            await tester.runAsync(
              () async =>
                  state.completedAutosaveCount == 1 &&
                  !await File(state.autosavePath!).exists(),
            ) ??
            false;
        if (cleared) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(state.completedAutosaveCount, 1);
      expect(cleared, isTrue, reason: 'Recovery cleanup: ${state.status}');
      expect(
        await tester.runAsync(() => File(state.autosavePath!).exists()),
        false,
      );
    } finally {
      if (!state.finishAutosave.isCompleted) state.finishAutosave.complete();
      await tester.pumpWidget(const SizedBox());
      await flushFilesystem(tester);
      state.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    }
  });

  testWidgets('unreadable recovery stays intact and is never autosaved over', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('mmx-recovery-invalid-');
      await File('${dir.path}/recovery.mmx').writeAsString('corrupt recovery');
    });
    final state = RecoveryTestState();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StudioScreen(state: state, recoveryDirectory: () async => dir),
        ),
      );
      await flushFilesystem(tester);
      await tester.pumpAndSettle();
      expect(find.text('Recover unsaved project?'), findsOneWidget);
      await tester.tap(find.text('Recover'));
      await flushFilesystem(tester);
      await tester.pumpAndSettle();
      expect(state.status, contains('failed'));
      expect(state.dirty, false);
      await tester.pump(const Duration(minutes: 1));
      expect(state.autosaveCount, 0);
      expect(
        await tester.runAsync(
          () => File('${dir.path}/recovery.mmx').readAsString(),
        ),
        'corrupt recovery',
      );
      state.dirty = true;
      state.finishAutosave.complete();
      await tester.pump(const Duration(seconds: 30));
      await flushFilesystem(tester);
      expect(state.autosavePath, isNot('${dir.path}/recovery.mmx'));
      await tester.runAsync(() async {
        expect(await File(state.autosavePath!).exists(), true);
        expect(
          await File('${dir.path}/recovery.mmx').readAsString(),
          'corrupt recovery',
        );
      });
    } finally {
      if (!state.finishAutosave.isCompleted) state.finishAutosave.complete();
      await tester.pumpWidget(const SizedBox());
      await flushFilesystem(tester);
      state.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    }
  });
}
