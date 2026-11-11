#!/usr/bin/env bash
# Collect into a fresh directory so old source line maps cannot pollute results.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mmx_coverage_raw="$(mktemp -d "${TMPDIR:-/tmp}/mmx-coverage.XXXXXX")"
cd "$root/packages/mmx_core"
# Serialize VM source-report collection; parallel collection stalled locally
# after the tests completed. This runs the same complete suite and coverage gate.
dart test --concurrency=1 --coverage="$mmx_coverage_raw"
mkdir -p coverage
dart run coverage:format_coverage --lcov --in="$mmx_coverage_raw" \
  --out=coverage/lcov.info --packages=.dart_tool/package_config.json --report-on=lib
cd "$root"
dart run tool/check_coverage.dart
