#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 6.
# Usage: book/scripts/capture-ch06.sh   (from the repository root)
# Needs Docker for the container tests and network access for benchstat.
# Takes about ten minutes, most of it fuzzing and benchmarking.
set -euo pipefail
root=$(pwd)
out=$root/book/output/ch06
mkdir -p "$out"
tmp=$(mktemp -d)
cleanup() {
  # Restore anything the golden-file demo touched, drop scratch files.
  [[ -f $tmp/runner.go ]] && cp "$tmp/runner.go" internal/sweep/runner.go
  pkill -f "fleetd -addr 127.0.0.1:18080" 2>/dev/null || true
  rm -rf "$tmp" cov sweep-cover v1.test v2.test v1.txt v2.txt sweep.test mem.out
  git worktree prune
}
trap cleanup EXIT
# Ports and absolute paths change on every run; nothing else is edited.
scrub() {
  sed -E -e "s#${root}/##g" -e "s#${HOME}#~#g" -e 's#127\.0\.0\.1:[0-9]+#127.0.0.1:PORT#g'
}
keep() { grep -E '^(=== RUN|ok|PASS|FAIL| *--- )' || true; }
# The module path is long; shorten it where it would overflow the page.
short() { sed -e 's#github.com/rahulbalajee/platform-go/##g' | expand -t 8; }
# Benchmark lines are tab-aligned for wide terminals; re-space them to fit.
benchfmt() {
  awk '/^Benchmark/ { printf "%-25s %6s", $1, $2
                      for (i = 3; i < NF; i += 2) printf "  %s %s", $i, $(i + 1)
                      print ""; next }
       { gsub(/\t/, "  "); print }'
}

echo "== table-driven tests"
go test -count=1 -v -run '^TestParseTargets$/^(tcp|tls)$' ./internal/sweep 2>&1 \
  | keep > "$out/table-run.txt"

echo "== fuzzing, before the fix (commit b0977b0, in a throwaway worktree)"
go clean -fuzzcache
git worktree add --detach "$tmp/prefix" b0977b0 >/dev/null 2>&1
cp internal/sweep/target_test.go internal/sweep/target_fuzz_test.go \
  internal/sweep/probe_fuzz_test.go "$tmp/prefix/internal/sweep/"
( cd "$tmp/prefix" &&
  go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep 2>&1 ) \
  | scrub > "$out/fuzz-targets.txt" || true
( cd "$tmp/prefix" &&
  go test -run '^$' -fuzz '^FuzzParseRetryAfter$' -fuzztime 60s ./internal/sweep 2>&1 ) \
  | scrub > "$out/fuzz-retryafter.txt" || true
git worktree remove --force "$tmp/prefix"

echo "== fuzzing, after the fix"
go test -run '^$' -fuzz '^FuzzParseTargets$' -fuzztime 60s ./internal/sweep 2>&1 \
  | tail -3 > "$out/fuzz-after.txt"

echo "== golden files"
# A JSON field rename, the kind of change a golden file exists to catch.
cp internal/sweep/runner.go "$tmp/runner.go"
perl -pi -e 's/json:"latency_ns"/json:"latency_ms"/' internal/sweep/runner.go
go test -count=1 -run 'TestReportersGolden/^json$' ./internal/sweep 2>&1 | head -15 \
  > "$out/golden-diff.txt" || true
cp "$tmp/runner.go" internal/sweep/runner.go
rm "$tmp/runner.go"
go test -count=1 -v -run 'TestReportersGolden|TestRunGolden' ./internal/sweep ./cmd/sweep 2>&1 \
  | keep > "$out/golden-pass.txt"

echo "== testscript"
go -C examples/ch06/sweepscript test -count=1 -v ./... 2>&1 | keep > "$out/script-run.txt"
# The script's environment dump (PATH and friends) is dropped: it is long
# and specific to this machine.
go -C examples/ch06/sweepscript test -count=1 -v -run 'TestScripts/^interrupt$' ./... 2>&1 \
  | awk '/testscript.go:[0-9]+: WORK=/ {skip=1; next} skip && /^ *$/ {skip=0; next} !skip' \
  | scrub > "$out/script-interrupt.txt"

echo "== testcontainers"
go -C examples/ch06/containers test -count=1 -v ./... 2>&1 \
  | perl -CSD -pe 's/[\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}]\x{FE0F}? ?//g' \
  | scrub > "$out/containers-full.txt"
grep -E '^ *(=== RUN|--- |ok|PASS|FAIL|containers_test)' "$out/containers-full.txt" \
  > "$out/containers.txt" || true
grep -E 'Building image|Built image|Creating container for image' "$out/containers-full.txt" \
  | sed -E 's/^[0-9/]+ //; s/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/<id>/g' \
  > "$out/containers-log.txt"
rm "$out/containers-full.txt"
go -C examples/ch06/containers test -count=1 -short -v ./... 2>&1 \
  | grep -E '^ *(=== RUN|--- |ok|PASS|FAIL|containers_test)' > "$out/containers-short.txt"

echo "== benchmarks"
go test -run '^$' -bench . -benchmem ./internal/sweep 2>&1 | benchfmt > "$out/bench.txt"
go test -c -o v2.test ./internal/sweep
GOEXPERIMENT=nojsonv2 go test -c -o v1.test ./internal/sweep
for i in $(seq 10); do \
  ./v1.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v1.txt; \
  ./v2.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v2.txt; \
done
go run golang.org/x/perf/cmd/benchstat@latest v1.txt v2.txt > "$out/benchstat.txt"
go test -run '^$' -bench 'Report/table' -benchmem -memprofile mem.out ./internal/sweep \
  > /dev/null
go tool pprof -sample_index=alloc_objects -top -nodecount=8 mem.out 2>/dev/null \
  | short > "$out/pprof.txt"
go build -gcflags=-m ./internal/sweep 2>&1 | grep 'report.go:9[78]' > "$out/escape.txt"

echo "== integration coverage"
go build -o "$tmp/fleetd" ./examples/ch06/fleetd
"$tmp/fleetd" -addr 127.0.0.1:18080 2>/dev/null &
fleet_pid=$!
for _ in $(seq 50); do curl -fs -o /dev/null http://127.0.0.1:18080/ok && break; sleep 0.1; done
mkdir -p cov/run && go build -cover -o sweep-cover ./cmd/sweep
printf 'http://127.0.0.1:18080/ok\nhttp://127.0.0.1:18080/missing\n' > cov/inventory.txt
GOCOVERDIR=cov/run ./sweep-cover cov/inventory.txt > "$out/cover-run.txt" 2>&1 || true
ls cov/run | sed -E 's/[0-9a-f]{32}/<hash>/' > "$out/cover-ls.txt"
go tool covdata percent -i=cov/run | short > "$out/cover-run-percent.txt"
kill "$fleet_pid"

mkdir -p cov/unit cov/e2e
go test -cover ./cmd/sweep ./internal/sweep ./pkg/conc ./pkg/retry ./pkg/lifecycle \
  -args -test.gocoverdir="$PWD/cov/unit" 2>&1 | short > "$out/cover-unit.txt"
GOCOVERDIR=$PWD/cov/e2e go -C examples/ch06/sweepscript test -count=1 ./... 2>&1 \
  | short > "$out/cover-e2e.txt"
go tool covdata percent -i=cov/unit | short > "$out/cover-unit-percent.txt"
mkdir -p cov/all && go tool covdata merge -o cov/all -i="cov/unit,$(echo cov/e2e/* | tr ' ' ,)" \
  > "$out/cover-merge.txt" 2>&1
go tool covdata percent -i=cov/all | short > "$out/cover-all-percent.txt"
go tool covdata textfmt -i=cov/all -o cov/all.out > "$out/cover-textfmt.txt" 2>&1
go tool cover -func=cov/all.out | short | sort -k3 -n | head -12 > "$out/cover-func.txt"

echo "== flaky tests"
go test -tags flakydemo -count=2 -run 'TestRegistry|TestRegister' ./examples/ch06/flaky \
  > "$out/flaky-count.txt" 2>&1 || true
for _ in $(seq 20); do
  if ! go test -tags flakydemo -count=1 -shuffle=on -run 'TestRegistry|TestRegister' \
      ./examples/ch06/flaky > "$out/flaky-shuffle.txt" 2>&1; then break; fi
done
seed=$(sed -n 's/^-test.shuffle //p' "$out/flaky-shuffle.txt")
echo "$seed" > "$out/flaky-seed.txt"
go test -tags flakydemo -count=1 -shuffle="$seed" -run 'TestRegistry|TestRegister' \
  ./examples/ch06/flaky > "$out/flaky-reproduce.txt" 2>&1 || true
go test -tags flakydemo -count=1 -run 'TestEndpoints' ./examples/ch06/flaky 2>&1 \
  | scrub > "$out/flaky-defer.txt" || true
go test -tags flakydemo -count=1 -run 'TestProxyFromEnvironment' ./examples/ch06/flaky 2>&1 \
  | head -2 | fold -s -w 88 > "$out/flaky-setenv.txt" || true
examples/ch06/flaky/covrace.sh > "$out/covrace.txt"

echo "captured into $out"
