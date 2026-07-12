#!/usr/bin/env bash
#
# Single lint lane for FloorplanViewer.
# Runs SwiftFormat in lint (dry-run) mode, then SwiftLint --strict. Exits non-zero on any
# violation so it can gate CI and the Definition of Done.
#
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

echo "==> SwiftFormat (lint mode)"
if ! swiftformat --lint . ; then
  echo "SwiftFormat found violations." >&2
  fail=1
fi

echo "==> SwiftLint (strict)"
if ! swiftlint lint --strict --quiet ; then
  echo "SwiftLint found violations." >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "==> Lint FAILED" >&2
  exit 1
fi

echo "==> Lint clean"
