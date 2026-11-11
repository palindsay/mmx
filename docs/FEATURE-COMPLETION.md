# Desktop feature completion

This is the **historical PR #5 checkpoint (2026-11-09)**. The 0.3.0 scan-to-print
candidate adds New Project, reversible cleanup, printer profiles, recipe/report
export, retained rendering and native build helpers. Its current behavior and
remaining acceptance gates are tracked in [production readiness](PRODUCTION-READINESS.md),
with validation in [testing](TESTING.md). The plan below records the earlier
delivery and must not be used as the current release acceptance record.

This extends the validated [PR #4](https://github.com/palindsay/mmx/pull/4)
hardening checkpoint. The user requested the optional backlog on 2026-11-09.
Windows/macOS signing hosts and licensed Meshmixer reference outputs are
explicitly deferred; they remain release acceptance requirements.

The implementation is delivered through [PR #5](https://github.com/palindsay/mmx/pull/5).
Its checks and artifacts identify the reviewed source, native adapter capability,
installer manifests and performance samples. The rows below define the delivered
behavior and its acceptance evidence; signing and human/reference acceptance
remain external release gates.

## Implementation and acceptance plan

| Workstream | Required behavior | Acceptance evidence |
|---|---|---|
| Incremental undo | Share immutable geometry across history; retain sparse edits without full scene copies; preserve mutable live meshes, rollback and budgets | Long transform sequences, sparse edits, exact attribute undo/redo, rollback and memory accounting tests; large-scene observations |
| Advanced manipulators | World/local axes, per-axis/uniform scale, translation/rotation/scale snapping, numeric input and pivot-safe gestures | One undo per gesture, pointer ownership, Escape cancellation, transformed-axis tests and native keyboard/drag/save workflow |
| Materials and textures | Seam-safe corner UVs, diffuse RGBA and PNG/JPEG textures, project persistence, supported OBJ/MTL and 3MF round trips, accessible editing | Texture/UV orientation, opacity, export/reimport, safe companion paths, allocation limits, and explicit rejection where an operation cannot preserve attributes |
| Parser mutation testing | Deterministic bounded mutations exercise actual importers and round-trip invariants | Reproducible seeds, malformed lengths/indices/archive metadata and resource-limit cases; no crashes or silent invalid meshes |
| Minimum wall behavior | Define the supported thickness metric; verify final output or fail explicitly; disclose voxel error and solver limits | Analytical thin regions, scale variation, bounded work, manifoldness, orientation and volume checks |
| Native renderer | Vulkan, Direct3D 12 and Metal through wgpu; retain an explicit CPU option and truthful fallback/adapter status | Depth/order/near-plane/resize and texture parity tests, native capability reports, three-platform build/package checks and license inventory |

## Integration sequence

1. Implement independent kernel, interaction and renderer changes with focused tests.
2. Wire worker cancellation, atomic exports, material editing and renderer status.
3. Review cross-feature behavior: material-aware undo, transformed UVs, recovery,
   unsupported operations, native loading and packaging.
4. Run format/analyzer/unit/coverage/corpus checks and native integration; collect
   performance observations and inspect rendered output.
5. Commit the coherent implementation, run all three native CI jobs, address
   failures, and review the final diff before merging.

## Scope boundaries

This work does not establish full Meshmixer equivalence. Unknown `.mix` semantics,
advanced PBR layers, UV seam painting, arbitrary surface deformation, mobile
deployment and image-based sculpt stamps are separate projects. Alpha cutout is
distinct from sorted translucent rendering. Analytical tests and hosted runners
do not replace independent references, human accessibility acceptance or signed
production distribution.
