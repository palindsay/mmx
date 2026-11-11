# Changelog

All notable changes to mmx are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
semantic versioning once it reaches 1.0.

## [Unreleased]

### Scan-to-print candidate (0.3.0)

- Start empty and create a New Project with Save/Discard/Cancel and recovery-safe replacement.
- Scan inspection with selectable findings, fragment protection, bounded denoising,
  guided hole/bridge previews, sampled deviation budgets, original comparison,
  protected references, printer profiles, reports and repeatable CLI recipes/batches.
- Object rename/delete/visibility/isolate/target controls and selection-limited Reduce/Remesh.
- `.mmx` schema 3 retains scan history and profiles; schema 1/2 remain readable.
  Older releases cannot open new schema 3 documents.
- Persistent renderer isolate and GPU scene resources; camera input no longer
  invalidates every completed frame. Printer bed graphics match configured bounds.
- Correct nonadjacent intersection inspection, attribute-preserving fan splits,
  cavity-aware caps, bridge topology, primitive winding, physical Hollow units,
  packing spacing/borders and wall/overhang analysis colors/directions.
- `mmx repair` preserves holes by default; `--fill-holes` explicitly fills them.
  `reduce --max-dev` measures sampled physical surface distance before writing.
- Root Makefile and portable Python helper build optimized native CLI/Studio
  bundles and unsigned packages. Commercial acceptance gates remain documented.

### Added

- Incremental geometry history, world/local manipulators, snapping and numeric transforms.
- Diffuse materials, PNG/JPEG textures, seam-safe UVs, supported OBJ/MTL and 3MF material round trips.
- Native Vulkan/Direct3D 12/Metal renderer with depth tests and explicit CPU fallback.
- Bounded deterministic parser mutation tests and native renderer capability checks.
- Continuous directional wall-clearance verification with bounded Solid/Hollow reconstruction and reported growth.
- Native `.mmx` projects, recovery saves, unsaved-change prompts and native file dialogs.
- Viewport manipulation, grouped sculpt undo, unit selection and cancelable workers.
- Desktop integration tests, parser/geometry regression suites and analytical corpus.
- Native installer jobs, deterministic portable archives, checksums and source provenance.
- Exact-input AOT performance comparisons with latency samples and peak memory.
- Native Linux acceptance automation and cross-platform AOT/profile evidence collection.
- Build receipts and verified signing orchestration for release artifacts.
- Tool matrix and finish plan for closing the reverse-engineering project.
- Studio actions for Extract, Make Part and Pivot.
- `BooleanResult` and `RemeshResult` fallback reporting.
- Property tests for remesh and collapse invariants.
- Vendored test models so the kernel suite runs without a Meshmixer install.
- Apache-2.0 licensing, contribution, security and community documentation.

### Changed

- Studio starts with an empty project; repository-only model assets are excluded from releases.
- Unsupported 3MF layers and unverified/unsupported minimum-wall requests fail explicitly.
- Extract in Studio now delegates to `ComplexTools.extract`.
- Pivot state is preserved by document undo/redo snapshots.
- CI runs on GitHub-hosted runners using the vendored fixtures.

### Fixed

- QEM candidate invalidation, remesh winding, surface-net lattice degeneracies and tiny-scale ray tolerances.
- Positive-offset voxel seed distances that could create a phantom grid-boundary shell.
- Material/UV export fidelity, encoded texture integrity, effective viewport sizing and native test launch isolation.
- Print-bed visibility and GPU reference outlines, preserving geometry below the bed.
- Concave import triangulation, PLY schemas/byte order, strict STL parsing and `.mix` metadata rewrites.
- Recovery write ordering, failed-import metadata rollback and keyboard shortcut focus.
- Per-session recovery ownership, operation completion races, invalid project cameras and macOS installer placement/provenance.
- Save As/export overwrite confirmation and native accessibility names for desktop controls.
- Stale build provenance, signing checksums, Windows uninstaller signing and macOS notarization failure handling.
- Plane Cut honours `keepPositive` on both sides and supports a negative-side
  slice group.
- Smooth hole filling relaxes only the filled patch.
- Hollow honors its requested SDF shell thickness; positive minimum-wall requests additionally verify final directional clearance.
- Make Polygon uses ear clipping for concave loops.
- Adaptive remesh fallback is explicit instead of silent.

## [0.1.0] - 2026-11-05

### Added

- Pure-Dart geometry kernel: topology, BVH, repair, remesh, decimation, SDF
  solidification, booleans with fallback, analysis, supports, packing, slicing.
- Native `.mix` reader/writer for VFMesh 1.2 and 1.3, including face groups and
  lossless rewrite of unknown records.
- Flutter Studio app with selection, sculpting, repair, remesh, reduce, solid,
  hollow, plane cut, mirror, extrude, supports, analysis and print workflows.
- CLI covering the kernel operators.
- Reverse-engineering report with observed/inferred/unknown evidence labels,
  RTTI and method-name recovery.
