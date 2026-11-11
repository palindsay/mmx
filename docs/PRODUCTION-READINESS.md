# Production readiness

Target: reliable Linux, Windows and macOS core mesh workflows and CLI.
**Status: release candidate, pending commercial acceptance. The scan-to-print
implementation addresses the reproduced correctness/workflow defects below.
Passing local tests and producing optimized binaries does not establish measured
print quality, sustained performance on customer hardware, or signed distribution.**
The [feature completion record](FEATURE-COMPLETION.md) records the previous
delivery scope, not commercial acceptance. This document supersedes the historical
finish/remediation plans; full Meshmixer parity remains a separate target.

## New Project workflow

**[observed]** Studio starts empty. Project → New project and Ctrl+N (Command+N
on macOS) start a fresh untitled document. The empty workspace offers Import mesh
and Open project. A clean project needs no confirmation. An unsaved project offers
Save, Discard and Cancel, with Save focused by default; Escape cancels. A canceled
or failed save preserves the current project. New Project clears objects, selection,
history, camera position, source attachments and the saved path; it preserves tool
parameter values and rendering preferences. Undo does not cross the document boundary.

The transition joins pending recovery writes before deleting only this session's
old recovery. Cleanup failure or a newer document revision aborts replacement.
Concurrent New/Open requests are serialized and active geometry/gesture operations
block replacement. New Project does not delete existing saved project files.
This follows the confirmation and keyboard-access principles in
[Microsoft's command guidance](https://learn.microsoft.com/en-us/windows/apps/design/basics/commanding-basics).

## Correctness review and implemented corrections

The November 10 review reproduced defects against
`e87edf6e79f3debf01b8c5cc9d58ba117f14443d`, despite its passing 214 kernel tests,
87 Studio tests, the 22-case analytical corpus, five Rust tests and six strict GPU
tests. Its [three-platform CI](https://github.com/palindsay/mmx/actions/runs/42754854409)
also passed. These are historical baseline results, not evidence for the new code.

The following corrections are **[observed in this implementation]** and have
dedicated regression tests:

| Original failure | Current behavior and evidence |
|---|---|
| Nonadjacent self-intersections were never inspected. | BVH overlap candidates, scale-normalized triangle SAT including coplanar axes, distinct self-intersection findings; crossing/coplanar/multiple-scale tests. Reporting exhaustion fails explicitly. Floating-point predicates are not an exact arithmetic proof. |
| Three faces sharing an edge remained non-manifold; valid mesh colors/groups disappeared. | Per-vertex incident-fan splitting across non-two-face edges preserves positions, face order, RGB, groups, UVs and material assignments. Introduced boundaries remain visible for subsequent repair. |
| Nested plane caps silently closed intentional cavities. | Even/odd planar regions, visibility bridges and ear clipping preserve nested cavities and islands. Tests check volume, watertightness, manifoldness and rays through the cavity, including multiple holes and oblique cuts. Ambiguous/touching contours fail. |
| Selection Reduce/Remesh also edited unselected objects. | Extract and edit the selected patch, pin its boundary, verify the boundary contract and stitch it back without moving/remeshing unselected faces. |
| Hollow's physical thickness depended on object scale. | Ordinary and verified Make Solid/Hollow bake world geometry and reset the object transform. Baked/unbaked 40 mm cube results are identical in the regression. |
| Packing crossed bed borders and violated spacing. | Reserve actual footprints plus spacing inside both borders, validate placed bounds and report unplaced objects. All packing quality modes have clearance regressions. |
| Continuous camera input starved displayed frames. | Separate scene invalidation from camera requests; publish completed current-scene frames while coalescing pending cameras. A persistent isolate and retained GPU buffers/textures avoid repeated scene transfer/upload. A 1 ms input regression checks publication before input stops. |
| Thin-wall heatmaps were reversed; upward faces could be classified as overhangs. | Thin measurements map toward warning colors, missing hits are unknown gray, and overhang checks use downward-facing normals. |
| Fitted box winding was inward; equal-sized boundary bridging could produce a pinched non-manifold seam. | Outward primitive winding and a diagonal-based, direction-aware bridge walk. Invalid bridges fail; mesh-level Booleans report their existing grid fallback when stitching is unsupported. |

See [scan regressions](../packages/mmx_core/test/scan_production_test.dart),
[scan acceptance](../packages/mmx_core/test/scan_acceptance_test.dart),
[workflow tests](../packages/mmx_core/test/scan_workflow_test.dart),
[Studio workflow](../apps/mmx_studio/test/scan_workflow_test.dart), and
[continuous rendering](../apps/mmx_studio/test/scene_render_worker_test.dart).

Selection smoothing, discard and cross-section reports now run in cancellable
workers. The object browser offers rename, delete, visibility, isolate/show-all and
reference-target controls, with undo and protected-original deletion safeguards.
UV/material topology changes still reject unsupported correspondence explicitly.

## Delivered scan workflow

- Selectable inspection findings cover boundary loops, non-manifold connectivity,
  intersections, duplicates, degenerates, winding, fragments, bounds and sampled
  manufacturing checks. Unknown wall/drainage assumptions remain visible.
- Fragment removal protects selected components and the largest component.
  Denoising pins boundaries/creases/unselected vertices, bounds displacement in
  millimeters and rejects flipped faces. Reduce/remesh use sampled physical error
  budgets; they do not claim certified global distance bounds.
- Hole-by-hole flat/smoothed patches and bridges preview before Apply. New patch
  groups identify inferred geometry; smoothed patches do not promise reconstruction
  of missing real-world detail. Arbitrary numeric plane trims preserve cavities.
- Apply retains a hidden, protected original; Show original toggles comparison at
  the same camera. Cancel leaves the document unchanged. Undo/redo, save/reopen,
  geometry hashes and per-step history preserve reviewability.
- FDM/resin settings drive bed dimensions, borders, minimum-wall and overhang
  assumptions. Packing uses the profile, and cross sections report open contours.
  The viewport bed uses the same configured rectangular dimensions and origin.
- Versioned recipes, preflight report export and CLI scan/cleanup/batch share the
  kernel. Whole-mesh recipe export verifies hash continuity; localized or
  interrupted histories cannot silently replay as whole-mesh operations. Batch
  isolates failures and refuses overwrites. Reports include input/output hashes.
- Project schema 3 stores originals, history and printer profiles; schema 1/2 remain
  readable. Changed Studio documents pass a conservative admission budget before
  commit; exact save serialization additionally validates the archive. Binary
  payload budget is 240 MiB, metadata estimate 8 MiB, encoded/decoded texture budget
  192 MiB, maximum 1024 objects/sources and 4096 archive entries. A protected copy
  consumes additional capacity; oversized edits roll back with a visible error.
- Root Makefile targets and `tool/build.py` build optimized Dart AOT and Flutter/
  Rust release binaries, stage complete bundles and optionally package unsigned
  archives/installers with provenance. The native CI matrix uses the same helper.

Detailed controls, operation contracts, recipe parameters and known limits are in
[the scan-to-print guide](CLI.md#scan-to-print-workflow). The included
[example recipe](scan/cleanup.recipe.json) preserves openings; review physical
thresholds for each scan instead of treating it as a universal repair preset.

## Commercial acceptance work

The initial commercial scope should be repair and print preparation of meshes
exported by scanners: STL, OBJ, mesh PLY and supported 3MF. Direct scanner capture
and raw point-cloud reconstruction should be separate milestones. **[inferred]**
This concentrates work on customer outcomes that the current mesh kernel can
support while avoiding device SDK integration before basic repair is dependable.

| Workstream | Remaining deliverable | Release acceptance |
|---|---|---|
| Geometry contracts | Extend independent adversarial coverage for booleans, general nested-shell classification and textured topology edits; validate the documented scan operation contracts on real scans. | All P0 reproducers pass; no silent scope changes, false repair success or unsupported attribute loss. |
| Complete editing | Human workflow/accessibility acceptance of the delivered scene controls, previews, reports and comparison; improve automatic base-plane fitting and defect navigation from operator feedback. | Operators complete import, cleanup, repair, print preparation, save/reopen and export without workaround files or hidden state. |
| Data durability | Native failure/upgrade/soak acceptance for schema 3 and the declared project budgets; design a chunked format if larger jobs must be supported. | Every accepted supported scene remains saveable/recoverable within declared limits; old projects remain readable across supported upgrades. |
| Capacity | Measure retained rendering, history capture and spatial rebuild costs on designated hosts; add indexed/chunked GPU uploads and out-of-core geometry for larger scans. | Fixed-host latency, memory and cancellation budgets for representative 100k, 1M and stretch 5M-face models. Current GPU expansion caps near 1.33M triangles before other overhead. |
| Validation | Legally usable real scans, adversarial topology, transform/selection invariants, independent fidelity references and long-running parser mutation/fuzz campaigns. | Retained input hashes, settings, expected results, resource bounds and failures for each supported platform; coverage alone is not sufficient. |
| Print outcome | Slicer round trips and measured prints spanning organic and mechanical scans, small features, cavities and intentional openings. | Compare dimensions and retained details against the chosen printer/process tolerance; surface assumptions and unresolved regions. |
| Distribution | Signed/notarized installers, clean-account install/upgrade/remove, accessibility and display scaling checks on exact shipped bytes. | All external gates below pass for the final source and artifact hashes. |
| Maintenance | Supported OS/hardware policy, release cadence, actionable local diagnostics, opt-in crash reporting, dependency/license inventories including Rust, regression triage and rollback. | Named maintenance ownership and a tested support/reproduction path; users' scans are not uploaded implicitly. |

Proposed performance targets must be approved against designated hardware before
becoming release claims: continuous navigation at a p95 frame interval of 33 ms
or less on the 1M-face reference scene, input feedback within 100 ms, cancellation
settled within 500 ms, and a two-hour edit/undo/save soak within a declared memory
budget. These are **targets**, not existing measurements. Unsupported workloads
need a clear preflight result, not an unexplained transition to unusable speed.

## Features that improve scanned meshes for printing

The objective is to remove scan artifacts while preserving measured shape and
intentional detail. A watertight result can still have the wrong dimensions,
closed sockets, overlapping internal surfaces, or invented anatomy. Preserve an
immutable original and show a preview and deviation measurement for every repair.

| Order | Feature | User benefit and acceptance criterion |
|---|---|---|
| 1 | Scan inspection and repair report | Locate holes, intersections, inverted regions, duplicate faces, tiny shells and inconsistent units. Clicking a finding selects its region. Show repaired, unresolved and untested states separately. |
| 1 | Floating-fragment and background cleanup | Preview connected-component filtering, brush/lasso removal and scan-table/base segmentation. Preserve user-marked small parts; thresholds use physical size and relative area rather than blindly retaining only the largest component. |
| 1 | Detail-preserving denoising and spike removal | Add local feature-aware smoothing with protected creases/regions and a displacement budget in millimeters. Test noise reduction together with dimensional drift and retention of thin edges, facial features and embossed details. |
| 1 | Guided hole and crack repair | Offer per-hole flat, curvature-continuing and bridged patches with preview. Let users protect intentional openings. Mark reconstructed patches as inferred and retain their edit history. |
| 1 | Deviation-limited reduction and remeshing | Expose physical error and edge-length controls, preserve protected features and material seams, and compare to the original. Distinguish sampled maximum/RMS/percentile measurements from certified global bounds. |
| 1 | Trim, orient and create a printable base | Interactive arbitrary cut planes, nested-contour caps, plane fitting, a flat base/pedestal, and configurable bed placement. Check orientation, bounds and volume after each step. |
| 2 | Local wall strengthening | Locate thin regions, preview inward/outward/local thickening and preserve fit-critical surfaces. Report the supported thickness metric and unknown regions; current enclosed-shell directional clearance is not a general printability certificate. |
| 2 | Shell and cavity cleanup | Classify nested shells, remove unintended internal surfaces, repair winding and create a bounded-error solid. Preserve intended cavities and channels rather than indiscriminately filling all space. |
| 2 | Resin hollowing and drain planning | Place/edit drain and vent holes, inspect cross sections, identify enclosed cavities and validate connectivity. Do not infer complete drainage from watertightness or hole count alone. |
| 2 | Scan-aware print preflight | Printer/process profiles combine dimensions, supported minimum features, wall checks, orientation, bed bounds and slicer export. Emit actionable findings and an explicit unsupported/unknown state. |
| 2 | Repeatable cleanup recipes | Save ordered operations, parameters and input/output hashes; preview per-model effects; batch via the CLI with failures isolated and originals preserved. |
| 3 | Multiple-scan alignment and fusion | Add manual landmarks, overlap-aware robust registration and residual maps before fusion. Reject poor alignment and preserve source scans. Current rigid ICP alone is not a complete multi-scan workflow. |
| 3 | Raw point-cloud workflow | Add an explicit point-cloud data type/import path, outlier filtering, normal estimation/orientation, reconstruction and density/support visualization. Validate PLY/XYZ/PCD first; larger exchange formats and device SDKs require separate scope. |

For point clouds, published statistical and radius-based filters remove points
based on neighborhood distance or density; aggressive settings can discard useful
samples. Use preview and reversible masks, as illustrated in
[Open3D's outlier-removal reference](https://www.open3d.org/docs/release/tutorial/geometry/pointcloud_outlier_removal.html).
Poisson reconstruction may add surfaces in sparsely sampled or unobserved areas;
input-support density helps expose these regions. Normal orientation is also a
prerequisite for the documented reconstruction workflow. These are algorithm
references, not a decision to add an Open3D dependency. See
[Open3D surface reconstruction](https://www.open3d.org/docs/release/tutorial/geometry/surface_reconstruction.html).

**[inferred]** The strongest differentiator is an explainable, reversible path
from scan to printable mesh, with protected detail and physical error budgets.
Automatic or AI-assisted completion must identify inferred geometry; it cannot
establish the true shape of an unscanned region. Validate value using time to a
usable export, repair success without manual rescue, preserved dimensions,
retained fine detail and repeatable print results. **[unknown]** User demand,
scanner-specific performance and superiority to Meshmixer need real operators and
independent comparisons; current tests do not establish them.

Delivery order: validate the implemented scan workflow on real scans and prints;
meet capacity/quality gates and complete signed release acceptance; then add the
remaining capabilities below based on validated demand. Order-1 building blocks
are now implemented, but automatic segmentation, curvature reconstruction, fitted
bases and certified deviation bounds remain extensions, not delivered guarantees. Mobile, advanced
PBR, generic strength simulation and a new G-code slicer are not first-release
requirements for this scope.

## Implemented plan

### Desktop interaction and persistence

- Geometry workers are owned isolates: cancel terminates synchronous CPU work,
  stale results cannot replace a newer document, and failed edits restore scene,
  camera, project path and original-source metadata. Status reports operation
  phases rather than an invented completion percentage.
- Rendering coalesces requests; spatial data caches key on document/object/mesh
  and transform state. World/local translation and rotation, per-axis/uniform
  scale, snapping, numeric entry and pivot editing commit one undo entry. Sculpt drags group stamps into one entry
  and cancel rolls back the whole stroke.
- Native `.mmx` projects preserve objects, IDs, transforms, colors/groups, pivots,
  visibility, targets, camera, selection and original imported `.mix` bytes.
  Save/Save As is separate from mesh export. Writes flush a temporary sibling
  before replacement; failed reads keep the current scene.
- Native dialogs, dirty prompts, unit selection, Ctrl/Command shortcuts and
  recovery autosaves are implemented. Recovery waits for pending writes before
  cleanup and preserves unreadable recovery data instead of overwriting it.
  Per-session files and exclusive leases prevent other app instances from
  overwriting, recovering or deleting a live session's autosave. Legacy recovery
  files remain recoverable; closing a lease preserves its unsaved data.
- Open/save/import remain locked through final previews. Completion listeners
  cannot have newer edits marked clean; invalid incoming cameras/previews roll
  back the prior scene. A preview failure after a successful disk save leaves
  that save successful and releases the operation lock.
- Framing an empty Boolean result preserves the prior camera, so valid empty
  results remain saveable and reloadable.
- Chosen existing Save As/export destinations require Replace confirmation;
  cancellation preserves the original bytes. Toolbar/tool actions and adjustable
  controls expose names through native accessibility APIs.
- Empty startup avoids adding unwanted geometry to imported scans. Release
  packaging rejects accidental Autodesk fixture assets in the app bundle.

### File and kernel correctness

- OBJ/OFF/PLY use bounded concave triangulation. PLY decodes ASCII and either
  binary byte order by property schema, including reordered fields, lists,
  colors/groups and unknown elements. STL validates grammar and binary sizes.
- ZIP bounds expanded content to 256 MiB and 4096 entries, checks CRC/size/method
  consistency and rejects unsafe names. 3MF resolves relationships, units,
  transforms, repeated instances and component graphs; unsupported material or
  extension semantics fail explicitly. `.mix` rewrite consumes records in order
  and fails rather than silently replacing metadata with a minimal mesh.
- Plane clipping preserves winding and attributes; reflected transforms reverse
  faces; invalid transforms fail atomically. Welding avoids packed-key
  collisions. Remesh/reduce and other edits preserve/interpolate supported
  colors/groups where correspondence exists.
- QEM heap entries are versioned and compare valid endpoint/midpoint choices;
  remeshing validates orientation. Surface-net lattice degeneracies and tiny-scale
  ray tolerances are corrected. Exact empty/disjoint booleans stay exact;
  invalid precise outputs take an explicitly reported grid fallback.
- Voxel allocations and generated pattern/subdivision/remesh output are bounded
  before allocation. CLI arguments reject nonfinite/unknown/invalid values, use
  exit 2 for usage errors, and write outputs atomically.

### Validation and release tooling

- Seeded geometry acceptance and an analytical corpus check topology, winding,
  components and explicit volume tolerances. An external-reference manifest
  harness compares independently acquired outputs without inventing oracle data.
  Reports retain consumed fixture/manifest hashes and operation settings.
- Critical IO coverage has a >80% per-module gate. Desktop tests exercise
  cancellation, manipulation, recovery, metadata rollback and shortcuts; native
  integration covers Unicode import/edit/undo/save/reopen/export workflows.
- CI pins Flutter 3.47.9 and targets Ubuntu 24.04 x64, Windows Server 2022 x64 and
  macOS 15 arm64. It builds CLIs/apps, runs native integration, creates unsigned
  native installers and checks installation/removal on disposable runners.
- Portable archives normalize metadata; artifacts include checksums, source and
  content provenance, dependency inventories and license texts. Signing scripts,
  manual acceptance and rollback steps are in [RELEASE.md](RELEASE.md).
  Source/binary build receipts reject stale packaging inputs. Signing paths
  verify their results before exposing final packages and hashes; real publisher
  signatures still require the external identities below.
- The AOT benchmark identifies exact inputs, host and toolchain, records raw
  latency samples and isolated-process peak RSS, and rejects incompatible
  baselines. See [PERFORMANCE.md](PERFORMANCE.md) for measured results and limits.

## Validation record

Current local validation passes 247 kernel tests, 111 Studio tests, four native
Linux workflows, seven strict GPU tests, five Rust tests, 22 analytical cases and
all 24 required coverage gates. Commands and detailed counts are in
[TESTING.md](TESTING.md). New
regressions cover the failures above, schema migration/protected provenance,
preview cancellation, native retained rendering and batch CLI behavior. This
checkout's Linux results do not substitute for a fresh Windows/macOS CI run of
these exact changes or native manual/physical-print acceptance.

The preceding PR #5 optional-feature local run passed 214 kernel and 87 Studio tests
with clean analyzers and formatting; its separate strict native renderer suite passed
six tests. That implementation added material/texture round trips, immutable
history, advanced manipulators, native depth/texture checks, parser mutations and
continuous wall verification. Independent reviews cover data persistence,
transaction rollback, growth bounds and reconstruction topology. Both new wall
modules reached 100% line coverage; all 19 then-required coverage modules passed. The native
matrix builds and tests Vulkan, Direct3D 12 and Metal, records actual adapter
capability, and packages unsigned installers. Use the exact commit and artifact
checksums in [PR #5](https://github.com/palindsay/mmx/pull/5) for that baseline's evidence.
[Native profile measurements](performance/NATIVE-RENDERER.md) retain raw samples
and software-adapter status; they do not establish release-host performance budgets.

### Historical core checkpoint

The merged core checkpoint passed with 169 kernel tests, 57 Studio tests, both analyzers
clean and no formatting changes. Native Linux integration passes. The 22-case
analytical corpus and fixed-host performance comparison pass. The optional
native [profile UI probe](performance/UI-RESPONSIVENESS.md) verifies progress and
cancellation on a 100k-face scene, while retaining observed frame stalls and
memory limits. A fresh Linux CLI and release build pass startup smoke testing;
critical coverage passes at 96.4–100% per required module. Packaging regression
tests and license collection pass.

The prior 0.2.0 candidate additionally passed 14 [native Linux acceptance checks](release/LINUX-ACCEPTANCE.md)
using actual GTK dialogs, AT-SPI actions, overwrite hash checks, permission
failures and forced termination/recovery. The release/evidence tooling has 21
regression tests; the local run passes with the PowerShell test skipped for the
native platform job. The [performance workflow](https://github.com/palindsay/mmx/actions/workflows/performance.yml)
collects AOT and native profile observations on all three platforms; these are
not approved budgets on designated release machines.

The three-platform build/integration/install/remove results for that checkpoint
are attached to [PR #4 checks](https://github.com/palindsay/mmx/pull/4/checks).
These results do not certify subsequent optional-feature changes.
See [TESTING.md](TESTING.md) for reproduction. CI integration injects paths;
the separate Linux acceptance run exercises real dialogs but does not establish
human accessibility acceptance or clean-account behavior on the other systems.
The [acceptance record](release/ACCEPTANCE.md) tracks the remaining external inputs.

## Release acceptance criteria

| Gate | Required evidence | Dependency |
|---|---|---|
| Automated OS matrix | Successful build, integration and install/remove jobs for the reviewed commit, linked above | GitHub-hosted native runners |
| Signing | Verified Windows signature and macOS signed/notarized/stapled installer | Publisher identities, signing host and credentials |
| Native manual acceptance | Clean-account dialogs, permissions, overwrite/exit prompts, forced-exit recovery, keyboard/accessibility and units | Human operator on each supported OS |
| Reference fidelity | Real Meshmixer outputs, recorded settings/provenance and passing agreed tolerances | Licensed usable installation and independently acquired corpus |
| Sustained performance | Repeat the measured fixed-host baseline and native profile probe; accept interactive frame/memory budgets on each supported platform | Designated release hosts and interactive workloads |

Do not label unsigned review artifacts production-ready or claim oracle fidelity
from analytical tests. No release is published by this work.

## Documented limits and future improvements

- Incremental undo shares immutable geometry blocks and counts unique payloads;
  transient checkpoints, live restoration buffers and VM overhead are separate.
  [Local measurements](performance/INCREMENTAL-UNDO.md) document the limits.
- Manipulators support local/world axes, per-axis scale, snapping and numeric
  entry. Arbitrary face deformation remains separate from object manipulation.
- Optional [minimum-wall verification](WALL-THICKNESS.md) checks continuous
  inward-normal opposing-surface clearance on the final mesh with bounded
  reconstruction attempts. It assumes embedded shells and is not a medial-axis,
  self-intersection or manufacturing certificate. Unverified SDF thickness still
  has voxel error; Fast mode and open-shell minimum requests fail explicitly.
- Grid reconstruction does not promise original material-region correspondence.
  Native source attachments preserve unknown `.mix` bytes without interpreting
  their semantics. [Materials](MATERIALS.md) support diffuse RGBA and PNG/JPEG
  textures with seam-safe UVs; unsupported 3MF layers/extensions fail explicitly.
- Parser mutation tests use deterministic bounded cases and metamorphic round
  trips. They are not exhaustive or a long-running fuzzing campaign.
- Native wgpu rendering supports Vulkan, Direct3D 12 and Metal with explicit CPU
  fallback. Alpha cutout is supported; sorted translucency, PBR and zero-copy
  Flutter textures remain outside the renderer contract.
- Full Meshmixer parity, mobile, advanced UV seam painting and image stamps
  remain separate work. See [TOOL-MATRIX.md](TOOL-MATRIX.md).

Signing hosts/identities and licensed reference outputs were explicitly deferred
by the user on 2026-11-09. Their deferral does not waive production release gates.
