#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 4.
# Usage: book/scripts/capture-ch04.sh   (from the repository root)
set -euo pipefail
out=book/output
root=$(pwd)
scrub() { sed -e "s#${root}/##g" -e 's#0x[0-9a-f]\{9,\}#0x…#g'; }

go build -o /tmp/sweep ./cmd/sweep
( cd "$out" && for i in 1 2 3 4; do
    /tmp/sweep -timeout 3s fleet.txt > sweep-table.txt 2> sweep-table.err || true
    grep -q "timed out" sweep-table.txt || break
  done )
( cd "$out" && /tmp/sweep -o jsonl -timeout 3s fleet.txt 2>/dev/null \
    | jq -c 'select(.status=="down") | {target, attempts, error}' | head -4 > sweep-jq.txt ) || true
go run ./examples/ch04/leak 2>&1 | scrub > "$out/leak.txt"
go test -count=1 -v -run 'TestRunnerOutcomes|TestDoRetriesUntilSuccess' ./internal/sweep ./pkg/retry 2>&1 \
  | grep -E '^(=== RUN|--- |ok|PASS|FAIL)' | scrub > "$out/synctest-run.txt"
go test -race -count=1 ./... 2>&1 | scrub > "$out/test-all.txt"
echo "captured into $out"
