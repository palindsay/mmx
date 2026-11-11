# Incremental undo evidence

Document history shares immutable geometry blocks, including UV/material index
buffers. Live mesh buffers remain independently mutable. Sparse changes retain
only changed blocks; transformations retain metadata and share geometry.
Materials and immutable textures are shared and counted once across history.
History has a byte budget (512 MiB by default) and an entry budget (1000).

## Reproduce

From `packages/mmx_core`:

```sh
dart test test/incremental_history_test.dart
dart compile exe tool/history_memory.dart -o /tmp/mmx-history-memory
/tmp/mmx-history-memory > /tmp/mmx-history-memory.json
```

The benchmark makes a procedural 100,352-face plane, records 30 transforms and
30 sparse position edits, and verifies all 60 undo steps. The report records input
and implementation hashes, runtime, raw snapshot latencies and process peak RSS.

## Local observation

The [2026-11-09 Linux capture](INCREMENTAL-UNDO-LINUX.json) retained 1,818,664 bytes
after the transforms and 2,300,560 bytes after the sparse edits. Full payload
copies for those 60 entries would total approximately 108,711,120 bytes.
Snapshot medians were 1.19 ms for transforms and 1.25 ms for sparse edits on this
developer host. These figures describe this workload only.

Payload accounting excludes VM objects, cache indexes and temporary rollback
checkpoints. Process peak RSS includes input preparation and launcher/runtime
residency, so it must not be interpreted as history allocation. Changed meshes
still require contiguous live buffers when restored. Snapshots scan mutable
buffers to detect in-place edits; this reduces retained copies but does not
promise constant-time capture or zero transient memory.
