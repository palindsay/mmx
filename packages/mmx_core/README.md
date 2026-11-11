# mmx_core

Pure-Dart geometry kernel for the [mmx project](../../README.md): a clean-room
reimplementation of the useful geometry and fabrication workflows of Autodesk
Meshmixer 3.5.0.

Licensed under Apache-2.0. See the root [`LICENSE`](../../LICENSE),
[`NOTICE`](../../NOTICE) and [`docs/REVERSE-ENGINEERING.md`](../../docs/REVERSE-ENGINEERING.md).

## What is included

- Mesh import/export: OBJ, ASCII/binary PLY, STL, OFF, 3MF and native `.mix`
  (VFMesh 1.2/1.3, face groups, lossless rewrite of unknown records). `.mmx`
  projects use schema 3 for scene metadata, scan history, protected originals,
  printer settings and original `.mix` source attachments; schema 1/2 remain readable.
- Topology: CSR adjacency, edge incidence, boundary loops, components and
  manifold checks.
- Repair: weld, crack closing, hole filling, non-manifold splitting, inspector.
- Remeshing and decimation: isotropic, adaptive, group-aware, linear
  subdivision, QEM/uniform reduction and boundary-preserving regional edits.
- Solid: narrow-band SDF voxelization, surface-nets polygonization, Make Solid,
  offset, hollow, booleans with an explicit grid fallback.
- Analysis: thickness, overhang, stability, deviation, mass properties,
  clearance.
- Fabrication: support forest, orientation, 2D packing, slicing.
- Tools: plane cut, mirror, extrude, shell separation, normal flip, smoothing,
  stamps, primitives, alignment, face groups, selection sets, complex
  split/filter/join, tube, polygon, part, pivot and planar unwrap.
- Rendering: orbit camera, software z-buffer rasterizer, PNG encoder.
- Scan workflows: defect findings, fragment protection, bounded denoising,
  per-hole/bridge/trim repair, physical sampled deviation checks, versioned
  recipes, printer preflight reports and geometry/attribute provenance hashes.
- CLI in `bin/mmx.dart` covering the operators.

## Use

```yaml
dependencies:
  mmx_core:
    path: ../packages/mmx_core
```

```dart
import 'package:mmx_core/mmx_core.dart';

Future<void> main() async {
  // Coordinates must already be millimeters for scan operations.
  // readFile enforces import limits and resolves OBJ/MTL/texture companions.
  final mesh = MeshIO.readFile('model.obj');
  final result = ScanRecipe.apply(mesh, ScanStep('denoise', {
    'displacementMm': 0.1,
    'iterations': 5,
    'creaseDegrees': 45,
  }));
  // prepare/commit also handles companion files when exporting OBJ.
  final output = MeshIO.prepareExport('clean.obj', result.mesh);
  await MeshIO.commitExport('clean.obj', output);
}
```

Heavy operators run synchronously; use an owned isolate from a UI layer for
cancellation. Scan reduction/remeshing checks sampled bidirectional surface
distance after editing. The low-level QEM cost is a heuristic, not a physical
distance guarantee. Unsupported attribute/topology combinations fail explicitly.

The [CLI guide](../../docs/CLI.md#scan-to-print-workflow) documents `scan`,
`cleanup`, `batch`, recipe parameters, exit codes and report limitations. From
the repository root, `make cli` (or `python3 tool/build.py --component cli`)
builds and stages an optimized native executable under `bin/builds/`.

## Test

```sh
dart pub get
dart analyze
dart test
```

The test models are vendored under `test/fixtures/models`; no Meshmixer
installation is required. See [`docs/TESTING.md`](../../docs/TESTING.md) for
coverage gates and the analytical/reference corpus.

## Status

Pre-1.0. The remaining project work is tracked in
[`docs/PRODUCTION-READINESS.md`](../../docs/PRODUCTION-READINESS.md).
