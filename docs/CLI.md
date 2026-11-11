# CLI reference

The CLI is a thin wrapper over `mmx_core`; it is useful for batch processing,
regression tests and CI. Run it from `packages/mmx_core`:

```sh
dart run bin/mmx.dart --help
```

For a release build:

```sh
dart compile exe bin/mmx.dart -o mmx
```

## Commands

| Command | Purpose |
|---|---|
| `scan <file>` | Inspect a mesh against printer assumptions and write a JSON preflight report; see the scan workflow below. |
| `cleanup <in> <out> --recipe <json>` | Apply a versioned cleanup recipe, write the mesh and report, and refuse existing outputs. |
| `batch <in...> --recipe <json> --outdir <dir>` | Apply a recipe to each input with isolated failures and per-file reports. |
| `info <file>` | Print counts, bounds, area, volume, components, boundary loops, non-manifold edges and defects. |
| `repair <in> <out>` | Weld, close cracks, remove duplicate faces, split non-manifold surfaces and report remaining findings. Holes remain open unless `--fill-holes` is supplied. |
| `remesh <in> <out> --edge <len>` | Isotropic remesh; `--iters`, `--adaptive 0-1`, `--debug-topology`. |
| `reduce <in> <out>` | Decimate with `--percent`, `--faces`, `--uniform`; `--max-dev` rejects output exceeding sampled bidirectional surface deviation in input units. |
| `solid <in> <out>` | Make Solid with `--mode fast|accurate|blocky`, `--res`, `--offset`, `--smooth`. |
| `boolean <a> <b> <out> --op ...` | Union/intersection/difference; `--precise` uses the mesh-level path with grid fallback. |
| `hollow <in> <out>` | Hollow with `--thickness`, `--holes`, `--hole-radius`. |
| `offset <in> <out> --distance <d>` | Surface offset. |
| `supports <in> <out>` | Support forest; `--angle`, `--density`, `--bed`. |
| `pack <out> <in...>` | 2D bed packing; `--bed`, `--quality`. |
| `slice <in>` | Layer slicing; `--layer`. |
| `analyze <in>` | Thickness/overhang analysis; `--thickness`, `--overhang`. |
| `mirror <in> <out>` | Mirror; `--plane`, `--keep`, `--weld`. |
| `flip <in> <out>` | Flip normals. |
| `smooth <in> <out>` | Taubin smoothing; `--iters`. |
| `drop` / `center` | Place on the bed. |
| `duplicate <in> <out>` | Translate a copy. |
| `combine <out> <in...>` | Join meshes. |
| `pattern <in> <out>` | Grid array; `--nx`, `--nz`, `--gap`. |
| `primitive <in> <out>` | Fit box/cylinder/sphere; `--kind`. |
| `measure <in>` | Dimensions, area, volume, shells. |
| `clearance <a> <b>` | Minimum inter-object distance. |
| `convert <in> <out>` | Convert formats, including `.mix`. |
| `render <in> <out.png>` | Software render; `--width`, `--height`, `--yaw`, `--pitch`, `--wire`. |

## Examples

```sh
# Repair and decimate a scan
dart run bin/mmx.dart repair scan.obj clean.obj
dart run bin/mmx.dart reduce clean.obj low.stl --percent 0.25

# Prepare for printing
dart run bin/mmx.dart hollow clean.obj shell.stl --thickness 2 --holes 4
dart run bin/mmx.dart supports shell.stl supported.stl --angle 45
dart run bin/mmx.dart analyze supported.stl

# Convert a Meshmixer scene
dart run bin/mmx.dart convert scene.mix scene.obj
```

The CLI exits non-zero on a missing input file or an unsupported command.
Geometry operations are deterministic for the same input and parameters.

## Verified minimum wall clearance

`solid` and enclosed `hollow` accept `--min-thickness`, `--max-growth` and
`--attempts` (1–12, default 6). A positive minimum requests continuous inward-normal
opposing-surface clearance on the final output; failed verification leaves an
existing output untouched. Solid requires Accurate/Blocky, and Hollow requires
`--holes 0`. Successful commands emit a `wallClearance` JSON record with the actual
offset/shell thickness, numerical margin, attempt count and reconstruction method.
An explicit diagnostic reports a marching-tetrahedra fallback when surface-net
topology is ambiguous. See
[the metric, assumptions and examples](WALL-THICKNESS.md) before treating a
clearance result as a requirement for fabrication.

## Scan to print workflow

Studio's **Scan to print** panel uses the same kernel operations as these commands:

```sh
# Use the optimized CLI from bin/builds/<platform>-<architecture>/, or dart run bin/mmx.dart.
mmx scan model.obj --units mm --process fdm --width 220 --depth 220 --height 250 --report scan.json
mmx cleanup model.obj clean.stl --recipe docs/scan/cleanup.recipe.json --report clean.json
mmx batch first.obj second.ply --recipe docs/scan/cleanup.recipe.json --outdir cleaned
```

Paths are relative to the working directory. Run this example from the repository
root with the built `mmx` on PATH. Inputs and existing outputs are never overwritten
by `cleanup`/`batch`; each batch input gets its own `.stl.report.json`. A failed item
does not stop other items; the process exits 1 if any item fails. Invalid arguments
or recipe schemas exit 2. `scan` exits 0 when inspection completes; inspect its JSON
`status`/findings to decide whether geometry needs repair. Completion is distinct
from printability approval. Mesh and report files commit separately: a report-write
failure can leave a valid output mesh, and retries still refuse to overwrite it.

Input coordinates default to millimeters; unitless meshes accept `--units cm|m|inch`.
3MF already declares units and is imported in millimeters; leave `--units mm` for
3MF. Dimensions are X width, Y height, Z depth, with bed coordinates starting at
zero. Shared options include `--process fdm|resin`, `--width`, `--depth`, `--height`,
`--border`, `--wall`. Outputs use millimeters. Starting printer values are editable
assumptions, not material/printer certifications.

A recipe is versioned JSON with `version: 1`, `units: "mm"`, and 1–100 `steps`:

| Operation | Parameters (defaults) | Contract |
|---|---|---|
| `repair` | `weldMm: 0.001` | Weld connectivity, remove duplicate/degenerate faces and split non-manifold fans; preserve holes. A split may leave new boundaries requiring review. |
| `fragments` | `areaMm2: 1` | Remove small disconnected components; always retain the largest. Studio selections protect whole components. |
| `denoise` | `displacementMm: 0.1`, `iterations: 5`, `creaseDegrees: 45` | Two-pass smoothing, fixed boundaries/creases/unselected vertices, bounded original-relative vertex motion; reject face inversions. |
| `reduce` | `keepFraction: 0.5`, `deviationMm: 0.2` | QEM reduction with fixed boundaries, followed by bidirectional sampled deviation check. |
| `remesh` | `edgeMm: 1`, `deviationMm: 0.2` | Isotropic remesh with protected boundaries/sharp edges/groups and sampled deviation check. |
| `fillHole` | `loop: 0`, `smooth: 0` | Fill exactly one inspected loop. `smooth: 1` relaxes added patch vertices; it is not a curvature-continuation guarantee. |
| `bridgeHoles` | `first: 0`, `second: 1` | Bridge two distinct simple loops with consistent boundary winding. Reject invalid/degenerate construction. |
| `trim` | `x/y/z: 0`, `nx: 0`, `ny: 1`, `nz: 0`, `keepPositive: 1` | Arbitrary plane cut with planar caps, even/odd nested cavities and original off-plane openings preserved. |

Choose hole indices after inspection of the actual input; these steps are not
semantic hole matching across unrelated scans. Review every batch output. Inferred
hole/bridge patches get a separate face group in project geometry. STL does not
preserve these attributes; reports retain their provenance. Unsupported UV/material
topology changes fail explicitly; denoising and face extraction retain attributes.

Studio previews do not alter the document until **Apply scan edit**. **Show original**
toggles the retained reference at the same camera; **Cancel preview** leaves the
project unchanged. Applying stores an original reference, step parameters, geometry
hashes and measured deviation, then refreshes inspection. New `.mmx` files use schema
3 and persist protected originals, scan history and printer settings; readers still
accept schema 1/2. Older releases cannot read schema 3. New Project discards the
in-memory workspace only after the normal Save/Discard/Cancel flow.

**Export preflight report** includes the current inspection and stored history.
**Export cleanup recipe** requires an uninterrupted whole-mesh history starting at
the retained original. Regional edits and intervening unrecorded geometry/placement
changes reject recipe export; use the report instead. This prevents replaying a
regional edit across an entire mesh without its original selection.

Reports include consumed geometry/attribute SHA-256 hashes (including referenced
texture content), operation settings, face counts and sampled max/RMS/p95 distances.
CLI cleanup also records the exported main-file SHA-256. These are reproducibility
aids, not signatures. Deviation is sampled, not a certified Hausdorff bound. Ray wall
measurements leave missing hits unknown; resin drainage, supports, fit and actual
print outcomes require further review. Inspection fails explicitly when its
intersection reporting budget is exceeded rather than reporting the scan clean.
