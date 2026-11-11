import 'dart:async';
import 'dart:isolate';

import 'package:mmx_core/mmx_core.dart';

import 'desktop_renderer.dart';

/// One owned renderer isolate per document window. Camera-only requests reuse
/// the retained scene instead of copying every mesh across isolates per frame.
/// The caller coalesces frames; this worker permits one request at a time.
class SceneRenderWorker {
  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _commands;
  Completer<void>? _starting;
  Completer<DesktopRenderFrame>? _pending;
  bool _disposed = false;
  int? _epoch;

  Future<void> _start() {
    if (_commands != null) return Future<void>.value();
    if (_starting != null) return _starting!.future;
    final started = _starting = Completer<void>();
    final events = _events = ReceivePort();
    events.listen((dynamic message) {
      if (message is SendPort) {
        _commands = message;
        if (!started.isCompleted) started.complete();
        return;
      }
      if (message is DesktopRenderFrame) {
        final pending = _pending;
        _pending = null;
        pending?.complete(message);
        return;
      }
      final error = StateError('Renderer worker failed: $message');
      if (!started.isCompleted) started.completeError(error);
      final pending = _pending;
      _pending = null;
      pending?.completeError(error);
      _commands = null;
      _epoch = null;
      _starting = null;
      events.close();
      _events = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
    });
    // Return the startup future immediately so disposal is always observed by
    // its caller, even before Isolate.spawn has finished creating the child.
    unawaited(
      Isolate.spawn(
        _entry,
        events.sendPort,
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'mmx persistent renderer',
      ).then(
        (child) {
          if (_disposed || !identical(_events, events)) {
            child.kill(priority: Isolate.immediate);
          } else {
            _isolate = child;
          }
        },
        onError: (Object error, StackTrace trace) {
          events.close();
          _starting = null;
          if (!started.isCompleted) started.completeError(error, trace);
        },
      ),
    );
    return started.future;
  }

  Future<DesktopRenderFrame> render(
    List<RenderObject> objects,
    Camera camera,
    RenderOptions options,
    RenderBackendPreference preference,
    int sceneEpoch,
  ) async {
    if (_disposed) throw StateError('Renderer disposed');
    await _start();
    if (_disposed) throw StateError('Renderer disposed');
    if (_pending != null) {
      throw StateError('Concurrent render requests must be coalesced');
    }
    final pending = _pending = Completer<DesktopRenderFrame>();
    _commands!.send((
      _epoch == sceneEpoch ? null : objects,
      camera,
      options,
      preference,
    ));
    _epoch = sceneEpoch;
    return pending.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _events?.close();
    _events = null;
    if (_starting != null && !_starting!.isCompleted) {
      _starting!.completeError(StateError('Renderer disposed'));
    }
    _pending?.completeError(StateError('Renderer disposed'));
    _pending = null;
  }

  static void _entry(SendPort parent) {
    final commands = ReceivePort();
    parent.send(commands.sendPort);
    List<RenderObject> scene = [];
    commands.listen((dynamic message) {
      try {
        final request =
            message
                as (
                  List<RenderObject>?,
                  Camera,
                  RenderOptions,
                  RenderBackendPreference,
                );
        if (request.$1 != null) scene = request.$1!;
        parent.send(
          renderDesktopFrame(
            scene,
            request.$2,
            request.$3,
            preference: request.$4,
            retainScene: true,
          ),
        );
      } catch (error, trace) {
        parent.send(['$error', '$trace']);
      }
    });
  }
}
