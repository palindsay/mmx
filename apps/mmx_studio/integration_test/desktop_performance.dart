// Opt-in: this filename deliberately does not end in _test.dart.
// See desktop_performance.md beside this file for execution and metric limits.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/state/studio_state.dart';
import 'package:mmx_studio/ui/screen.dart';

const _hostId = String.fromEnvironment('MMX_PERF_HOST_ID');
const _toolchain = String.fromEnvironment('MMX_PERF_TOOLCHAIN');
const _reportPath = String.fromEnvironment('MMX_PERF_REPORT');
const _revision = String.fromEnvironment('MMX_PERF_REVISION');

// A closed, outward-oriented periodic torus: 50,176 vertices, 100,352 faces.
// No external assets or kernel refinement are needed to reproduce this input.
TriMesh _torus() {
  const segments = 224, rings = 224;
  const majorRadius = 20.0, minorRadius = 5.0;
  final positions = Float32List(segments * rings * 3);
  final indices = Uint32List(segments * rings * 6);
  for (var u = 0; u < segments; u++) {
    final theta = 2 * math.pi * u / segments;
    for (var v = 0; v < rings; v++) {
      final phi = 2 * math.pi * v / rings;
      final radius = majorRadius + minorRadius * math.cos(phi);
      final vertex = u * rings + v;
      positions[vertex * 3] = radius * math.cos(theta);
      positions[vertex * 3 + 1] = minorRadius * math.sin(phi);
      positions[vertex * 3 + 2] = radius * math.sin(theta);
      final a = vertex;
      final b = ((u + 1) % segments) * rings + v;
      final c = ((u + 1) % segments) * rings + (v + 1) % rings;
      final d = u * rings + (v + 1) % rings;
      indices.setRange(vertex * 6, vertex * 6 + 6, [a, c, b, a, d, c]);
    }
  }
  return TriMesh(positions, indices);
}

String _fingerprint(TriMesh mesh) {
  var hash = 0x811c9dc5;
  for (final bytes in [
    mesh.positions.buffer.asUint8List(),
    mesh.indices.buffer.asUint8List(),
  ]) {
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Map<String, Object?> _distribution(List<int> samples) {
  if (samples.isEmpty) return {'samples': 0, 'samplesMicroseconds': <int>[]};
  final ordered = [...samples]..sort();
  double percentile(double p) =>
      ordered[((ordered.length - 1) * p).ceil()] / 1000;
  return {
    'samples': samples.length,
    'samplesMicroseconds': List<int>.of(samples),
    'medianMs': percentile(.5),
    'p95Ms': percentile(.95),
    'maxMs': ordered.last / 1000,
  };
}

/// Samples UI-isolate timers and framework post-frame callbacks. Scheduling a
/// frame each turn keeps cadence measurable even when the scene is stationary.
/// These are framework completion intervals, not GPU/presentation timings.
class _UiProbe {
  _UiProbe(this.state, {this.onHeartbeat});
  final StudioState state;
  final VoidCallback? onHeartbeat;
  final clock = Stopwatch();
  final heartbeatIntervals = <int>[];
  final workerHeartbeatIntervals = <int>[];
  final frameIntervals = <int>[];
  final workerFrameIntervals = <int>[];
  Timer? _timer;
  bool _running = false;
  int _lastHeartbeat = 0, _lastFrame = 0;
  int? workerStartUs, workerEndUs;
  int sampledPeakRss = 0;

  void start() {
    _running = true;
    clock.start();
    state.addListener(_observePhase);
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = clock.elapsedMicroseconds;
      final interval = now - _lastHeartbeat;
      heartbeatIntervals.add(interval);
      if (state.operationPhase == 'Computing') {
        workerHeartbeatIntervals.add(interval);
      }
      _lastHeartbeat = now;
      sampledPeakRss = math.max(sampledPeakRss, ProcessInfo.currentRss);
      onHeartbeat?.call();
    });
    SchedulerBinding.instance.addPostFrameCallback(_frame);
    SchedulerBinding.instance.scheduleFrame();
  }

  void _observePhase() {
    if (state.operationPhase == 'Computing') {
      workerStartUs ??= clock.elapsedMicroseconds;
    } else if (workerStartUs != null) {
      workerEndUs ??= clock.elapsedMicroseconds;
    }
  }

  void _frame(Duration _) {
    if (!_running) return;
    final now = clock.elapsedMicroseconds;
    final interval = now - _lastFrame;
    frameIntervals.add(interval);
    if (state.operationPhase == 'Computing') {
      workerFrameIntervals.add(interval);
    }
    _lastFrame = now;
    SchedulerBinding.instance.addPostFrameCallback(_frame);
    SchedulerBinding.instance.scheduleFrame();
  }

  Map<String, Object?> stop() {
    _running = false;
    _timer?.cancel();
    state.removeListener(_observePhase);
    clock.stop();
    final elapsed = clock.elapsedMicroseconds;
    return {
      'operationCompletionMs': elapsed / 1000,
      'workerAwaitPhaseMs': workerStartUs == null || workerEndUs == null
          ? null
          : (workerEndUs! - workerStartUs!) / 1000,
      'heartbeatTargetMs': 16,
      'heartbeatIntervals': _distribution(heartbeatIntervals),
      'heartbeatIntervalsDuringWorker': _distribution(workerHeartbeatIntervals),
      'postFrameIntervals': _distribution(frameIntervals),
      'postFrameIntervalsDuringWorker': _distribution(workerFrameIntervals),
      'finalHeartbeatTailMs': (elapsed - _lastHeartbeat) / 1000,
      'finalPostFrameTailMs': (elapsed - _lastFrame) / 1000,
      'sampledPeakProcessRssBytes': sampledPeakRss,
      'processHighWaterRssBytes': ProcessInfo.maxRss,
      'rendererAtCompletion': {
        'preference': state.renderBackendPreference.name,
        'backend': state.renderBackend,
        'hardwareAccelerated': state.hardwareAccelerated,
        'diagnostic': state.renderDiagnostic,
      },
    };
  }
}

Future<String?> _cpuDescription() async {
  if (Platform.isLinux) {
    final lines = await File('/proc/cpuinfo').readAsLines();
    return lines
        .where((line) => line.startsWith('model name'))
        .firstOrNull
        ?.split(':')
        .last
        .trim();
  }
  if (Platform.isMacOS) {
    final result = await Process.run('/usr/sbin/sysctl', [
      '-n',
      'machdep.cpu.brand_string',
    ]);
    return result.exitCode == 0 ? result.stdout.toString().trim() : null;
  }
  return Platform.environment['PROCESSOR_IDENTIFIER'];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('opt-in native UI responsiveness and cancellation', (
    tester,
  ) async {
    expect(_hostId, isNotEmpty, reason: 'Set --dart-define=MMX_PERF_HOST_ID');
    expect(
      _toolchain,
      isNotEmpty,
      reason: 'Set --dart-define=MMX_PERF_TOOLCHAIN',
    );
    final state = StudioState(loadStartup: false);
    final input = _torus();
    expect(input.validate(), isEmpty);
    expect(MeshTopology(input).boundaryLoops(), isEmpty);
    expect(MeshTopology(input).nonManifoldEdges(), isEmpty);
    expect(input.signedVolume(), greaterThan(0));
    state.selectedObjectId = state.doc.add(input, name: '100k torus').id;
    state.frameSelection();
    _UiProbe? activeProbe;
    try {
      await tester.pumpWidget(
        MaterialApp(home: StudioScreen(state: state, enableRecovery: false)),
      );
      await state.render();
      await tester.pumpAndSettle();
      // Warm the framework animation/timer path, not the measured geometry
      // operator. This reports one cold Reduce and one cancellation attempt.
      final idle = _UiProbe(state)..start();
      activeProbe = idle;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final idleResult = idle.stop();
      activeProbe = null;

      state.reducePercent = .5;
      final reduce = _UiProbe(state)..start();
      activeProbe = reduce;
      await state.doReduce().timeout(const Duration(minutes: 2));
      final reduceResult = reduce.stop();
      activeProbe = null;
      expect(reduce.workerHeartbeatIntervals, isNotEmpty);
      expect(reduce.workerFrameIntervals, isNotEmpty);
      expect(state.status, contains('Reduce done'));
      expect(state.activeMesh!.faceCount, lessThan(input.faceCount));
      final outputFaces = state.activeMesh!.faceCount;
      expect(state.activeMesh!.validate(), isEmpty);
      expect(MeshTopology(state.activeMesh!).boundaryLoops(), isEmpty);
      expect(MeshTopology(state.activeMesh!).nonManifoldEdges(), isEmpty);

      await state.undo();
      expect(state.activeMesh!.faceCount, input.faceCount);
      final undoDepth = state.doc.undoDepth;
      int? cancelRequestedUs;
      late final _UiProbe cancel;
      cancel = _UiProbe(
        state,
        onHeartbeat: () {
          if (cancelRequestedUs == null &&
              state.operationPhase == 'Computing') {
            cancelRequestedUs = cancel.clock.elapsedMicroseconds;
            state.cancelOperation();
          }
        },
      )..start();
      activeProbe = cancel;
      await state.doReduce().timeout(const Duration(minutes: 2));
      final cancelResult = cancel.stop();
      activeProbe = null;
      expect(cancelRequestedUs, isNotNull);
      expect(state.busy, false);
      expect(state.status, contains('cancelled'));
      expect(state.activeMesh!.faceCount, input.faceCount);
      expect(state.doc.undoDepth, undoDepth);
      cancelResult['requestToOperationCompletionMs'] =
          (cancel.clock.elapsedMicroseconds - cancelRequestedUs!) / 1000;
      cancelResult['requestToWorkerPhaseEndMs'] = cancel.workerEndUs == null
          ? null
          : (cancel.workerEndUs! - cancelRequestedUs!) / 1000;

      final report = <String, Object?>{
        'schemaVersion': 2,
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'provenance': {'gitRevision': _revision, 'harnessVersion': 3},
        'host': {
          'id': _hostId,
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'abi': Abi.current().toString(),
          'cpu': await _cpuDescription(),
          'logicalProcessors': Platform.numberOfProcessors,
          'displayEnvironment': Platform.environment['DISPLAY'],
        },
        'runtime': {
          'declaredToolchain': _toolchain,
          'dart': Platform.version,
          'buildMode': kDebugMode
              ? 'debug'
              : (kProfileMode ? 'profile' : 'release'),
          'framePolicy': 'fullyLive',
          'viewportLogicalPixels': [state.frameWidth, state.frameHeight],
          'devicePixelRatio': tester.view.devicePixelRatio,
          'rendererPreference': state.renderBackendPreference.name,
        },
        'workload': {
          'generator':
              'periodic torus 224x224, major radius 20, minor radius 5',
          'vertices': input.vertexCount,
          'faces': input.faceCount,
          'fnv1a32LittleEndianMeshBytes': _fingerprint(input),
          'operator': 'StudioState.doReduce / Decimator.reduce',
          'percentage': .5,
          'outputFaces': outputFaces,
          'samples': 1,
          'operatorWarmups': 0,
        },
        'idle500ms': idleResult,
        'reduce': reduceResult,
        'cancelReduceOnFirstWorkerHeartbeat': cancelResult,
        'processHighWaterRssBytes': ProcessInfo.maxRss,
        'limits': [
          'Heartbeat and framework post-frame intervals measure UI isolate '
              'progress; they are not kernel-only or GPU presentation timings.',
          'Worker await phase includes isolate startup/result transfer; overall '
              'completion also includes checkpoint, validation and render.',
          'Continuous framework frames are requested by this probe; scene '
              'rasterization still follows normal Studio scheduling.',
          'Process RSS includes Flutter, all isolates, setup and validation; '
              'the process high-water mark cannot reset between samples.',
          'A single headless capture cannot certify interactive presentation '
              'frame rates or establish timing regressions; compare recorded '
              'build modes separately.',
        ],
      };
      final json = const JsonEncoder.withIndent('  ').convert(report);
      // A native integration executable may not inherit the invoking shell CWD.
      // Require an absolute output path; also print a machine-readable marker.
      if (_reportPath.isNotEmpty) {
        expect(File(_reportPath).isAbsolute, true);
        await File(_reportPath).writeAsString('$json\n');
      }
      // ignore: avoid_print
      print('MMX_UI_PERFORMANCE_JSON ${jsonEncode(report)}');
      binding.reportData = report;
    } finally {
      activeProbe?.stop();
      await state.cancelInteraction();
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
