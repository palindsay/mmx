import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/render/scene_render_worker.dart';
import 'package:mmx_studio/state/studio_state.dart';

TriMesh triangle() => TriMesh(
  Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]),
  Uint32List.fromList([0, 1, 2]),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'persistent worker reuses the scene and replaces it on a new epoch',
    () async {
      final worker = SceneRenderWorker();
      addTearDown(worker.dispose);
      final camera = Camera(yaw: 0, pitch: 0, distance: 4, near: .1, far: 100);
      const options = RenderOptions(
        width: 96,
        height: 96,
        showBed: false,
        showGrid: false,
        ambient: 1,
      );
      final object = RenderObject(
        triangle(),
        transform: identity4(),
        color: [1, 0, 0],
      );
      final first = await worker.render(
        [object],
        camera,
        options,
        RenderBackendPreference.cpu,
        1,
      );
      final cached = await worker.render(
        [],
        camera,
        options,
        RenderBackendPreference.cpu,
        1,
      );
      expect(cached.rgba, first.rgba);
      final removed = await worker.render(
        [],
        camera,
        options,
        RenderBackendPreference.cpu,
        2,
      );
      expect(removed.rgba, isNot(first.rgba));
      await expectLater(
        worker.render(
          [],
          camera,
          const RenderOptions(width: 0),
          RenderBackendPreference.cpu,
          2,
        ),
        throwsStateError,
      );
      final restarted = await worker.render(
        [object],
        camera,
        options,
        RenderBackendPreference.cpu,
        3,
      );
      expect(restarted.rgba, first.rgba);
      worker.dispose();
      await expectLater(
        worker.render([], camera, options, RenderBackendPreference.cpu, 3),
        throwsStateError,
      );
    },
  );
  test(
    'disposing during renderer startup delivers a handled failure',
    () async {
      final worker = SceneRenderWorker();
      final future = worker.render(
        [],
        Camera(),
        const RenderOptions(width: 96, height: 96),
        RenderBackendPreference.cpu,
        1,
      );
      worker.dispose();
      await expectLater(future, throwsStateError);
    },
  );
  test(
    'continuous camera input publishes current-scene frames before input stops',
    () async {
      final state = StudioState();
      addTearDown(state.dispose);
      state.renderBackendPreference = RenderBackendPreference.cpu;
      state.frameWidth = 640;
      state.frameHeight = 480;
      state.showBed = false;
      state.selectedObjectId = state.doc.add(triangle()).id;
      state.camera = Camera(yaw: 0, pitch: 0, distance: 4, near: .1, far: 100);
      await state.render();
      var previous = state.frame, frames = 0;
      void listener() {
        if (!identical(previous, state.frame)) {
          frames++;
          previous = state.frame;
        }
      }

      state.addListener(listener);
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => state.orbit(.001, 0),
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(
          frames,
          greaterThan(0),
          reason: 'Camera updates must not invalidate every completed frame',
        );
      } finally {
        timer.cancel();
        state.removeListener(listener);
      }
      await state.render();
    },
  );
}
