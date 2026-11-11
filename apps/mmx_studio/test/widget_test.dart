import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/main.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/viewport.dart';

void main() {
  testWidgets('studio shell renders', (tester) async {
    await tester.pumpWidget(const MmxStudioApp());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('MESH STUDIO'), findsOneWidget);
  });

  testWidgets('UI state drives a kernel operator end to end', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      // Wait for the startup model to load and render.
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull, reason: 'startup model must load');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = state.selected!.mesh.faceCount;
      state.reducePercent = 0.3;
      await state.doReduce();
      final after = state.selected!.mesh.faceCount;
      expect(after, lessThan(before));
      expect(state.doc.canUndo, isTrue);
      expect(state.status, contains('Reduce'));
    });
    state.dispose();
  });

  testWidgets('narrow layout hides the properties panel behind a drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MmxStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // Panel is gone from the row, replaced by the drawer affordance.
    expect(find.text('OBJECTS'), findsNothing);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mirror operator is wired through app state', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      final b = state.selected!.mesh.bounds();
      state.mirrorPlaneOffset = b.maxX;
      state.mirrorKeepOriginal = false;
      await state.doMirror();
      final nb = state.selected!.mesh.bounds();
      expect(nb.minX, greaterThan(b.maxX - 1.0));
      expect(state.status, contains('Mirror'));
    });
    state.dispose();
  });

  testWidgets('modify rail item opens the remaining edit actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MmxStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.auto_fix_high));
    await tester.pump();
    expect(find.text('Flip normals'), findsOneWidget);
    expect(find.text('Combine all'), findsOneWidget);
    expect(find.text('Measure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flip normals and measure run through app state', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      final volumeBefore = state.selected!.mesh.signedVolume();
      await state.doFlipNormals();
      expect(
        state.selected!.mesh.signedVolume(),
        closeTo(-volumeBefore, volumeBefore.abs() * 0.01),
      );
      await state.doMeasure();
      expect(state.status, contains('Measure'));
      expect(state.status, contains('shell'));
      expect(state.status, contains('volume'));
    });
    state.dispose();
  });

  testWidgets('stamp runs through app state', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      final before = state.selected!.mesh.signedVolume();
      state.stampRadius = 8;
      state.stampHeight = 2;
      await state.doStamp();
      expect(state.status, contains('Stamp'));
      expect(state.selected!.mesh.signedVolume(), greaterThan(before));
    });
    state.dispose();
  });

  testWidgets('align to target runs through app state', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      await state.doDuplicate();
      final copy = state.selected!;
      expect(state.doc.objects.length, 2);
      await state.doAlignToTarget();
      expect(state.status, contains('Aligned'));
      final target = state.doc.objects.firstWhere((o) => o.id != copy.id);
      final rms = AlignTool.rmsDistance(copy.mesh, target.mesh);
      expect(rms, lessThan(0.5));
    });
    state.dispose();
  });

  testWidgets('mix scene import loads mesh objects', (tester) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      await state.importPath('test/fixtures/sample.mix');
      expect(state.status, contains('Imported'));
      final imported = state.doc.objects
          .where((o) => o.mesh.faceCount == 10996)
          .toList();
      expect(imported, isNotEmpty);
      expect(state.selected!.mesh.vertexCount, 5550);
    });
    state.dispose();
  });

  testWidgets('touch pinch gesture zooms the camera', (tester) async {
    final state = StudioState(loadStartup: true);
    final before = state.camera.distance;
    final first = TestPointer(1, PointerDeviceKind.touch);
    final second = TestPointer(2, PointerDeviceKind.touch);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MeshViewport(state: state)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final center = tester.getCenter(find.byType(MeshViewport));
    await tester.sendEventToBinding(first.down(center - const Offset(40, 0)));
    await tester.sendEventToBinding(second.down(center + const Offset(40, 0)));
    await tester.sendEventToBinding(first.move(center - const Offset(80, 0)));
    await tester.sendEventToBinding(second.move(center + const Offset(80, 0)));
    await tester.pump();
    expect(state.camera.distance, lessThan(before));
    await tester.sendEventToBinding(first.up());
    await tester.sendEventToBinding(second.up());
    state.dispose();
  });

  testWidgets('extract and make part are wired through app state', (
    tester,
  ) async {
    late StudioState state;
    await tester.runAsync(() async {
      state = StudioState(loadStartup: true);
      for (var i = 0; i < 100 && state.selected == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(state.selected, isNotNull);
      await state.selectAll();
      final before = state.doc.objects.length;
      await state.extractSelection();
      expect(state.doc.objects.length, greaterThan(before));
      expect(state.status, contains('Extracted'));
      final afterExtract = state.doc.objects.length;
      expect(state.selection, isNull);
      await state.selectAll();
      await state.makePart();
      expect(state.doc.objects.length, greaterThan(afterExtract));
      expect(state.status, contains('solid part'));
      await state.doCreatePivot();
      expect(state.selected!.pivot, isNotNull);
      expect(state.status, contains('Pivot'));
    });
    state.dispose();
  });
}
