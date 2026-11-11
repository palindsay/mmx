import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/manipulator.dart';
import 'package:mmx_studio/state/studio_state.dart';

class WallState extends StudioState {
  WallState() : super(loadStartup: false);
  @override
  Future<void> render() async {}
}

TriMesh box(double halfSize) => Modify.fitPrimitive(
  TriMesh(
    Float32List.fromList([
      -halfSize,
      -halfSize,
      -halfSize,
      halfSize,
      halfSize,
      halfSize,
    ]),
    Uint32List(0),
  ),
  PrimitiveKind.box,
);

void main() {
  test(
    'verified solid uses world millimeters and preserves pivot through undo',
    () async {
      final state = WallState();
      try {
        final object = state.doc.add(box(2));
        object.transform = multiply4(
          translation4(2, 3, 4),
          multiply4(
            rotation4(1, 2, 3, .7),
            identity4()
              ..[0] = 1.5
              ..[5] = .25
              ..[10] = .75,
          ),
        );
        object.pivot = Pivot.atPoint([.5, .5, .5], normal: [1, 1, 0]);
        final beforePivot = objectPivotWorld(object);
        final beforeTransform = Float64List.fromList(object.transform);
        state.selectedObjectId = object.id;
        state.solidMinThickness = 1.2;
        state.solidResolution = 32;
        await state.doMakeSolid();
        expect(
          state.status,
          contains('Verified inward-normal clearance'),
          reason: state.status,
        );
        expect(state.selected!.transform, identity4());
        expect(state.status, contains('marching tetrahedra'));
        expect(objectPivotWorld(state.selected!), beforePivot);
        expect(WallThickness.certify(state.activeMesh!, 1.2).passed, true);
        expect(state.doc.undoDepth, 1);
        expect(state.dirty, true);
        await state.undo();
        expect(state.selected!.transform, beforeTransform);
        expect(objectPivotWorld(state.selected!), beforePivot);
        expect(state.activeMesh!.positions, box(2).positions);
      } finally {
        state.dispose();
      }
    },
  );

  test('unsupported verified modes fail transactionally and enclosed hollow succeeds', () async {
    final state = WallState();
    try {
      state.selectedObjectId = state.doc.add(box(10)).id;
      final before = Float32List.fromList(state.activeMesh!.positions);
      state.solidMinThickness = 2;
      state.solidMode = SolidMode.fast;
      await state.doMakeSolid();
      expect(state.status, contains('requires Accurate or Blocky'));
      expect(state.doc.undoDepth, 0);
      expect(state.activeMesh!.positions, before);
      state.hollowMinThickness = 2;
      state.hollowThickness = 2;
      state.hollowHoles = 3;
      state.solidResolution = 32;
      await state.doHollow();
      expect(state.status, contains('enclosed shell'));
      expect(state.doc.undoDepth, 0);
      expect(state.dirty, false);
      state.hollowHoles = 0;
      await state.doHollow();
      expect(
        state.status,
        contains('Verified inward-normal clearance'),
        reason: state.status,
      );
      expect(state.status, contains('shell'));
      expect(WallThickness.certify(state.activeMesh!, 2).passed, true);
      expect(state.doc.undoDepth, 1);
    } finally {
      state.dispose();
    }
  });
}
