# mmx

A clean-room, cross-platform mesh studio and geometry kernel built from a
reverse engineering study of **Autodesk Meshmixer 3.5.0**.

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.13%2B-blue)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.47%2B-02569B)](https://flutter.dev)
[![CI](https://github.com/plindsay/mmx/actions/workflows/ci.yml/badge.svg)](https://github.com/plindsay/mmx/actions/workflows/ci.yml)

> **Status: pre-1.0.** The core geometry workflows are usable and tested; the
> remaining work is tracked in [`docs/FINISH-PLAN.md`](docs/FINISH-PLAN.md).
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

- [Documentation index](docs/README.md)
- [Reverse-engineering report](docs/REVERSE-ENGINEERING.md)
- [Tool and action coverage](docs/TOOL-MATRIX.md)
- [CLI reference](docs/CLI.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Testing and coverage](docs/TESTING.md)
- [Finish plan](docs/FINISH-PLAN.md)
- [Remediation plan](docs/REMEDIATION-PLAN.md)

## Features

**Formats:** OBJ, PLY, STL (binary/ASCII), OFF, 3MF (OPC zip) and native
Meshmixer `.mix` scenes. The `.mix` reader supports VFMesh 1.2 and 1.3, face
groups and lossless rewrite of unknown records.

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
maps, undo/redo, import/export, narrow-window drawer layout and touch orbit/pinch
gestures. Linux is verified end to end; Windows and macOS targets are present.

## Build and test

Requirements: Flutter 3.47+ and Dart 3.13+. No Meshmixer installation is needed
for tests; the sample models are vendored under
`packages/mmx_core/test/fixtures/models`.

```sh
# Full verification (kernel + Studio)
./tool/verify.sh

# Release build (packages CLI and Studio archives into dist/)
./tool/build_release.sh

# Kernel only
cd packages/mmx_core
dart pub get
dart analyze
dart test

# Studio
cd apps/mmx_studio
flutter pub get
flutter analyze
flutter test
```

Current baseline: **106 kernel tests** and **11 Studio tests**, both analyzers
clean. Coverage and known gaps are in [`docs/TESTING.md`](docs/TESTING.md).

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
cd apps/mmx_studio
flutter pub get
flutter run -d linux        # or windows / macos
flutter build linux --release
```

The app bundles `bunnyr.obj`, `sphere.obj` and `dog.obj` as starter assets and
can also read a Meshmixer installer models directory.

## Performance

Measured on an 8-core x86-64 Linux host with AOT compilation against the
shipped `bunnyr.obj` (5,550 vertices / 10,996 faces):

| Operation | Time |
|---|---:|
| Import + topology + BVH | 38 ms |
| QEM decimate 50% | 108 ms |
| Isotropic remesh | 394 ms |
| Make Solid 128³ | 1.20 s |
| Hollow + escape holes | 1.62 s |
| Thickness scan | 56 ms |
| Support forest | 46 ms |
| Pack 6 objects | 1 ms |
| Slice 250 layers | 254 ms |
| Render 960×640 | 12 ms |

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
Copyright Autodesk, Inc. It is included as test fixtures and demonstration
assets. The public API headers under `docs/reference/` are reproduced from
Autodesk's `meshmixer/mm-api` repository for reference.

Meshmixer is a trademark of Autodesk, Inc. mmx is an independent project and is
not affiliated with or endorsed by Autodesk.

## Acknowledgments

The geometry approach follows published work by Botsch, Kobbelt, Sorkine and
Schmidt, and the open-source lineage around Meshmixer (geometry3Sharp,
Cotangent2 and libgeometry). Those projects informed the algorithms; mmx does
not link against them.
