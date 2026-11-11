import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:mmx_core/mmx_core.dart';

import 'gpu_packet.dart';

enum RenderBackendPreference { auto, cpu, gpu }

NativeGpuRenderer? _retainedRenderer;

/// Sendable across isolates. An API-backed software adapter is named explicitly;
/// successful native rendering does not imply physical GPU acceleration.
class DesktopRenderFrame {
  final Uint8List rgba;
  final String backend, diagnostic;
  final bool hardwareAccelerated;
  const DesktopRenderFrame(
    this.rgba, {
    required this.backend,
    required this.diagnostic,
    required this.hardwareAccelerated,
  });
}

/// Invoke in a worker isolate. Both auto and gpu preserve the CPU escape path;
/// gpu expresses a preference, while [NativeGpuRenderer.render] is strict.
DesktopRenderFrame renderDesktopFrame(
  List<RenderObject> objects,
  Camera camera,
  RenderOptions options, {
  RenderBackendPreference preference = RenderBackendPreference.auto,
  bool retainScene = false,
}) {
  GpuPacket.validateFrame(options);
  if (preference != RenderBackendPreference.cpu) {
    try {
      final renderer = retainScene
          ? (_retainedRenderer ??= NativeGpuRenderer())
          : NativeGpuRenderer();
      return renderer.render(
        objects,
        camera,
        options,
        retainScene: retainScene,
      );
    } on Object catch (error) {
      return DesktopRenderFrame(
        Rasterizer.render(objects, camera, options),
        backend: 'CPU fallback',
        diagnostic: 'Native GPU unavailable: $error',
        hardwareAccelerated: false,
      );
    }
  }
  return DesktopRenderFrame(
    Rasterizer.render(objects, camera, options),
    backend: 'CPU',
    diagnostic: 'Software rasterizer selected',
    hardwareAccelerated: false,
  );
}

typedef _AllocateNative = Pointer<Uint8> Function(Size);
typedef _Allocate = Pointer<Uint8> Function(int);
typedef _ReleaseNative = Void Function(Pointer<Void>);
typedef _Release = void Function(Pointer<Void>);
typedef _RenderNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
);
typedef _Render = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

class NativeGpuRenderer {
  List<RenderObject>? _lastObjects;
  Object? _lastGeometryOptions;
  Uint8List? _header;
  _NativeBuffer? _retainedInput, _retainedOutput, _retainedDiagnostic;

  final DynamicLibrary library;
  late final _Allocate _allocate = library
      .lookupFunction<_AllocateNative, _Allocate>('mmx_gpu_allocate');
  late final _Release _release = library
      .lookupFunction<_ReleaseNative, _Release>('mmx_gpu_release');
  late final _Render _render = library.lookupFunction<_RenderNative, _Render>(
    'mmx_gpu_render',
  );
  late final NativeFinalizer _finalizer = NativeFinalizer(
    library.lookup<NativeFunction<_ReleaseNative>>('mmx_gpu_release'),
  );

  NativeGpuRenderer({String? libraryPath})
    : library = DynamicLibrary.open(libraryPath ?? _libraryPath()) {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'mmx_gpu_abi_version',
    )();
    if (version != 1) {
      throw StateError('Unsupported GPU renderer ABI $version');
    }
  }

  static String _libraryPath() {
    final configured = Platform.environment['MMX_GPU_LIBRARY'];
    if (configured != null && configured.isNotEmpty) {
      return configured;
    }
    final executable = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isLinux) {
      return '$executable/lib/libmmx_gpu.so';
    }
    if (Platform.isWindows) {
      return '$executable/mmx_gpu.dll';
    }
    if (Platform.isMacOS) {
      return '$executable/../Frameworks/libmmx_gpu.dylib';
    }
    throw UnsupportedError('Native renderer supports Linux, Windows and macOS');
  }

  DesktopRenderFrame render(
    List<RenderObject> objects,
    Camera camera,
    RenderOptions options, {
    bool retainScene = false,
  }) {
    GpuPacket.validateFrame(options);
    final geometryOptions = (
      options.wireframe,
      options.showBed,
      options.showGrid,
      options.actualBedWidth,
      options.actualBedDepth,
      options.centerBed,
      options.flatShading,
    );
    _NativeBuffer input, output, diagnostic;
    if (retainScene) {
      if (!identical(objects, _lastObjects) ||
          geometryOptions != _lastGeometryOptions ||
          _retainedInput == null) {
        final packet = GpuPacket.encode(objects, camera, options);
        _retainedInput?.dispose();
        _retainedInput = _buffer(packet.length);
        _retainedInput!.pointer.asTypedList(packet.length).setAll(0, packet);
        _header = Uint8List.fromList(packet.sublist(0, 104));
        _lastObjects = objects;
        _lastGeometryOptions = geometryOptions;
      }
      final header = ByteData.sublistView(_header!);
      header.setUint32(8, options.width, Endian.little);
      header.setUint32(12, options.height, Endian.little);
      final frame = [
        ...options.background,
        1.0,
        ...camera.viewProjection(options.width / options.height),
        options.ambient,
      ];
      for (var i = 0; i < frame.length; i++) {
        if (!frame[i].isFinite) throw ArgumentError('Invalid GPU camera');
        header.setFloat32(20 + i * 4, frame[i], Endian.little);
        if (!header.getFloat32(20 + i * 4, Endian.little).isFinite) {
          throw ArgumentError('GPU camera exceeds float32 range');
        }
      }
      input = _retainedInput!;
      input.pointer.asTypedList(104).setAll(0, _header!);
      final size = options.width * options.height * 4;
      if (_retainedOutput?.size != size) {
        _retainedOutput?.dispose();
        _retainedOutput = _buffer(size);
      }
      output = _retainedOutput!;
      diagnostic = _retainedDiagnostic ??= _buffer(4096);
    } else {
      final packet = GpuPacket.encode(objects, camera, options);
      input = _buffer(packet.length);
      output = _buffer(options.width * options.height * 4);
      diagnostic = _buffer(4096);
      input.pointer.asTypedList(packet.length).setAll(0, packet);
    }
    try {
      final status = _render(
        input.pointer,
        input.size,
        output.pointer,
        output.size,
        diagnostic.pointer,
        diagnostic.size,
      );
      final bytes = diagnostic.pointer.asTypedList(diagnostic.size);
      final end = bytes.indexOf(0);
      final message = utf8.decode(
        bytes.sublist(0, end < 0 ? bytes.length : end),
        allowMalformed: true,
      );
      if (status < 0) {
        throw StateError(message.isEmpty ? 'GPU rendering failed' : message);
      }
      return DesktopRenderFrame(
        Uint8List.fromList(output.pointer.asTypedList(output.size)),
        backend: status == 0 ? 'GPU (wgpu)' : 'wgpu software adapter',
        diagnostic: message,
        hardwareAccelerated: status == 0,
      );
    } finally {
      if (!retainScene) {
        input.dispose();
        output.dispose();
        diagnostic.dispose();
      }
    }
  }

  _NativeBuffer _buffer(int length) {
    final pointer = _allocate(length);
    if (pointer == nullptr) {
      throw StateError('GPU native allocation rejected ($length bytes)');
    }
    return _NativeBuffer(pointer, length, _release, _finalizer);
  }
}

final class _NativeBuffer implements Finalizable {
  final Pointer<Uint8> pointer;
  final int size;
  final _Release release;
  final NativeFinalizer finalizer;
  bool disposed = false;
  _NativeBuffer(this.pointer, this.size, this.release, this.finalizer) {
    finalizer.attach(this, pointer.cast(), detach: this, externalSize: size);
  }
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    finalizer.detach(this);
    release(pointer.cast());
  }
}
