# mmx

A clean-room, cross-platform mesh studio and geometry kernel built from a
reverse engineering study of **Autodesk Meshmixer 3.5.0**.

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.13%2B-blue)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.47%2B-02569B)](https://flutter.dev)
[![CI](https://github.com/palindsay/mmx/actions/workflows/ci.yml/badge.svg)](https://github.com/palindsay/mmx/actions/workflows/ci.yml)

> **Status: 0.3.0 candidate, pre-1.0.** The core geometry workflows are usable and tested; the
> release acceptance is tracked in [`docs/PRODUCTION-READINESS.md`](docs/PRODUCTION-READINESS.md).
> The source is Apache-2.0. Sample models are Autodesk assets; see
> [`NOTICE`](NOTICE).

## What this is

mmx has two parts:

- **`mmx_core`** - a pure-Dart geometry kernel: import/export, topology,
  repair, remeshing, decimation, SDF solidification, booleans, analysis,
  supports, packing and slicing.
- **`mmx_studio`** - a Flutter desktop app for selection, sculpting, repair,
  remesh/reduce, solid/hollow, plane cuts, mirroring, supports, analysis and
  print preparation.

The reverse-engineering report is part of the repository:
[`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md). It separates
**[observed]** evidence from **[inferred]** conclusions and **[unknown]**
constants, and documents the `.mix` binary format, RTTI, recovered method names
and tool semantics.

## Documentation

- [Quick start: build and run](QUICKSTART.md)
- [Studio scan-to-print workflow](apps/mmx_studio/README.md#scan-to-print)
- [Contributor guide](CONTRIBUTING.md)
- [Documentation index](docs/README.md)
- [Reverse-engineering report](docs/REVERSE-ENGINEERING.md)
- [Tool and action coverage](docs/TOOL-MATRIX.md)
- [CLI reference](docs/CLI.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Testing and coverage](docs/TESTING.md)
- [Production readiness and remaining release gates](docs/PRODUCTION-READINESS.md)
- [Installers, signing and rollback](docs/RELEASE.md)
- [Performance measurement](docs/PERFORMANCE.md)
- [Historical desktop feature checkpoint](docs/FEATURE-COMPLETION.md)
- [Finish plan](docs/FINISH-PLAN.md)
- [Remediation plan](docs/REMEDIATION-PLAN.md)

## Features

**Formats:** OBJ, PLY, STL (binary/ASCII), OFF, 3MF (OPC zip) and native
Meshmixer `.mix` scenes. The `.mix` reader supports VFMesh 1.2 and 1.3, face
groups and lossless rewrite of unknown records. Native `.mmx` projects preserve
the whole editable scene and original imported `.mix` bytes. OBJ/OFF/PLY support
concave polygons; PLY accepts ASCII and both binary byte orders. Unsupported
3MF material/extension semantics fail explicitly. Supported diffuse colors,
PNG/JPEG textures and seam-safe UVs round-trip through OBJ/MTL, 3MF and projects.

**Geometry:** CSR topology, BVH raycast/closest-point, weld, crack closing,
hole filling, non-manifold splitting, defect inspection, isotropic and
adaptive remeshing, QEM and uniform decimation, SDF voxelization, surface-nets
polygonization, Make Solid, offset, hollow, booleans with an explicit fallback,
plane cutting with capping, mirroring, extrusion, shell separation, ICP
alignment, primitive fitting and procedural stamps.

**Analysis and fabrication:** wall thickness, overhang, stability, deviation,
mass properties, clearance, support forests, orientation search, 2D bed packing
and layer slicing.

**Studio:** object browser, tool panels, sculpt/select brushes, analysis heat
maps, incremental undo, world/local transform and pivot handles, snapping and
numeric entry, material/texture editing, explicit import units, project recovery,
native file dialogs, and touch orbit/pinch gestures. A wgpu renderer uses Vulkan,
Direct3D 12 or Metal with a visible CPU fallback and explicit CPU option.
Geometry and rendering run in workers; cancellation terminates active CPU work.
Linux, Windows and macOS have build, integration and installer CI jobs.

**Scan to print:** inspect selectable defects, preview fragment removal and bounded
denoising, repair individual holes, bridge boundaries, trim cavities correctly,
and reduce/remesh with sampled physical deviation limits. Apply retains a protected
original; Show original, Cancel, Undo and saved edit history make changes reviewable.
Printer settings drive bed bounds, wall/overhang findings and packing. Export JSON
preflight reports or whole-mesh cleanup recipes; `mmx cleanup` and `mmx batch` reuse
the same operations. See [the Studio walkthrough](apps/mmx_studio/README.md#scan-to-print)
and [recipe contracts and limits](docs/CLI.md#scan-to-print-workflow).

## Build and test

Start with the [quick start](QUICKSTART.md) to install the tools. CI uses Flutter
3.47.9 and its bundled Dart SDK. Desktop builds also require Rust 1.99.1,
Python 3.11+, and the native tools for your OS.

From the repository root:

```sh
python3 start.py          # Build and run Studio; Windows: py -3 start.py
python3 start.py --debug  # Development with hot reload

# Optimized CLI + Studio; run each desktop build on its native OS
make build               # Or: python3 tool/build.py
make linux               # Explicit Linux target
make package             # Portable review archive and provenance

# Full verification (kernel + Studio)
make test                # Or: ./tool/verify.sh
```

For individual packages, run each block from the repository root:

```sh
cd packages/mmx_core
dart pub get
dart analyze
dart test
```

```sh
cd apps/mmx_studio
flutter pub get
flutter analyze
flutter test
```

Tests use vendored fixtures; no Meshmixer installation is needed.
Verification includes kernel properties, parser fidelity, worker cancellation,
desktop interactions and project recovery. Commands and coverage gates are in
[`docs/TESTING.md`](docs/TESTING.md).

## CLI

```sh
cd packages/mmx_core
dart run bin/mmx.dart info model.obj
dart run bin/mmx.dart reduce model.obj out.stl --percent 0.3
dart run bin/mmx.dart remesh model.obj out.stl --edge 1.2 --iters 4
dart run bin/mmx.dart solid model.obj solid.stl --mode accurate --res 160
dart run bin/mmx.dart hollow model.obj shell.stl --thickness 2 --holes 4
dart run bin/mmx.dart supports model.obj supports.stl --angle 45
dart run bin/mmx.dart analyze model.obj
dart run bin/mmx.dart measure model.obj
dart run bin/mmx.dart convert model.obj scene.mix
dart run bin/mmx.dart render model.obj view.png --width 1200 --height 800

# AOT build
dart compile exe bin/mmx.dart -o mmx
```

## Desktop app

```sh
python3 start.py              # Windows: py -3 start.py
python3 start.py --build-only  # Build a release bundle without launching
```

See the [quick start](QUICKSTART.md) for platform setup, output paths, and manual commands.

Use the Project menu to open/save `.mmx` projects, transform the selected object,
and apply booleans. Native dialogs import/export mesh files; project saves preserve
the whole scene. Recovery autosaves are offered on restart.

The app starts with an empty project and offers **Import mesh** and **Open project**.
Use **Project → New project** or **Ctrl+N** (**Command+N** on macOS) to start fresh.
Unsaved projects offer **Save**, **Discard**, and **Cancel**; a failed or canceled
save keeps the current project open. New projects reset undo history and project
metadata, and safely clear this session's old recovery after pending writes.
Repository sample models are test fixtures and are excluded from release bundles.

## Performance

The AOT benchmark records workload hashes, host/toolchain identity, latency
samples and process peak memory. Compare runs on the same quiet machine with
identical inputs; see [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md). Kernel
benchmarks do not measure interactive frame latency.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) and [`SUPPORT.md`](SUPPORT.md).
Security issues follow [`SECURITY.md`](SECURITY.md). The project uses a clean-room rule: no Autodesk
source code is copied; the binary, its RTTI/strings and public API headers are
the evidence.

## License and attribution

The mmx source code is licensed under the **Apache License 2.0**. See
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The sample geometry (`bunnyr.obj`, `dog.obj`, `elephant.obj`, `gremlin.obj`,
`plane.obj`, `sphere.obj`) comes from the Meshmixer installer and remains
Copyright Autodesk, Inc. It is included as repository test fixtures and excluded
from binary releases. The public API headers under `docs/reference/` are reproduced from
Autodesk's `meshmixer/mm-api` repository for reference.

Meshmixer is a trademark of Autodesk, Inc. mmx is an independent project and is
not affiliated with or endorsed by Autodesk.

## Acknowledgments

The geometry approach follows published work by Botsch, Kobbelt, Sorkine and
Schmidt, and the open-source lineage around Meshmixer (geometry3Sharp,
Cotangent2 and libgeometry). Those projects informed the algorithms; mmx does
not link against them.
