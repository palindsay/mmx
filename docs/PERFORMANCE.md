# Performance validation

## Reproducible kernel measurements

Run from `packages/mmx_core` on an otherwise idle, dedicated machine:

```sh
dart pub get
dart compile exe tool/performance.dart -o /tmp/mmx-performance
/tmp/mmx-performance --host-id=workstation-a > /tmp/baseline.json
/tmp/mmx-performance --host-id=workstation-a \
  --baseline=/tmp/baseline.json > /tmp/candidate.json
```

Choose a stable, non-sensitive host label and preserve the original baseline.
Recompile after changing sources. Use an absolute executable path; on Windows,
choose an `.exe` output path. Baselines belong to the host and toolchain that
produced them, rather than to arbitrary hosted CI runners.

Each of six cases runs in its own AOT process, performs one warmup, and records
three operator calls. Inputs are the vendored 12k-face sphere and a mesh reduced
to approximately 100k faces after two subdivisions. Operations are 50% Reduce,
two Remesh iterations at bounding-box diagonal / 60, and Make Solid at resolution
96. Import, input preparation, process startup, and output checks are excluded
from operator timings. Reports retain all samples, median, min/max, output face
counts, and worker wall time. Three samples are a small repeatability check,
not a tail-latency distribution or confidence interval.

The runner rejects JIT captures. Schema 2 comparisons require identical host ID,
CPU model, logical CPU count, architecture, OS version, physical RAM, Dart
runtime, execution settings, parameters, and exact prepared-input SHA-256
fingerprints. Linux also records available CPU affinity, governor, and cgroup
limits. These checks cannot establish that a machine is idle or has the same
thermal state; operators must control background activity and power settings.
The 100k input depends on the reducer: algorithm corrections can change its hash
and correctly invalidate a comparison.

The JSON records executable and working-tree hashes, Git revision/status, and
fixture hash for investigation. Working-tree hashes describe files at capture
time; always compile immediately before capturing to associate them with the
executable. A dirty tree is recorded explicitly rather than presented as a
release commit.

## Regression gate and memory

A compatible candidate fails if any median exceeds its baseline by **more than
20%**; exactly 20% passes. Exit status is `0` for a capture/pass, `1` for a latency
regression, and `2` for invalid input, failed measurement, or incompatible
provenance. Missing cases, nonpositive samples, and medians inconsistent with
raw samples are rejected. A saved report can be checked without rerunning work:

```sh
dart run tool/performance.dart --baseline=/tmp/baseline.json \
  --compare=/tmp/candidate.json
dart test test/performance_test.dart
```

Per-case `processPeakRssBytes` uses Dart's process resident-memory high-water
mark. It includes loading the prepared mesh, warmup, all three operations,
validation, and fingerprint checks. This is neither incremental operator
allocation nor peak Dart heap usage. On Linux, the process-lifetime high-water
mark can also include launcher residency inherited across fork/exec, including
prepared inputs held by the parent. It is therefore an upper bound for the
worker process lifecycle, not an isolated operator-memory peak. Separate workers
isolate operation runs but do not eliminate that launch contribution. RSS
meanings differ across operating systems; compare only the same host and OS.
Post-operation RSS samples and startup RSS are also retained. No memory
threshold is asserted without a reviewed capacity budget.

The benchmark rejects prepared inputs and every output with invalid mesh
structure, nonpositive/nonfinite volume, boundary edges, edges with more than
two incident faces, or inconsistent winding. Raw reports include those topology
counts. The edge checks do not detect self-intersections or all nonmanifold
vertex configurations. Broader topology and geometric accuracy are covered by
`test/geometry_acceptance_test.dart` and `tool/validate_corpus.dart`; faster
results do not establish correctness. These measurements are kernel latency,
not UI frame time, interaction latency, cancellation latency, or responsiveness.
The separate [native UI probe](../apps/mmx_studio/integration_test/desktop_performance.md)
measures Studio operation time, UI-isolate progress, frame callbacks, and
cancellation on a procedural 100k-face scene. Its separate
[debug/profile results](performance/UI-RESPONSIVENESS.md) record the headless
measurements. Representative interactive hardware and repeated samples are
still required for UI performance budgets.

## Cross-platform observational workflow

[Performance evidence](../.github/workflows/performance.yml) runs on
`ubuntu-24.04`, `windows-2022`, and `macos-15`. Start it with `workflow_dispatch`
for a selected revision and 1, 3, or 5 UI captures (default 3). Pull requests
changing the workflow, collector, or harness also run it to validate those tools
and bootstrap the workflow before it exists on the default branch.

```sh
gh workflow run performance.yml --ref YOUR_BRANCH -f ui_samples=3
```

Each job compiles the kernel benchmark once, captures it twice, then launches
independent native **profile** processes for the UI probe. The UI workload
records every heartbeat and framework post-frame interval. The second kernel
capture uses the same job/machine, executable, inputs, and configuration.
Host labels include the run ID, attempt, and platform; they are deliberately
unsuitable for comparing unrelated hosted VMs across workflow runs.

Artifacts named `performance-PLATFORM-RUN-ATTEMPT` contain:

- `capture-context.json`: actual checkout revision/status, runner image/label,
  platform, capture timestamps, and explicit pending release acceptance.
- `kernel-1.json`, `kernel-2.json`, and `kernel-comparison.json`: both full AOT
  reports, raw operator samples, topology checks, and observed median changes.
- `ui-profile-NN.json`: independent cold-process profile captures, raw UI
  interval samples, source/host metadata, operation completion, and cancellation.
- `flutter-toolchain.json`, command logs, `summary.md`, and
  `artifact-sha256.json` for reproducibility and failure investigation.

A hosted median shift over the existing 20% comparison threshold is reported
in the artifact and job summary, **not adopted as a release budget**. Invalid or
incompatible reports, failed native execution, and failed topology/UI-progress/
cancellation checks fail the job. Capture failures retain logs and allow the
other capture phase to run. The collector refuses to overwrite previous evidence.

The same collector runs locally with Python 3, Dart, and Flutter on PATH:

```sh
python3 tool/performance_evidence.py --platform linux \
  --host-id=workstation-a --ui-samples=3 --output=/absolute/new/evidence-directory
```

Use `--platform windows` or `--platform macos` on those hosts (`python` is the
usual Windows launcher). Linux uses the current display, or `xvfb-run` if
`DISPLAY` is unset. `--phase kernel` or `--phase ui` supports focused diagnostics.
These runs remain observational; no option silently grants release acceptance.
Designated release hosts, representative interactive workloads, repeated
measurements, and approved latency/memory budgets are still required to close
the sustained-performance gate. Hosted VM evidence establishes platform execution
and captures useful observations, rather than certifying physical display FPS
or a product SLA.

## Observed local evidence

The original [schema-1 report](performance/2026-11-09-legacy.json) is preserved.
It lacks input hashes, raw samples, topology checks, and complete host metadata,
so the new gate rejects it with exit status 2. Historical timing ratios are
informational only: process isolation and verification changed, and the 100k
prepared input changed with correctness repairs.

A [pre-fix diagnostic capture](performance/2026-11-09-before-closure-fix.json)
produced 49,999 triangles from its nominal 100k-face Reduce workload. A closed
triangle manifold cannot have an odd triangle count. Investigation reproduced
a Float32 rounding problem in reducer collapse validation. That capture is
**not an accepted baseline**; it is retained to make the correction visible.
The runner now checks edge closure/orientation on inputs and every output, and
the reducer has a full-size regression test.


**Observed, 2026-11-09:** the corrected
[baseline](performance/2026-11-09-linux-baseline.json) and
[candidate](performance/2026-11-09-linux-candidate.json) were captured consecutively
on the same Linux workstation: Ryzen 9 7950X, 32 logical processors, 107.4 GiB
reported physical RAM, performance governor, Dart 3.13.7 AOT. Both reports have
the same executable and kernel source hashes; their dirty working-tree state is
recorded. These are repeated runs of one corrected build, demonstrating local
repeatability and the functioning gate, not cross-version performance proof.

| Case | Baseline median (ms) | Candidate median (ms) | Change | Peak RSS, baseline / candidate (MiB) | Raw change vs legacy |
|---|---:|---:|---:|---:|---:|
| `12k/reduce` | 45.853 | 49.198 | +7.30% | 95.6 / 81.5 | +3.86% |
| `12k/remesh` | 6378.595 | 6477.221 | +1.55% | 95.6 / 73.0 | +13.88% |
| `12k/solid` | 346.385 | 352.698 | +1.82% | 93.8 / 73.5 | +4.99% |
| `100k/reduce` | 480.717 | 479.274 | -0.30% | 236.6 / 194.0 | +3.67% |
| `100k/remesh` | 12907.856 | 13086.266 | +1.38% | 207.0 / 136.6 | +3.68% |
| `100k/solid` | 1003.860 | 1016.668 | +1.28% | 127.2 / 119.0 | -0.24% |

The compatible comparison passed with exit status 0. Both inputs (12,600 and
100,000 faces) and all outputs have zero boundary, nonmanifold, or inconsistently
oriented edges. The 100k Reduce output contains exactly 50,000 faces. The last
column preserves the historical timing comparison but is **not a valid gate**
for the provenance/workload reasons above. No historical raw median exceeded
the former 20% budget; that observation does not validate the old geometry.

The real saved reports also exercised failure behavior: replacing the 12k
Reduce samples with a synthetic 21% slower median produced exit status 1 and
identified that case. Comparing against the legacy report produced exit status
2. All 13 comparator/CLI/topology tests passed; targeted analysis was clean.
The largest process-lifetime RSS was 236.6 MiB in the baseline and 194.0 MiB
in the candidate. Identical code and launch/allocation variability mean this
is not evidence of a memory optimization. This historical pair covers Linux only.
New [native renderer measurements](performance/NATIVE-RENDERER.md) retain hardware
and hosted software-adapter observations. Release-host budgets remain pending.
