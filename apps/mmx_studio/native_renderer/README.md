# Native depth-buffered renderer

Studio's optional renderer is a Rust `cdylib` behind a versioned C ABI. The Dart
kernel remains pure Dart. Pinned **wgpu 30.0.1** selects **Vulkan** on Linux,
**Direct3D 12** on Windows and **Metal** on macOS. OpenGL is disabled. This follows
wgpu's [native backend API](https://docs.rs/wgpu/30.0.1/wgpu/) and the repository's
existing renderer boundary, avoiding a deprecated macOS OpenGL dependency.

## Build and package

Install Rust **1.99.1** (`rustup toolchain install 1.99.1 --profile minimal`).
`rust-toolchain.toml` and `Cargo.lock` pin the build. Python 3.11+ collects third-party
notices. Normal `flutter build linux`, `flutter build windows`, and
`flutter build macos` build/embed the library and notices. macOS universal builds
also need `rustup target add --toolchain 1.99.1 aarch64-apple-darwin x86_64-apple-darwin`.
Linux needs a Vulkan loader/ICD at runtime; Mesa's software Vulkan driver is
sufficient for CI correctness tests. A working native adapter is optional at
runtime: missing libraries, drivers, device allocation or readback failures
produce an explicit CPU fallback diagnostic.

CMake installs `lib/libmmx_gpu.so` on Linux and `mmx_gpu.dll` beside the Windows
executable. Xcode embeds `Contents/Frameworks/libmmx_gpu.dylib`, signed with the
app's existing identity (ad-hoc for local builds). This does not provision or
perform distribution signing. Build scripts include target-specific dependency
license texts and their checksums in `native-licenses/index.json`. Published
crates missing notices use exact-commit upstream texts in `vendor_licenses/`,
with checked URL/hash provenance; release builds never fetch mutable notices.

## Rendering and supported attributes

WGSL vertex/fragment shaders render into RGBA8 with a **Depth32Float** attachment.
Depth writes and comparison resolve occlusion per fragment, including intersecting
triangles. Near/far clipping occurs in the graphics pipeline. Readback handles
256-byte row alignment and returns top-down RGBA to Flutter. There is no painter's
sort. Studio owns a persistent rendering isolate. Scene epochs replace geometry
only when the scene changes; camera-only requests reuse its retained packet and
update the camera header. Completed frames for the current scene are published
even while newer camera requests arrive, avoiding starvation during a drag.

The native backend retains one scene's vertex buffers and textures, comparing
the exact scene bytes before reuse. Camera-only frames update uniforms; scene
changes replace cached resources. The cache is process-wide and bounded to one
scene, so alternating windows/scenes can cause uploads. A native mutex serializes
calls. Device and pipelines are also reused within the process.

Flat/smooth normals, affine transforms (including reflection), selection tints,
analysis colors, wire edges, bed/grid, vertex RGB, diffuse RGBA and per-corner UV
textures are supported. Texture sampling is bilinear with clamp/repeat addressing;
UVs use v-up while image rows are top-down. The viewport uses **alpha cutout**:
combined alpha below 0.5 discards the fragment; retained fragments are opaque.
Sorted translucency, PBR, GPU picking and zero-copy
Flutter textures are outside this backend's current contract. Readback/upload
costs remain measurable; do not assume a frame-rate improvement on every model.

## Validation and capability evidence

From this directory run `cargo test --locked` and
`cargo clippy --locked --all-targets -- -D warnings`. From Studio, after a Linux
release build:

```sh
MMX_GPU_LIBRARY="$PWD/build/linux/x64/release/bundle/lib/libmmx_gpu.so" \
  flutter test test/gpu_renderer_test.dart
MMX_GPU_LIBRARY="$PWD/build/linux/x64/release/bundle/lib/libmmx_gpu.so" \
  dart run tool/probe_gpu.dart --require-native --output /tmp/mmx-gpu.png
```

The tests independently check submission-order depth, intersecting triangles,
near clipping, resizing, bounded input, missing-library fallback, retained scene
replacement, camera updates, UV orientation, texture sampling, bed visibility
and alpha-cutout parity with the CPU renderer. Studio's
`test/scene_render_worker_test.dart` checks continuous input, scene epochs,
worker restart and disposal separately. Without
`MMX_GPU_LIBRARY`, native capability tests are explicitly skipped; fallback and
packet tests still run. The JSON probe records adapter name/backend/type.
Software/unknown/virtual adapters never set `hardwareAccelerated=true`; passing
on Mesa llvmpipe proves graphics correctness, **not physical GPU performance**.
Native Metal/DX12 runtime validation requires their actual hosts.

## ABI and resource limits

ABI 1 exports `mmx_gpu_abi_version`, `mmx_gpu_allocate`, `mmx_gpu_release`, and
`mmx_gpu_render`. Allocated native buffers have Dart NativeFinalizers as well as
explicit cleanup, so worker-isolate cancellation does not abandon allocations.
Rust contains panics at the C boundary and returns diagnostics; invalid caller
pointers remain a C ABI contract violation. GPU readback waits are bounded.

The little-endian packet has a 104-byte header containing magic `0x47584d4d`, version, width, height,
draw count, RGBA background, camera matrix, and ambient value. Each draw contains
vertex count, primitive, flags, texture dimensions/byte count, model/normal
matrices, interleaved float vertices and RGBA texture bytes. Vertex stride is
16 floats: position 3, normal 3, color 4, UV 2, barycentric 3, selection 1.
Flags are unlit=1, wire=2, reflected=4, clamp=8, no-cull=16. Triangle/line counts,
finite attributes and exact packet consumption are checked before GPU submission.
Limits are 4096×4096 pixels, 4096 draws, four million expanded vertices,
4096×4096 texture dimensions, and 256 MiB total packet bytes. No unbounded counts
from a model are trusted. Scene replacement still serializes and copies geometry;
camera reuse avoids repeated GPU geometry uploads but retains byte comparison and
per-frame RGBA readback/Flutter image upload. Memory pressure can cause a reported
CPU fallback. These changes do not establish a sustained large-scan frame rate.
