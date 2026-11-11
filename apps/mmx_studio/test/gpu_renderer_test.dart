import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmx_core/mmx_core.dart';
import 'package:mmx_studio/render/desktop_renderer.dart';
import 'package:mmx_studio/render/gpu_packet.dart';

TriMesh triangle(double z) => TriMesh(
  Float32List.fromList([-1, -1, z, 1, -1, z, 0, 1, z]),
  Uint32List.fromList([0, 1, 2]),
);
RenderObject object(TriMesh mesh, List<double> color) =>
    RenderObject(mesh, transform: identity4(), color: color);
final camera = Camera(yaw: 0, pitch: 0, distance: 4, near: .1, far: 100);
const options = RenderOptions(
  width: 96,
  height: 96,
  showBed: false,
  showGrid: false,
  ambient: 1,
);
List<int> pixel(Uint8List rgba, int x, int y, {int width = 96}) =>
    rgba.sublist((y * width + x) * 4, (y * width + x) * 4 + 4);

void main() {
  test('CPU preference is explicit and missing native backend falls back', () {
    final objects = [
      object(triangle(0), [1, 0, 0]),
    ];
    final cpu = renderDesktopFrame(
      objects,
      camera,
      options,
      preference: RenderBackendPreference.cpu,
    );
    expect(cpu.backend, 'CPU');
    expect(cpu.hardwareAccelerated, isFalse);
    expect(pixel(cpu.rgba, 48, 48), [255, 0, 0, 255]);
    expect(
      () => NativeGpuRenderer(libraryPath: '/missing/mmx-gpu-library'),
      throwsArgumentError,
    );
    if (Platform.environment['MMX_GPU_LIBRARY'] == null) {
      final automatic = renderDesktopFrame(objects, camera, options);
      expect(automatic.backend, 'CPU fallback');
      expect(automatic.diagnostic, contains('Native GPU unavailable'));
      expect(automatic.rgba, cpu.rgba);
    }
  });
  test('bounded scene packet rejects frame and malformed attribute inputs', () {
    expect(
      () => GpuPacket.encode([], camera, const RenderOptions(width: 4097)),
      throwsArgumentError,
    );
    expect(
      () => GpuPacket.encode([], camera, const RenderOptions(height: 0)),
      throwsArgumentError,
    );
    final bad = triangle(0)..positions[0] = double.nan;
    expect(
      () => GpuPacket.encode(
        [
          object(bad, [1, 0, 0]),
        ],
        camera,
        options,
      ),
      throwsArgumentError,
    );
    final singular = RenderObject(
      triangle(0),
      transform: List.filled(16, 0),
      color: [1, 0, 0],
    );
    expect(
      () => GpuPacket.encode([singular], camera, options),
      throwsArgumentError,
    );
    final bytes = GpuPacket.encode(
      [
        object(triangle(0), [1, 0, 0]),
      ],
      camera,
      options,
    );
    expect(ByteData.sublistView(bytes).getUint32(0, Endian.little), 0x47584d4d);
    expect(bytes.length, 104 + 152 + 3 * 64 + 4);
  });
  final nativePath = Platform.environment['MMX_GPU_LIBRARY'];
  group(
    'native depth-buffered rendering',
    () {
      late NativeGpuRenderer gpu;
      setUpAll(() => gpu = NativeGpuRenderer(libraryPath: nativePath));
      test('retained geometry handles camera changes, resize and scene replacement', () {
        final scene = [
          object(triangle(0), [1, 0, 0]),
        ];
        final first = gpu.render(scene, camera, options, retainScene: true);
        expect(pixel(first.rgba, 48, 48), [255, 0, 0, 255]);
        final moved = camera.clone()..target = [20, 0, 0];
        final next = gpu.render(scene, moved, options, retainScene: true);
        expect(pixel(next.rgba, 48, 48), isNot([255, 0, 0, 255]));
        expect(
          gpu.render(scene, camera, options, retainScene: true).rgba,
          first.rgba,
        );
        const resized = RenderOptions(
          width: 48,
          height: 48,
          showBed: false,
          showGrid: false,
          ambient: 1,
        );
        expect(
          pixel(
            gpu.render(scene, camera, resized, retainScene: true).rgba,
            24,
            24,
            width: 48,
          ),
          [255, 0, 0, 255],
        );
        final replacement = [
          object(triangle(0), [0, 0, 1]),
        ];
        expect(
          pixel(
            gpu.render(replacement, camera, options, retainScene: true).rgba,
            48,
            48,
          ),
          [0, 0, 255, 255],
        );
      });
      test('real depth occlusion is independent of triangle submission order', () {
        final near = object(triangle(.5), [1, 0, 0]),
            far = object(triangle(-.5), [0, 0, 1]);
        final first = gpu.render([near, far], camera, options);
        final second = gpu.render([far, near], camera, options);
        expect(pixel(first.rgba, 48, 48), [255, 0, 0, 255]);
        expect(first.rgba, second.rgba);
        expect(first.diagnostic, contains('wgpu'));
        expect(
          first.diagnostic,
          anyOf(contains('Vulkan'), contains('Metal'), contains('Dx12')),
        );
        if (first.diagnostic.contains('Cpu')) {
          expect(first.hardwareAccelerated, isFalse);
        }
        // Compare the interior point with the independent software z-buffer.
        expect(
          pixel(first.rgba, 48, 48),
          pixel(Rasterizer.render([far, near], camera, options), 48, 48),
        );
        // Submission order alone cannot solve intersecting triangles: the front
        // surface varies across the image within the same primitive pair.
        final crossing = triangle(0)
          ..positions.setAll(0, [-1, -1, 1, 1, -1, -1, 0, 1, 0]);
        final plane = triangle(0)
          ..positions.setAll(0, [-1, -1, 0, 1, -1, 0, 0, 1, 0]);
        final mixed = gpu.render(
          [
            object(crossing, [1, 0, 0]),
            object(plane, [0, 0, 1]),
          ],
          camera,
          options,
        );
        expect(pixel(mixed.rgba, 38, 58)[0], 255);
        expect(pixel(mixed.rgba, 58, 58)[2], 255);
      });
      test('bed outline keeps below-bed geometry visible and mesh depth intact', () {
        TriMesh belowBed(double y) => TriMesh(
          Float32List.fromList([1.3, y, 1.3, 2.3, y, 3.3, 3.3, y, 1.3]),
          Uint32List.fromList([0, 1, 2]),
        );
        final above = Camera(
          yaw: 0,
          pitch: .75,
          distance: 6,
          target: [2.3, -.5, 2.3],
          near: .1,
          far: 100,
        );
        final near = object(belowBed(-.5), [1, 0, 0]);
        final far = object(belowBed(-1.2), [0, 0, 1]);
        final withoutBed = gpu.render([near, far], above, options);
        expect(pixel(withoutBed.rgba, 48, 48), [255, 0, 0, 255]);
        expect(pixel(gpu.render([far], above, options).rgba, 48, 48), [
          0,
          0,
          255,
          255,
        ]);
        for (final (showBed, showGrid) in [
          (true, false),
          (false, true),
          (true, true),
        ]) {
          final withBed = RenderOptions(
            width: 96,
            height: 96,
            showBed: showBed,
            showGrid: showGrid,
            bedSize: 20,
            ambient: 1,
          );
          final first = gpu.render([near, far], above, withBed);
          final reversed = gpu.render([far, near], above, withBed);
          final cpu = Rasterizer.render([far, near], above, withBed);
          // The sightline crosses the bed interior between grid lines. Only
          // mesh surfaces may cover this pixel; the bed is not an opaque floor.
          expect(
            pixel(first.rgba, 48, 48),
            pixel(withoutBed.rgba, 48, 48),
            reason: 'showBed=$showBed, showGrid=$showGrid',
          );
          expect(pixel(first.rgba, 48, 48), pixel(cpu, 48, 48));
          expect(first.rgba, reversed.rgba);
          if (showGrid) expect(first.rgba, isNot(withoutBed.rgba));
        }
        // Zoom out so the complete bed boundary is in view. The outline must
        // still be drawn, while its empty center remains background-colored.
        final overview = Camera(yaw: .6, pitch: .75, distance: 35);
        final plain = gpu.render([], overview, options);
        final outlined = gpu.render(
          [],
          overview,
          const RenderOptions(
            width: 96,
            height: 96,
            showBed: true,
            showGrid: false,
            bedSize: 20,
            ambient: 1,
          ),
        );
        expect(outlined.rgba, isNot(plain.rgba));
        expect(pixel(outlined.rgba, 48, 48), pixel(plain.rgba, 48, 48));
      });
      test(
        'near-plane clipping and frame resize retain a valid depth attachment',
        () {
          final crossing = triangle(0)..positions[2] = 3.95;
          final image = gpu.render(
            [
              object(crossing, [0, 1, 0]),
            ],
            camera,
            options,
          );
          expect(
            image.rgba.where((v) => v == 255).length,
            greaterThan(96 * 96),
          );
          const resized = RenderOptions(
            width: 73,
            height: 41,
            showBed: false,
            showGrid: false,
            ambient: 1,
          );
          final next = gpu.render(
            [
              object(triangle(0), [1, 0, 0]),
            ],
            camera,
            resized,
          );
          expect(next.rgba.length, 73 * 41 * 4);
          expect(pixel(next.rgba, 36, 20, width: 73), [255, 0, 0, 255]);
        },
      );
      test(
        'UV texture orientation, alpha cutout and material tint match CPU',
        () {
          final mesh =
              TriMesh(
                  Float32List.fromList([
                    -1,
                    -1,
                    0,
                    1,
                    -1,
                    0,
                    1,
                    1,
                    0,
                    -1,
                    1,
                    0,
                  ]),
                  Uint32List.fromList([0, 1, 2, 0, 2, 3]),
                )
                ..cornerUvs = Float32List.fromList([
                  0,
                  0,
                  1,
                  0,
                  1,
                  1,
                  0,
                  0,
                  1,
                  1,
                  0,
                  1,
                ])
                ..faceMaterials = Uint16List(2)
                ..materials = [
                  MeshMaterial(
                    baseColor: [1, 1, 1, 1],
                    textureClamp: true,
                    texture: MeshTexture(
                      name: 'test',
                      mimeType: 'image/png',
                      width: 2,
                      height: 2,
                      bytes: Uint8List.fromList([1]),
                      rgba: Uint8List.fromList([
                        255,
                        0,
                        0,
                        255,
                        0,
                        255,
                        0,
                        255,
                        0,
                        0,
                        255,
                        255,
                        255,
                        255,
                        255,
                        0,
                      ]),
                    ),
                  ),
                ];
          final objects = [
            object(triangle(-.5), [1, 0, 1]),
            object(mesh, [1, 1, 1]),
          ];
          final image = gpu.render(objects, camera, options);
          expect(pixel(image.rgba, 35, 35)[0], greaterThan(200));
          expect(pixel(image.rgba, 61, 35)[1], greaterThan(200));
          expect(pixel(image.rgba, 35, 61)[2], greaterThan(200));
          expect(pixel(image.rgba, 55, 58), [255, 0, 255, 255]);
          final cpu = Rasterizer.render(objects, camera, options);
          for (final point in [
            [35, 35],
            [61, 35],
            [35, 61],
            [55, 58],
          ]) {
            final actual = pixel(image.rgba, point[0], point[1]);
            final expected = pixel(cpu, point[0], point[1]);
            // Bilinear interpolation/UNORM rounding differs by one channel
            // level between the Mesa and NVIDIA adapters and Dart doubles.
            // Keep orientation, cutout alpha and depth assertions exact above.
            for (var channel = 0; channel < 3; channel++) {
              expect(
                (actual[channel] - expected[channel]).abs(),
                lessThanOrEqualTo(1),
                reason: 'point $point channel $channel',
              );
            }
            expect(actual[3], expected[3]);
          }
          mesh.materials = [
            MeshMaterial(
              baseColor: [.5, .75, 1, .8],
              textureClamp: true,
              texture: mesh.materials.single.texture,
            ),
          ];
          final tinted = gpu.render(objects, camera, options);
          final tintedCpu = Rasterizer.render(objects, camera, options);
          final tintedPixel = pixel(tinted.rgba, 35, 35);
          expect(tintedPixel[0], inInclusiveRange(100, 200));
          final expectedTint = pixel(tintedCpu, 35, 35);
          for (var channel = 0; channel < 3; channel++) {
            expect(
              (tintedPixel[channel] - expectedTint[channel]).abs(),
              lessThanOrEqualTo(1),
            );
          }
          expect(tintedPixel[3], 255);
        },
      );
    },
    skip: nativePath == null
        ? 'Set MMX_GPU_LIBRARY to the compiled native library to require capability tests'
        : false,
  );
}
