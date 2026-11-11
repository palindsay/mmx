import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';

TriMesh triangle() => TriMesh(
  Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
  Uint32List.fromList([0, 1, 2]),
);

class ControlledRenderState extends StudioState {
  ControlledRenderState({this.holdCall}) : super(loadStartup: false);
  final int? holdCall;
  final entered = Completer<void>();
  final release = Completer<void>();
  final failCalls = <int>{};
  var calls = 0;
  @override
  Future<void> render() async {
    calls++;
    if (failCalls.contains(calls)) throw StateError('Injected preview failure');
    if (calls == holdCall) {
      entered.complete();
      await release.future;
    }
  }
}

Future<String> writeProject(Directory dir) async {
  final path = '${dir.path}/scene.mmx';
  await File(path).writeAsBytes(
    ProjectIO.write(
      ProjectData([SceneObject(99, 'loaded', triangle())], selectedId: 99),
    ),
  );
  return path;
}

void main() {
  test(
    'clamped layout callbacks do not continuously reschedule previews',
    () async {
      final state = ControlledRenderState();
      try {
        state.setFrameSize(5000, 0);
        await Future<void>.delayed(Duration.zero);
        expect(state.calls, 1);
        for (var i = 0; i < 5; i++) {
          state.setFrameSize(5000 + i, -i);
          await Future<void>.delayed(Duration.zero);
        }
        expect(state.frameWidth, 4096);
        expect(state.frameHeight, 1);
        expect(state.calls, 1);
        state.setFrameSize(600, 400);
        await Future<void>.delayed(Duration.zero);
        expect(state.calls, 2);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'scheduled preview failures report status and allow a later render',
    () async {
      final state = ControlledRenderState()..failCalls.add(1);
      try {
        state.setFrameSize(600, 400);
        await Future<void>.delayed(Duration.zero);
        expect(state.status, contains('Preview failed'));
        state.setFrameSize(601, 400);
        await Future<void>.delayed(Duration.zero);
        expect(state.calls, 2);
        expect(state.interactionLocked, false);
      } finally {
        state.dispose();
      }
    },
  );

  for (final operation in ['open', 'save', 'import']) {
    testWidgets('$operation keeps edits locked through final preview', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('mmx-completion-');
        final state = ControlledRenderState(
          holdCall: operation == 'save' ? 1 : 2,
        );
        state.selectedObjectId = state.doc.add(triangle()).id;
        state.dirty = true;
        try {
          final path = await writeProject(dir);
          final input = '${dir.path}/input.obj';
          await File(input).writeAsBytes(MeshIO.writeBytes(input, triangle()));
          final Future<void> pending = switch (operation) {
            'open' => state.openProject(path),
            'save' => state.saveProject(path),
            _ => state.importPath(input),
          };
          await state.entered.future;
          expect(state.busy, true);
          expect(state.interactionLocked, true);
          await state.transformSelected(translation4(10, 0, 0));
          expect(state.selected!.transform[12], 0);
          state.release.complete();
          await pending;
          expect(state.busy, false);
          expect(state.dirty, operation == 'import');
          await state.transformSelected(translation4(10, 0, 0));
          expect(state.selected!.transform[12], 10);
          expect(state.dirty, true);
        } finally {
          if (!state.release.isCompleted) state.release.complete();
          state.dispose();
          await dir.delete(recursive: true);
        }
      });
    });
  }

  for (final asRecovery in [false, true]) {
    testWidgets(
      'open completion listener preserves its new edit ($asRecovery)',
      (tester) async {
        await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('mmx-listener-');
          final state = ControlledRenderState();
          Future<void>? edit;
          bool? dirtyAtUnlock;
          String? pathAtUnlock;
          try {
            final path = await writeProject(dir);
            void onReady() {
              if (!state.busy && state.selected?.id == 99) {
                state.removeListener(onReady);
                dirtyAtUnlock = state.dirty;
                pathAtUnlock = state.projectPath;
                edit = state.transformSelected(translation4(7, 0, 0));
              }
            }

            state.addListener(onReady);
            expect(await state.openProject(path, asRecovery: asRecovery), true);
            expect(edit, isNotNull);
            await edit;
            expect(dirtyAtUnlock, asRecovery);
            expect(pathAtUnlock, asRecovery ? null : path);
            expect(state.selected!.transform[12], 7);
            expect(state.dirty, true);
          } finally {
            state.dispose();
            await dir.delete(recursive: true);
          }
        });
      },
    );
  }

  testWidgets(
    'failed incoming preview restores document metadata and history',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('mmx-open-preview-');
        final state = ControlledRenderState()..failCalls.addAll([1, 2]);
        state.selectedObjectId = state.doc.add(triangle(), name: 'unsaved').id;
        state.doc.snapshot('prior edit');
        state.dirty = true;
        state.projectPath = 'original.mmx';
        state.camera = Camera(distance: 17);
        final source = ProjectSourceAttachment(
          name: 'original.mix',
          bytes: Uint8List.fromList([1, 2]),
        );
        state.sourceAttachments.add(source);
        try {
          final path = await writeProject(dir);
          expect(await state.openProject(path), false);
          expect(state.selected!.name, 'unsaved');
          expect(state.doc.undoDepth, 1);
          expect(state.sourceAttachments, [source]);
          expect(state.camera.distance, 17);
          expect(state.projectPath, 'original.mmx');
          expect(state.dirty, true);
          expect(state.busy, false);
          expect(state.status, contains('Preview failed'));
          await state.transformSelected(translation4(2, 0, 0));
          expect(state.selected!.transform[12], 2);
        } finally {
          state.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('successful disk save survives final preview failure', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('mmx-save-preview-');
      final state = ControlledRenderState()..failCalls.add(1);
      state.selectedObjectId = state.doc.add(triangle(), name: 'saved').id;
      state.dirty = true;
      try {
        final path = '${dir.path}/saved.mmx';
        expect(await state.saveProject(path), true);
        final saved = ProjectIO.read(await File(path).readAsBytes());
        expect(saved.objects.single.name, 'saved');
        expect(state.dirty, false);
        expect(state.projectPath, path);
        expect(state.busy, false);
        expect(state.status, contains('Preview failed'));
        await state.transformSelected(translation4(3, 0, 0));
        expect(state.dirty, true);
      } finally {
        state.dispose();
        await dir.delete(recursive: true);
      }
    });
  });

  testWidgets('cancelling incoming preview preserves the previous document', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('mmx-open-cancel-');
      final state = ControlledRenderState(holdCall: 1);
      state.selectedObjectId = state.doc.add(triangle(), name: 'unsaved').id;
      state.dirty = true;
      try {
        final pending = state.openProject(await writeProject(dir));
        await state.entered.future;
        state.cancelOperation();
        state.release.complete();
        expect(await pending, false);
        expect(state.selected!.name, 'unsaved');
        expect(state.dirty, true);
        expect(state.busy, false);
        expect(state.status, contains('cancelled'));
      } finally {
        if (!state.release.isCompleted) state.release.complete();
        state.dispose();
        await dir.delete(recursive: true);
      }
    });
  });

  testWidgets('unrenderable archived camera preserves previous unsaved scene', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('mmx-invalid-view-');
      final state = StudioState(loadStartup: false)
        ..frameWidth = 32
        ..frameHeight = 32;
      state.selectedObjectId = state.doc.add(triangle(), name: 'unsaved').id;
      state.dirty = true;
      try {
        final path = await writeProject(dir);
        final entries = ZipArchive.read(await File(path).readAsBytes());
        final altered = entries.map((entry) {
          if (entry.name != 'manifest.json') return entry;
          final manifest = jsonDecode(utf8.decode(entry.data)) as Map;
          (manifest['camera'] as Map)['fov'] = 1e-308;
          return ZipEntry(
            entry.name,
            Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
          );
        }).toList();
        await File(path).writeAsBytes(ZipArchive.write(altered));
        expect(await state.openProject(path), false);
        expect(state.selected!.name, 'unsaved');
        expect(state.dirty, true);
        expect(state.busy, false);
      } finally {
        state.dispose();
        await dir.delete(recursive: true);
      }
    });
  });
}
