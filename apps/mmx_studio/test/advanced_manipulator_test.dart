import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/manipulator.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/gizmo.dart';
import 'package:mmx_studio/ui/screen.dart';
import 'package:mmx_studio/ui/viewport.dart';

class PreviewState extends StudioState {
  PreviewState() : super(loadStartup: false);
  Completer<void>? gate;
  bool failPreview = false;
  @override
  Future<void> render() async {
    if (gate != null) await gate!.future;
    if (failPreview) throw StateError('preview unavailable');
  }
}

PreviewState scene() {
  final state = PreviewState();
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
      translation4(7, 11, 13),
      multiply4(rotation4(0, 0, 1, math.pi / 2), scale),
    )
    ..pivot = Pivot(position: [1, -2, .5], normal: [0, 0, 1]);
  state.selectedObjectId = object.id;
  state.frameSelection();
  return state;
}

void vectorClose(Iterable<double> actual, Iterable<double> expected) {
  final a = actual.toList(), b = expected.toList();
  expect(a.length, b.length);
  for (var i = 0; i < a.length; i++) {
    expect(a[i], closeTo(b[i], 1e-8), reason: 'component $i');
  }
}

List<double> column(Float64List matrix, int axis) => [
  for (var i = 0; i < 3; i++) matrix[axis * 4 + i],
];

double length(List<double> values) =>
    math.sqrt(values.fold<double>(0, (sum, value) => sum + value * value));

void main() {
  test('pivot conversion accepts strong nonuniform scaling without false singularity', () {
    final transform = identity4()
      ..[0] = 1e-5
      ..[5] = 1e5
      ..[10] = 4;
    final world = transformPoint(transform, [2, -3, 4]);
    vectorClose(inverseTransformPoint(transform, world), [2, -3, 4]);
    final object = SceneObject(
      1,
      '',
      TriMesh(Float32List(0), Uint32List(0)),
      transform: transform,
    )..pivot = Pivot.atPoint([2, -3, 4]);
    ManipulatorGesture(
      object,
      ManipulatorMode.pivot,
      0,
      space: ManipulatorSpace.local,
    ).preview(.5);
    vectorClose(object.pivot!.position, [50002, -3, 4]);
  });

  for (final space in ManipulatorSpace.values) {
    test('translation uses $space axes in world millimeters', () async {
      final state = scene();
      addTearDown(state.dispose);
      final before = Float64List.fromList(state.selected!.transform);
      state.setManipulatorSpace(space);
      state.setManipulatorMode(ManipulatorMode.translate);
      expect(await state.applyManipulatorAmount(0, 5), true);
      final moved = state.selected!.transform;
      vectorClose(moved.take(12), before.take(12));
      vectorClose(
        moved.sublist(12, 15),
        space == ManipulatorSpace.local ? [7, 6, 13] : [12, 11, 13],
      );
      expect(state.doc.undoDepth, 1);
      await state.undo();
      vectorClose(state.selected!.transform, before);
      await state.redo();
      vectorClose(state.selected!.transform, moved);
    });

    test(
      'axis and uniform scaling preserve a transformed pivot in $space',
      () async {
        for (final scaling in ManipulatorScaleMode.values) {
          final state = scene();
          try {
            final before = Float64List.fromList(state.selected!.transform);
            final pivot = objectPivotWorld(state.selected!);
            final volume = state.selected!.worldMesh().signedVolume();
            final positions = List<double>.from(state.selected!.mesh.positions);
            state.setManipulatorSpace(space);
            state.setManipulatorMode(ManipulatorMode.scale);
            state.setManipulatorScaleMode(scaling);
            expect(await state.applyManipulatorAmount(0, 1.5), true);
            vectorClose(objectPivotWorld(state.selected!), pivot);
            expect(state.selected!.mesh.positions, positions);
            final factor = scaling == ManipulatorScaleMode.uniform
                ? math.pow(1.5, 3)
                : 1.5;
            expect(
              state.selected!.worldMesh().signedVolume(),
              closeTo(volume * factor, 1e-5),
            );
            final after = state.selected!.transform;
            for (var axis = 0; axis < 3; axis++) {
              // The object has a 90-degree Z rotation. Its local X follows world −Y.
              final affected =
                  scaling == ManipulatorScaleMode.uniform ||
                  axis == (space == ManipulatorSpace.local ? 0 : 1);
              expect(
                length(column(after, axis)),
                closeTo(
                  length(column(before, axis)) * (affected ? 1.5 : 1),
                  1e-8,
                ),
              );
            }
            expect(state.doc.undoDepth, 1);
          } finally {
            state.dispose();
          }
        }
      },
    );
  }

  test(
    'local rotation is rigid despite nonuniform scale, around local pivot',
    () async {
      final state = scene();
      addTearDown(state.dispose);
      final pivot = objectPivotWorld(state.selected!);
      final point = transformPoint(state.selected!.transform, [0, 0, 0]);
      final relative = [for (var i = 0; i < 3; i++) point[i] - pivot[i]];
      state.setManipulatorSpace(ManipulatorSpace.local);
      state.setManipulatorMode(ManipulatorMode.rotate);
      await state.applyManipulatorAmount(0, math.pi / 2);
      vectorClose(objectPivotWorld(state.selected!), pivot);
      vectorClose(transformPoint(state.selected!.transform, [0, 0, 0]), [
        pivot[0] + relative[2],
        pivot[1] + relative[1],
        pivot[2] - relative[0],
      ]);
      for (var axis = 0; axis < 3; axis++) {
        expect(
          length(column(state.selected!.transform, axis)),
          closeTo(axis + 2, 1e-8),
        );
      }
      vectorClose(state.selected!.pivot!.normal, [0, 0, 1]);
    },
  );

  test('snap is gesture-relative, symmetric and commits one undo', () async {
    final state = scene();
    addTearDown(state.dispose);
    state.setManipulatorMode(ManipulatorMode.translate);
    state.setManipulatorSnap(
      const ManipulatorSnap(enabled: true, translation: 2),
    );
    expect(state.beginManipulator(0), true);
    state.updateManipulator(1.2);
    state.updateManipulator(3.2);
    state.updateManipulator(-3.2);
    expect(state.selected!.transform[12], 3);
    state.setManipulatorSpace(ManipulatorSpace.local);
    expect(
      state.manipulatorSpace,
      ManipulatorSpace.world,
      reason: 'settings lock during a drag',
    );
    expect(state.setManipulatorSnap(const ManipulatorSnap()), false);
    await state.endManipulator();
    expect(state.doc.undoDepth, 1);
    expect(state.interactionLocked, false);
    await state.undo();
    expect(state.selected!.transform[12], 7);
    state.setManipulatorMode(ManipulatorMode.scale);
    state.updateManipulator(1.3); // No active gesture cannot mutate anything.
    expect(await state.applyManipulatorAmount(0, 1.04), true);
    expect(
      state.doc.undoDepth,
      0,
      reason: 'a snap to neutral creates no history',
    );
    expect(await state.applyManipulatorAmount(0, 1.26), true);
    expect(state.selected!.transform[4], closeTo(3.9, 1e-8));
    state.setManipulatorMode(ManipulatorMode.rotate);
    state.setManipulatorSpace(ManipulatorSpace.local);
    final before = Float64List.fromList(state.selected!.transform);
    await state.applyManipulatorAmount(2, 23 * math.pi / 180);
    final a = column(before, 0), b = column(state.selected!.transform, 0);
    final cosine =
        List.generate(3, (i) => a[i] * b[i]).reduce((a, b) => a + b) /
        (length(a) * length(b));
    expect(cosine, closeTo(math.cos(math.pi / 6), 1e-8));
    expect(a[0] * b[1] - a[1] * b[0], lessThan(0));
  });

  test('moving a local pivot preserves mesh/transform and cancellation restores absence', () async {
    final state = scene();
    addTearDown(state.dispose);
    state.setManipulatorMode(ManipulatorMode.pivot);
    state.setManipulatorSpace(ManipulatorSpace.local);
    final before = Float64List.fromList(state.selected!.transform);
    expect(await state.applyManipulatorAmount(0, 4), true);
    vectorClose(state.selected!.transform, before);
    vectorClose(state.selected!.pivot!.position, [3, -2, .5]);
    expect(state.doc.undoDepth, 1);
    await state.undo();
    vectorClose(state.selected!.pivot!.position, [1, -2, .5]);
    state.selected!.pivot = null;
    state.dirty = false;
    expect(state.beginManipulator(1), true);
    state.updateManipulator(3);
    await state.endManipulator(cancel: true);
    expect(state.selected!.pivot, null);
    expect(state.dirty, false);
    expect(state.doc.undoDepth, 0);
    vectorClose(state.selected!.transform, before);
  });

  test('local scaling handles shear without shifting its pivot', () {
    final state = scene();
    addTearDown(state.dispose);
    final object = state.selected!;
    object.transform[8] += .6;
    final before = Float64List.fromList(object.transform);
    final pivot = objectPivotWorld(object);
    ManipulatorGesture(
      object,
      ManipulatorMode.scale,
      2,
      space: ManipulatorSpace.local,
      scaleMode: ManipulatorScaleMode.axis,
    ).preview(.5);
    vectorClose(objectPivotWorld(object), pivot);
    vectorClose(column(object.transform, 0), column(before, 0));
    vectorClose(column(object.transform, 1), column(before, 1));
    vectorClose(
      column(object.transform, 2),
      column(before, 2).map((x) => x * .5),
    );
  });

  test(
    'invalid inputs and failed preview do not leave a gesture lock',
    () async {
      final state = scene();
      addTearDown(state.dispose);
      state.setManipulatorMode(ManipulatorMode.scale);
      expect(await state.applyManipulatorAmount(0, double.nan), false);
      expect(await state.applyManipulatorAmount(0, -1), false);
      expect(
        state.setManipulatorSnap(const ManipulatorSnap(translation: 0)),
        false,
      );
      expect(state.doc.undoDepth, 0);
      state.setManipulatorMode(ManipulatorMode.translate);
      state.beginManipulator(0);
      state.updateManipulator(4);
      await Future<void>.delayed(Duration.zero); // Drain the scheduled preview.
      state.gate = Completer<void>();
      final completion = state.endManipulator();
      expect(state.interactionLocked, true);
      expect(state.beginManipulator(1), false);
      state.failPreview = true;
      state.gate!.complete();
      await completion;
      expect(state.interactionLocked, false);
      expect(state.selected!.transform[12], 11);
      expect(state.status, contains('Preview failed'));
      expect(state.doc.undoDepth, 1);
    },
  );

  test('gizmo local axes follow rotated object and axis scaling follows its handle', () {
    final state = scene();
    addTearDown(state.dispose);
    const size = Size(800, 600);
    state.setManipulatorSpace(ManipulatorSpace.world);
    final world = GizmoProjection.forState(state, size)!;
    state.setManipulatorSpace(ManipulatorSpace.local);
    final local = GizmoProjection.forState(state, size)!;
    vectorClose(local.directions[0], [0, -1, 0]);
    final worldY = world.handles[1]! - world.origin;
    final localX = local.handles[0]! - local.origin;
    expect(worldY.dx * localX.dx + worldY.dy * localX.dy, lessThan(0));
    final start = local.handles[0]!, direction = start - local.origin;
    expect(local.hitTest(start), 0);
    expect(
      local.dragAmount(ManipulatorMode.scale, 0, start, start + direction),
      closeTo(math.e, 1e-8),
    );
    final perpendicular = Offset(direction.dy, -direction.dx);
    expect(
      local.dragAmount(ManipulatorMode.scale, 0, start, start + perpendicular),
      closeTo(1, 1e-8),
    );
  });

  test('rotation ring stays pickable when its axis points at the camera', () {
    final state = scene();
    addTearDown(state.dispose);
    state.setManipulatorMode(ManipulatorMode.rotate);
    state.camera = Camera(
      yaw: 0,
      pitch: 0,
      distance: 30,
      target: objectPivotWorld(state.selected!),
    );
    final projection = GizmoProjection.forState(state, const Size(800, 600))!;
    expect(
      (projection.handles[2]! - projection.origin).distance,
      lessThan(1e-8),
    );
    final ring = projection.rotationRings[2];
    expect(projection.hitTest(ring[8]!), 2);
    expect(
      projection.dragAmount(ManipulatorMode.rotate, 2, ring[8]!, ring[24]!),
      closeTo(-math.pi / 2, 1e-8),
    );
  });

  testWidgets('rotation ring supports multiple turns with one snapped undo', (
    tester,
  ) async {
    final state = scene();
    state.setManipulatorMode(ManipulatorMode.rotate);
    state.setManipulatorSnap(
      const ManipulatorSnap(enabled: true, rotationDegrees: 90),
    );
    state.camera = Camera(
      yaw: 0,
      pitch: 0,
      distance: 30,
      target: objectPivotWorld(state.selected!),
    );
    final pivot = objectPivotWorld(state.selected!);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
    );
    await tester.pump();
    final view = find.byType(MeshViewport),
        offset = tester.getTopLeft(find.byType(MeshViewport));
    final projection = GizmoProjection.forState(state, tester.getSize(view))!;
    final ring = projection.rotationRings[2];
    final gesture = await tester.startGesture(
      offset + ring[8]!,
      kind: PointerDeviceKind.mouse,
    );
    for (final index in [16, 24, 32, 40, 48, 56, 0, 8, 16, 24]) {
      await gesture.moveTo(offset + ring[index]!);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.doc.undoDepth, 1);
    vectorClose(column(state.selected!.transform, 0), [2, 0, 0]);
    vectorClose(column(state.selected!.transform, 1), [0, 3, 0]);
    vectorClose(objectPivotWorld(state.selected!), pivot);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('a second pointer cannot end the owning transform drag', (
    tester,
  ) async {
    final state = scene();
    state.setManipulatorMode(ManipulatorMode.translate);
    await tester.pumpWidget(
      MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
    );
    await tester.pump();
    final view = find.byType(MeshViewport),
        offset = tester.getTopLeft(find.byType(MeshViewport));
    final projection = GizmoProjection.forState(state, tester.getSize(view))!;
    final before = Float64List.fromList(state.selected!.transform);
    final first = await tester.startGesture(
      offset + projection.handles[0]!,
      pointer: 1,
    );
    await first.moveBy(const Offset(20, 0));
    final second = await tester.startGesture(
      offset + projection.origin,
      pointer: 2,
    );
    await second.up();
    expect(state.manipulatorGestureActive, true);
    await first.cancel();
    await tester.pumpAndSettle();
    vectorClose(state.selected!.transform, before);
    expect(state.doc.undoDepth, 0);
    expect(state.interactionLocked, false);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('numeric controls submit local snapped movement with Enter', (
    tester,
  ) async {
    final state = scene();
    state.setManipulatorMode(ManipulatorMode.translate);
    state.setManipulatorSpace(ManipulatorSpace.local);
    state.setManipulatorSnap(
      const ManipulatorSnap(enabled: true, translation: .5),
    );
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('manipulator-amount')),
      '1.3',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    vectorClose(state.selected!.transform.sublist(12, 15), [7, 9.5, 13]);
    expect(state.doc.undoDepth, 1);
    state.setManipulatorMode(ManipulatorMode.scale);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('manipulator-amount')),
      '-2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Enter a factor from 0.01 to 100'), findsOneWidget);
    expect(state.doc.undoDepth, 1);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final cancel in ['pointer', 'escape']) {
    testWidgets(
      '$cancel cancellation restores transform and permits a fresh drag',
      (tester) async {
        final state = scene();
        state.setManipulatorMode(ManipulatorMode.scale);
        state.setManipulatorSpace(ManipulatorSpace.local);
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
        );
        await tester.pump();
        final view = find.byType(MeshViewport),
            before = Float64List.fromList(state.selected!.transform);
        final projection = GizmoProjection.forState(
          state,
          tester.getSize(view),
        )!;
        final origin = tester.getTopLeft(view), handle = projection.handles[0]!;
        final pointer = await tester.startGesture(
          origin + handle,
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveTo(
          origin + handle + (handle - projection.origin) * .3,
        );
        expect(state.gestureActive, true);
        expect(state.selected!.transform, isNot(equals(before)));
        if (cancel == 'pointer') {
          await pointer.cancel();
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await pointer.up();
        }
        await tester.pumpAndSettle();
        vectorClose(state.selected!.transform, before);
        expect(state.doc.undoDepth, 0);
        expect(state.interactionLocked, false);
        final again = await tester.startGesture(
          origin + handle,
          kind: PointerDeviceKind.mouse,
        );
        await again.moveTo(origin + handle + (handle - projection.origin) * .3);
        await again.up();
        await tester.pumpAndSettle();
        expect(state.doc.undoDepth, 1);
        expect(state.interactionLocked, false);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }
}
