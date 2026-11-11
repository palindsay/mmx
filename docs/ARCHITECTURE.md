# Architecture

mmx separates a pure Dart geometry kernel from a Flutter desktop application.
Linux, Windows and macOS are the tested desktop targets. Mobile scaffolding is
outside the current release contract. Recovered Meshmixer behavior informs the
clean-room design; it does not establish exact algorithm equivalence.

## Components

| Location | Responsibility |
|---|---|
| `packages/mmx_core/lib/src/mesh/` | Typed mesh buffers, surface attributes, topology and allocation limits |
| `spatial/` | Triangle BVH for ray, nearest-point and overlap queries |
| `repair/`, `remesh/`, `solid/` | Repair, subdivision, reduction, remeshing, SDF reconstruction and booleans |
| `tools/`, `analysis/`, `fab/` | Editing, measurement, UV projection, supports, packing and slicing |
| `io/` | Bounded mesh/project parsers, textures, archive validation and atomic output |
| `scan/` | Shared scan inspection, physical printer profiles, cleanup recipes, sampled deviation and provenance |
| `scene/` | Objects, transforms, pivots, incremental undo/redo and rollback |
| `render/` | Camera, independent CPU rasterizer and CLI PNG rendering |
| `apps/mmx_studio/lib/state/` | Transactions, worker ownership, gestures and recovery |
| `apps/mmx_studio/lib/ui/` | Flutter controls, dialogs, viewport and accessibility |
| `apps/mmx_studio/lib/render/` | Native packets, versioned FFI boundary and CPU fallback |
| `apps/mmx_studio/native_renderer/` | Pinned Rust/wgpu renderer, shaders, platform builds and notices |

## Geometry and attributes

Positions use `Float32List`; triangle indices use `Uint32List`. Optional buffers
hold face groups, vertex RGB, per-corner UVs and per-face material indices.
Corner UVs preserve seams without duplicating geometric vertices. Materials and
textures are immutable; texture source bytes and decoded pixels are retained.
Reflected transforms reverse winding and UV corner order.

Operators preserve attributes where correspondence is defined. Reconstruction
and unsupported topology edits reject surface attributes; users can explicitly
remove them. OBJ/MTL and the supported 3MF subset preserve diffuse colors/textures.
Native projects retain the editable scene and unknown original `.mix` bytes as
source attachments. Project schema 3 also stores protected originals, scan history
and printer settings; schema 1/2 readers migrate missing fields to defaults.
Studio checks a conservative save budget before accepting changed documents: 240 MiB
binary payload, 8 MiB metadata estimate, 4096 entries, 1024 objects/sources and
192 MiB encoded-plus-decoded textures. Save performs exact archive validation.

Remeshing uses split/collapse/flip/relax/project passes with validated topology.
Reduction uses versioned QEM candidates. Precise booleans classify and stitch
meshes, with an explicitly reported voxel fallback. SDF operations use bounded
grids and distance bands covering requested offsets. These are documented
approximations, not proprietary Meshmixer implementations.

Optional minimum-wall operations verify continuous inward-normal opposing-surface
clearance on the final mesh. Reconstruction attempts and growth are bounded;
ambiguous surface-net topology can use a reported marching-tetrahedra fallback
on the same grid before verification. Invalid, unsupported or exhausted cases
fail transactionally. The [metric and assumptions](WALL-THICKNESS.md) explicitly
exclude general self-intersection, strength and manufacturing certification.

## Transactions and history

Workers receive plain Dart data through owned isolates. Cancellation terminates
CPU work; operation IDs and document revisions reject stale results. Transactions
capture a rollback point and hold the interaction lock through the final preview.
A failed preview after a committed save does not undo that disk write. Exports
encode in cancellable workers, then commit encoded bytes after revision and
cancellation checks. OBJ companions stage before atomic main-file replacement.

History stores immutable geometry blocks and shares unchanged blocks across
entries. Sparse edits retain changed blocks; metadata-only edits reuse geometry.
Byte comparisons protect against hash collisions. Live arrays never alias history
blocks, and checkpoints preserve both history stacks. Undo restores changed mesh
arrays while reusing unchanged live meshes. Byte and entry budgets bound retained
history payload; transient checkpoints and VM overhead are separate memory costs.
See [incremental undo evidence](performance/INCREMENTAL-UNDO.md).

Manipulators capture axes, pivot and transform at gesture start. World/local
translation and rotation, axis/uniform scale, snapping and numeric entry use the
same preview/commit path. Each completed gesture adds one history entry;
cancellation restores the captured state. Sculpt strokes group dabs similarly.

## Rendering

The desktop backend uses wgpu through a versioned C ABI: Vulkan on Linux,
Direct3D 12 on Windows and Metal on macOS. A depth attachment resolves per-fragment
occlusion, including intersecting triangles. The kernel remains independent of
Rust and Flutter. The CPU rasterizer serves CLI output, explicit selection and
native-driver failures.

Frames render off the UI isolate and coalesce during rapid interactions. Flutter
uploads returned RGBA pixels; this is not a zero-copy texture integration.
An owned renderer isolate retains the scene across camera requests. Native devices,
pipelines, mesh buffers and textures persist; camera-only frames update uniforms.
A scene epoch invalidates retained geometry, while completed current-scene frames
can publish during continuous camera input. The native cache retains one scene
and compares packet bodies exactly; alternating windows replace that cache. Native buffers have explicit cleanup and finalizers. Resource limits
bound packets, textures and frame dimensions.

Both paths support diffuse materials, bilinear textures, UV seams, selection,
analysis colors and alpha cutout. Alpha below 0.5 discards a fragment; surviving
fragments are opaque. Sorted translucency and PBR are outside the contract.
The UI reports actual backend/adapter capability and fallback reasons.
See the [renderer guide](../apps/mmx_studio/native_renderer/README.md).

## Verification and release boundaries

Unit, property and bounded mutation tests check geometry invariants, file fidelity,
transactions and attribute round trips. Native integration exercises editing,
keyboard/pointer workflows, persistence and export. Renderer tests independently
check depth, clipping, resize and texture parity. Three-platform CI builds apps
and installers, validates provenance and tests installation/removal.

[Testing](TESTING.md), [performance](PERFORMANCE.md) and
[production readiness](PRODUCTION-READINESS.md) carry current evidence.
Hosted measurements are observations rather than interactive release budgets.
Publisher signatures, human acceptance and independently acquired reference
outputs remain separate release gates. Neither analytical correctness nor a
successful build establishes full Meshmixer parity.
