#!/usr/bin/env bash
# Reproduces a flaky failure seen while collecting e2e coverage on macOS:
# coverage-instrumented processes that exit at the same moment into one
# fresh GOCOVERDIR can collide on a temporary file name. Starts eight at a
# time until one reports the failed write, then shows what was written.
# Usage: examples/ch06/flaky/covrace.sh   (from the repository root)
set -euo pipefail
bin=$(mktemp -d)
dir=$(mktemp -d)
trap 'rm -rf "$bin" "$dir" "$dir.err"' EXIT
go build -cover -o "$bin/sweep" ./cmd/sweep

for round in $(seq 1 500); do
  rm -rf "${dir:?}"/* "$dir.err"
  for _ in 1 2 3 4 5 6 7 8; do
    GOCOVERDIR=$dir "$bin/sweep" -version >/dev/null 2>>"$dir.err" &
  done
  wait
  if grep -q "emit failed" "$dir.err"; then
    echo "round $round, stderr of one process:"
    # Shorten the 32-digit hash and the paths so the message fits a page.
    sed -E -e "s#$dir#\$GOCOVERDIR#g" -e 's/[0-9a-f]{32}/<hash>/g' \
      "$dir.err" | fold -s -w 88
    echo "files written:"
    ls "$dir" | sed -E 's/[0-9a-f]{32}/<hash>/' 
    exit 0
  fi
done
echo "no collision in 500 rounds"
