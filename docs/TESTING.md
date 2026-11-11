# Testing and coverage

## Verification

Run `./tool/verify.sh` from the repository root. It resolves dependencies, checks
Dart formatting, runs both analyzers, then executes the kernel and Studio suites.
Tests use checked-in fixtures; no Meshmixer installation is required.

The scan-to-print candidate adds focused kernel, state/widget, CLI and native
workflow tests. Run `make test` (portable equivalent: `python3 tool/build.py --verify`)
for the normal verification path. New coverage gates require **more than 80%** for
`scan/workflow.dart`, `scan/recipe.dart`, `scan/provenance.dart`,
`tools/selection_edit.dart` and `geom/planar_region.dart`, in addition to existing
critical modules. Local Linux results are summarized below; exact Windows/macOS
acceptance still requires the native CI matrix for these changes.

### Local scan-to-print verification, 2026-11-10

- `./tool/verify.sh`: **247 kernel tests**, **111 Studio tests**, formatting and
  both analyzers pass. Five native capability tests are skipped in the ordinary
  Studio suite and run separately against the built library.
- `./tool/coverage.sh`: all **24** required per-module gates pass. New modules:
  scan workflow **89.4%**, recipe **97.7%**, provenance **100%**, selection editing
  **100%**, nested planar regions **94.6%**. Project persistence is **99.6%**.
- Strict native GPU suite: **7 passed**, including retained geometry, camera
  updates, resize, replacement, clipping, depth, textures and bed visibility.
- Rust release parser/allocation/mutation tests: **5 passed**; `cargo fmt --check`
  and `cargo clippy --locked --release --all-targets -- -D warnings` pass.
- Native Linux desktop, materials, manipulators and scan workflows: **4 passed**
  in separate Flutter invocations. The scan workflow also supplied a rendered UI
  inspection of original comparison and Apply/Cancel.
- Analytical geometry corpus: **22 cases passed**. Python build/packaging/evidence
  tooling: **28 tests**, with one Windows-only check skipped on Linux.

The malformed-CLI cases each have their own test deadline. The first macOS CI
run passed 242 kernel tests but timed out a single test containing five cold Dart
launches; splitting those invocations retains every assertion and the default
per-test timeout, increasing the suite from 243 to 247 tests.

These observations cover the local 0.3.0 candidate working tree. They do not
certify physical print outcomes, sustained large-scan performance, or the exact
Windows/macOS artifacts; see [production acceptance](PRODUCTION-READINESS.md).

Optional-feature checkpoint PR #5, observed on 2026-11-09: 214 kernel tests and
87 Studio tests pass; both analyzers and formatting checks are clean. The ordinary
Studio suite skips four native capability tests, which run explicitly against
the built library in the six-test renderer suite. The analytical corpus has
22 cases and runs on each native CI platform.

For focused work:

```sh
cd packages/mmx_core
dart test test/geometry_acceptance_test.dart test/io_fidelity_test.dart
dart run tool/validate_corpus.dart
cd ../../apps/mmx_studio
flutter test test/interaction_test.dart test/recovery_test.dart test/worker_runtime_test.dart
# A fresh Flutter process is required for each desktop integration file.
for test_file in integration_test/*_test.dart; do
  xvfb-run -a flutter test "$test_file" -d linux || exit 1
done
```

Use `-d windows` or `-d macos` on those hosts, without Xvfb, still launching a
separate `flutter test` process for each file.

Native property workflows open **Tool properties** when the window is narrower
than 900 logical pixels and dismiss the drawer before viewport gestures. Both
800×600 (the macOS default) and 1280×720 layouts have widget regressions and
passed native Linux checks; tests must not assume a permanently visible sidebar.

On native macOS, synthetic text-field Tab also needs Cocoa's
`TextInputClient.performSelectors` / `insertTab:` callback. Flutter 3.47.9 defers
that key to the IME, while the integration binding leaves `TestTextInput`
unregistered. The test helper supplies the missing platform message and asserts
that Apply really has focus before Enter; it does not focus or invoke the button
directly. A macOS-platform regression reproduces the raw-key failure. Human
keyboard/accessibility acceptance remains a separate release check.

**Observed SDK limitation (Flutter 3.47.9):** a multi-file desktop invocation such
as `flutter test integration_test -d linux` passes the first app, then fails to
launch subsequent apps with “The log reader stopped unexpectedly, or never
started.” The SDK's `flutter_tools/lib/src/desktop_device.dart` keeps one
`DesktopLogReader` per device; its final stream controller closes after the first
app exits and is reused by the next launch. This occurs before test assertions.
Use a fresh per-file Flutter process for all four native workflows.
Private D-Bus sessions do not fix this closed-stream problem and are not required
for these tests; use them separately when isolating native desktop automation.

The native workflows check empty startup and New Project, native plugin registration,
non-ASCII paths, import units, reduction, undo/redo, project save/reopen,
watertight STL export, scan preview/original preservation, printer-profile/history
round trips and report export, keyboard and pivot-aware manipulators, and material/texture
OBJ companion-file round trips. They inject file paths; real GTK dialog automation
has separate [Linux acceptance evidence](release/LINUX-ACCEPTANCE.md). Human and
clean-account acceptance remain separate release checks. See
[release procedures](RELEASE.md).

## Regression coverage

- Scan tests exercise multiscale/coplanar intersections, non-manifold fan splits,
  nested/multiple/oblique cap contours, protected selection boundaries/attributes,
  outward primitives, valid bridges, physical transform equivalence, measured
  deviation budgets, packing clearance and explicit unknown wall/drainage findings.
- Native/state scan workflows verify Cancel/Apply, protected originals, undo/redo,
  schema 1/2 migration to schema 3, saved printer settings, hashes/replay continuity,
  error rollback and narrow-window controls. CLI tests exercise unit conversion,
  recipes, overwrite refusal and isolated batch failure.
- Persistent renderer tests cover camera updates before input stops, scene epoch
  replacement, worker restart/disposal, native cached geometry, resize and textures.
- New Project tests cover empty startup, Ctrl/Command+N, Save/Discard/Cancel,
  Escape and safe default focus, real project persistence, canceled/failed saves,
  history/source/selection reset, preview failure, interaction locks and newer
  edits from completion listeners. Recovery tests delay an old autosave and
  verify that New Project waits, preserves other recovery files, and aborts if
  a newer edit arrives before cleanup completes.
- Geometry tests assert closed/manifold/oriented topology and analytical volume,
  exercise extreme scales, overlapping/disjoint/empty booleans, repeated edits,
  attribute interpolation, and allocation limits. Randomized cases use fixed seeds.
- Parser tests cover binary byte orders, reordered PLY properties, concave faces,
  malformed indices, archive checksums/limits, 3MF instances/units, project metadata
  and byte-preserved imported `.mix` source attachments.
- Studio tests cover transform/pivot gestures, single-entry sculpt undo, spatial
  cache invalidation, stale results, failed/canceled import rollback, recovery
  write ordering, unreadable recovery preservation and keyboard save shortcuts.
- Completion tests keep open/save/import locked through rendering, preserve new
  edits from completion listeners, and roll back failed incoming previews.
  Recovery leases isolate simultaneous sessions; a real child-process crash
  test verifies exclusive ownership and subsequent recovery.
- Worker tests terminate an active synchronous CPU loop, cancel during spawn,
  propagate errors, and verify unexpected worker exit completes promptly.
- Python packaging tests verify repeated archives are byte-identical and file
  manifests/checksums reflect their contents.
- Build-helper tests pair the simulated OS with its architecture, including ARM
  and Intel macOS, so host rejection, dry-run safety and compiler failures are
  exercised independently of the machine running the tests.

## Coverage gate

```sh
./tool/coverage.sh
python3 -B -m unittest discover -s tool -p 'test_*.py'
```

The collector uses a fresh temporary directory for raw coverage on every run;
merging stale records after source changes can produce incorrect line counts.
Coverage runs suites serially: a parallel VM collection stalled after test
execution during earlier local validation. The current serial result and module
counts are recorded above. Ordinary correctness tests remain concurrent.
The current report is `packages/mmx_core/coverage/lcov.info`.

CI requires more than 80% line coverage separately for native project IO,
atomic writes, ZIP, 3MF, polygon triangulation, OBJ, PLY, STL, mesh attribute
transfer and generated-mesh allocation guards. Missing records
fail the gate. This is a targeted line-coverage requirement; it does not establish
exhaustive parser fuzzing, branch coverage or whole-project coverage.

The optional-feature gate also covers mesh file dispatch, companion paths, MTL,
image decoding, 3MF materials, immutable material data, incremental history and
continuous directional wall-clearance verification.
Run `test/material_fidelity_test.dart` and `test/incremental_history_test.dart`
for their focused regression suites. Mutation tests have fixed seeds and finite
case counts; they exercise actual parsers rather than a mock grammar.

Native renderer tests require the built library. See the
[renderer guide](../apps/mmx_studio/native_renderer/README.md) for the strict
`MMX_GPU_LIBRARY` command, Rust checks and adapter capability probe. Ordinary
Flutter unit tests explicitly skip unavailable native capability tests; CI runs
them after the platform build. Software adapters are labeled as such.

The historical PR #5 coverage run passed its 19 required modules at 92.6–100%.
Wall verification, its tetrahedral fallback, PLY, STL, 3MF, image decoding, companion paths, atomic writes,
3MF materials and allocation guards reach 100%; OBJ measures 94.9%, project IO
99.6%, ZIP 99.3%, triangulation 98.8% and attribute transfer 96.4%. These are
line-coverage observations, not exhaustive correctness claims.

## Geometry references and performance

The [analytical corpus](../packages/mmx_core/tool/corpus/README.md) reports explicit
volume tolerances and topology requirements. Its reference-manifest mode accepts
independently acquired Meshmixer output and records comparison failures. No such
external output has been supplied, so analytical success proves no parity claim.
Reports retain hashes of the manifest and every consumed fixture alongside
operation parameters, so replacing a reference file cannot silently reuse its
identity in evidence.

[Performance instructions](PERFORMANCE.md) describe host identity, exact input
hashes, AOT samples, peak RSS and regression budgets. Run measurements on an idle,
fixed host; never gate kernel latency using unrelated shared-runner baselines.

## Algorithm limits

Adaptive density is a heuristic. Precise boolean and adaptive-remesh fallbacks
are reported explicitly. Ordinary Hollow thickness is approximate within voxel
error. Optional bounded minimum-wall reconstruction verifies the final mesh's
[directional clearance](WALL-THICKNESS.md), under documented embedded-shell
assumptions; it is not a general manufacturing or self-intersection certificate.
Grid reconstruction has no material-region correspondence
guarantee; unsupported topology edits reject surface attributes. Planar unwrap
persists per-corner UVs, while diffuse materials/textures use an explicit supported
format subset. Imported unknown `.mix`
records are retained as source attachments; they are not interpreted as editable
scene objects. These limitations are tracked in [production readiness](PRODUCTION-READINESS.md).
