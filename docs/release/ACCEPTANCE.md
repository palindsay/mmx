# Release acceptance record

Target: the **0.3.0 scan-to-print candidate** for Linux x64, Windows x64 and
macOS arm64, building on the optional features in
[PR #5](https://github.com/palindsay/mmx/pull/5). GitHub Releases in `palindsay/mmx`
is the publication destination. This record does not authorize or establish a
published release; signed production distribution remains pending acceptance.

## Evidence and outstanding inputs

| Area | Evidence | Remaining requirement |
|---|---|---|
| Automated correctness and installation | [Local 0.3.0 verification](../TESTING.md#local-scan-to-print-verification-2026-11-10); [PR #5 checks](https://github.com/palindsay/mmx/pull/5/checks) and [PR #4 checks](https://github.com/palindsay/mmx/pull/4/checks) are historical checkpoints | All three native CI jobs must pass for the final reviewed commit. |
| Linux native interaction | [Linux acceptance](LINUX-ACCEPTANCE.md) | Human acceptance on a clean supported desktop, including assistive technology. |
| Windows/macOS native interaction | Native integration and installer CI | Interactive clean-account checks below on both operating systems. |
| Performance | [Performance procedure](../PERFORMANCE.md) and hosted measurement artifacts | Designated machines, representative workloads and an agreed latency/frame/memory budget. |
| Scan-to-print quality | Analytical scan regressions and native preview/save/report workflow | Representative scanner exports, preserved dimensions/detail, operator review and physical prints against agreed acceptance tolerances. |
| Signing | [Release review](RELEASE-REVIEW.md) and [signing procedure](../RELEASE.md#signing-and-notarization) | Configured publisher identities; real signature, timestamp, notarization and staple verification. |
| External reference comparison | [Reference harness](../../packages/mmx_core/tool/corpus/README.md) | Independently acquired outputs with application version, settings and provenance. No external results have been supplied. |

The 2026-11-09 environment inspection recorded Linux, Wine and hosted CI access.
That inspection found no configured signing environment variables or
repository signing secrets, release environments, variables or self-hosted
runners, and located no usable Meshmixer installation.
The user explicitly deferred Windows/macOS signing hosts, identities and licensed
reference outputs on 2026-11-09. These inputs are future release work; their
deferral does not establish signature, fidelity or human-acceptance evidence.

## Local 0.3.0 observations, 2026-11-10

**[observed]** The candidate working tree passed 247 kernel and 111 Studio tests,
both analyzers, formatting, all 24 targeted coverage gates, 22 analytical corpus
cases, five Rust tests, seven strict GPU tests and four native Linux integration
workflows. Python tooling passed 28 tests with one Windows-only skip. Detailed
commands and limits are in [testing](../TESTING.md).

`make native-package` produced an optimized Linux AOT CLI, Flutter/Rust Studio,
portable archive and unsigned `.deb`. Checksums and the extracted installer file
manifest were verified, and the staged app passed a startup smoke check. A native
probe reported Vulkan on a discrete NVIDIA RTX 5090; that single frame is not
sustained large-scan performance evidence. These local binaries predate the final
documentation/commit and do not certify artifacts for a later source digest.
CI must rebuild and verify the reviewed commit on each supported release host.

## Native acceptance checklist

Record the operator, date, source commit, OS/build, architecture and exact
installer SHA-256. For each check, retain the observed result and any reproducer:

1. Install and launch from a clean ordinary user account.
2. Use native open/save dialogs with spaces and Unicode names; cancel each.
3. Save, reopen and export; confirm object metadata and physical units.
4. Decline and accept overwrite prompts; exercise an unwritable destination.
5. Edit, undo and redo; cancel expensive work and confirm the prior scene.
6. Test dirty exit and New Project with Save, Discard, Cancel and Escape; check
   canceled/failed saves preserve work and a fresh project has no stale undo/history.
7. Force termination after autosave; recover, defer and discard deliberately.
8. Open two app instances and confirm their recovery files remain independent.
9. Navigate actions and dialogs by keyboard and a screen reader; check names,
   focus, scaling and contrast at the display settings intended for release.
10. Uninstall; verify projects and recovery data remain intact.
11. Import representative scans with explicit units; inspect, preview cleanup,
    compare the original, Cancel/Apply and undo/redo. Check protected originals
    survive scene actions and save/reopen. Verify selected-region edits preserve
    unselected detail and that incompatible histories reject recipe export.
12. Open schema 1/2 fixtures, save separate schema 3 copies and reopen them;
    confirm profiles/history persist and an older reader rejects schema 3.
13. Check dimensions, bed placement, physical deviation, unresolved wall/drainage
    findings, report hashes and slicer output before the agreed physical-print trials.

Automated native interaction records are evidence for those exact executions.
They do not substitute for human accessibility acceptance, prove unrelated OS
behavior, or establish acceptable performance on different hardware.

## Publication

Review and merge the implementation after its final checks pass. Before publishing
signed packages, complete the applicable acceptance records, select the release
version metadata, rebuild from the release commit, verify signatures and regenerate
checksums. Retain the source/build receipts, dependency inventory, test reports
and previous release for rollback. Unsigned CI artifacts remain review artifacts.
