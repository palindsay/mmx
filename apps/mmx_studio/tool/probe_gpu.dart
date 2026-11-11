import 'dart:convert';
import 'dart:io';

import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/render/desktop_renderer.dart';

/// Capability evidence, not a hardware performance claim. Set MMX_GPU_LIBRARY
/// to test an uninstalled library. --require-native makes missing devices fail.
void main(List<String> args) {
  String? output;
  var requireNative = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--require-native') {
      requireNative = true;
    } else if (args[i] == '--output' && i + 1 < args.length) {
      output = args[++i];
    } else {
      stderr.writeln(
        'Usage: probe_gpu.dart [--require-native] [--output preview.png]',
      );
      exitCode = 2;
      return;
    }
  }
  final fixture = File.fromUri(
    Platform.script.resolve(
      '../../../packages/mmx_core/test/fixtures/models/sphere.obj',
    ),
  );
  final mesh = MeshIO.readBytes('sphere.obj', fixture.readAsBytesSync());
  final bounds = mesh.bounds();
  final camera = Camera()
    ..frame(
      bounds.minX,
      bounds.minY,
      bounds.minZ,
      bounds.maxX,
      bounds.maxY,
      bounds.maxZ,
    );
  final objects = [
    RenderObject(mesh, transform: identity4(), color: [.35, .65, .95]),
  ];
  const options = RenderOptions(
    width: 640,
    height: 480,
    showBed: false,
    showGrid: false,
  );
  final stopwatch = Stopwatch()..start();
  late DesktopRenderFrame frame;
  var nativeAvailable = false;
  int? warmMilliseconds;
  try {
    final renderer = NativeGpuRenderer();
    frame = renderer.render(objects, camera, options);
    nativeAvailable = true;
    final warm = Stopwatch()..start();
    renderer.render(objects, camera, options);
    warmMilliseconds = warm.elapsedMilliseconds;
  } on Object catch (error) {
    final cpu = renderDesktopFrame(
      objects,
      camera,
      options,
      preference: RenderBackendPreference.cpu,
    );
    frame = DesktopRenderFrame(
      cpu.rgba,
      backend: 'CPU fallback',
      diagnostic: error.toString(),
      hardwareAccelerated: false,
    );
    if (requireNative) {
      exitCode = 1;
    }
  }
  stopwatch.stop();
  if (output != null) {
    File(output).writeAsBytesSync(
      PngEncoder.encodeRGBA(frame.rgba, options.width, options.height),
    );
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'nativeAvailable': nativeAvailable,
      'backend': frame.backend,
      'hardwareAccelerated': frame.hardwareAccelerated,
      'diagnostic': frame.diagnostic,
      'faces': mesh.faceCount,
      'width': options.width,
      'height': options.height,
      'probeMilliseconds': stopwatch.elapsedMilliseconds,
      'warmFrameMilliseconds': warmMilliseconds,
      'note': 'Readback renderer; virtual/software adapter timings are not hardware performance evidence.',
    }),
  );
}
