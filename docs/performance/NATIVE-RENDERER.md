# Native renderer responsiveness observations

These measurements cover runtime commit
`3e23a87c5ab1d8a185153dfb3fe3748b9997a4c9`, including materials, incremental
history and the corrected bed outline. Later compact-window test changes do not
alter runtime code. Harness version 3 records the actual backend and adapter for
every phase; job success does not approve interactive performance budgets.

## Local hardware captures

Three separate profile processes ran on Linux x64, Ryzen 9 7950X and NVIDIA RTX
5090/Vulkan with Flutter 3.47.9/Dart 3.13.7. Every phase reports hardware
acceleration. The viewport was 892×674 logical pixels at device pixel ratio 2;
these are not directly comparable to the historical CPU captures at ratio 1.
All 90 recorded runtime-source hashes and clean Git status matched before/after.

Each process builds the same 100,352-face torus, observes idle frames, performs
one cold 50% Reduce, undoes it, then cancels a second Reduce at its first worker
heartbeat. Every output has 50,176 valid closed/manifold faces; cancellation
preserves the original mesh and history.

| Measurement | Observed result |
|---|---:|
| Reduce completion, three samples | 862.678 / 854.373 / 847.521 ms |
| Cancellation to operation settled, three samples | 241.249 / 235.338 / 234.907 ms |
| Reduce frame interval p95 | 20.746–23.464 ms |
| Worst Reduce frame interval | 63.860 ms |
| Worst cancellation frame interval | 112.362 ms |
| Maximum whole-process peak RSS | 586.918 MiB |

Unmodified raw reports: [capture 1](2026-11-09-native-profile/ui-profile-01.json),
[capture 2](2026-11-09-native-profile/ui-profile-02.json),
[capture 3](2026-11-09-native-profile/ui-profile-03.json), and
[verified summary](2026-11-09-native-profile/verified-summary.json). The complete
local validation bundle additionally retains source/binary manifests and logs.
These observations show UI progress, not sustained 60 FPS or physical presentation
latency; peak RSS includes Flutter, workers, setup and validation.

## Hosted software adapters

The matching [hosted run](https://github.com/palindsay/mmx/actions/runs/42721148715)
retains per-platform raw samples, context, checksums and logs. Its Linux llvmpipe
and Windows Microsoft Basic Render Driver adapters correctly report software
rendering. Their respective median Reduce completion times were 1580.289 and
3497.087 ms; cancellation settled in 505.270 and 3684.300 ms.

On Windows, worker cancellation finished in 0.231–0.305 ms, while operation
settlement included subsequent processing and rendering. Framework frames kept
progressing during that interval. Prompt worker termination therefore does not
promise prompt final preview completion on every adapter. These shared runners
are not a controlled comparison between operating systems or release machines.

Automatic rendering can select a native software adapter. Studio exposes its
actual status and an explicit CPU preference; compare those options on the
intended hardware when setting frame, memory and completion budgets. Native API
availability alone is not evidence of hardware acceleration or superior speed.
