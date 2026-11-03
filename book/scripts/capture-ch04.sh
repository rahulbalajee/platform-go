#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 4 (book/output/ch04): the
# checkpoints of all seven build steps, the troubleshooting tables (each made
# by breaking a copy of a snapshot), the deep dive and the exercise answers.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch04.sh "$TMPDIR/c4.sh" && bash "$TMPDIR/c4.sh"
#
# Needs network access for the TLS and DNS targets (go.dev, badssl.com), jq,
# and a free port 8099 on 127.0.0.1 for the fake fleet. About three minutes.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK
root=$(pwd)
out=$root/book/output/ch04
wb=$root/workbook/ch04
rm -rf "$out"; mkdir -p "$out/ts"
work=$(mktemp -d "${TMPDIR:-/tmp}/ch04.XXXXXX")
fleet_pid=
stop_fleet() {
  if [[ -n $fleet_pid ]]; then
    pkill -P "$fleet_pid" 2>/dev/null || true
    kill "$fleet_pid" 2>/dev/null || true
    wait "$fleet_pid" 2>/dev/null || true
    fleet_pid=
  fi
}
trap 'stop_fleet; rm -rf "$work"' EXIT

goroot=$(go env GOROOT)
# Absolute paths and goroutine addresses change on every run; nothing else
# is edited. Tabs are expanded the way a terminal shows them.
scrub() {
  sed -E -e "s#${work}/#~/#g" -e "s#${goroot}#\$GOROOT#g" -e "s#${HOME}#~#g" \
    -e 's#0x[0-9a-f]{9,}#0x…#g' | expand -t 8
}
# cap FILE CMD: run CMD (a shell string) in the current directory and save
# its scrubbed stdout and stderr. A failing command is expected, not fatal.
cap() {
  local f=$1; shift
  set +e; ( eval "$*" ) > "$out/$f.raw" 2>&1; set -e
  scrub < "$out/$f.raw" > "$out/$f"; rm -f "$out/$f.raw"
}
# key FILE PATTERN [N]: the first N (default 1) lines of a capture matching
# PATTERN, quoted in the troubleshooting tables.
key() {
  grep -E -m "${3:-1}" "$2" "$out/$1" > "$out/ts/$1" ||
    { echo "no match for '$2' in $1"; exit 1; }
}

# The reader's project directory. Each step replaces the source files and
# keeps the inventories the reader wrote earlier.
proj=$work/sweep
use_step() {
  mkdir -p "$proj"
  find "$proj" -name '*.go' -delete
  rm -f "$proj/go.mod" "$proj/go.sum"
  (cd "$wb/step$1" && tar cf - .) | (cd "$proj" && tar xf -)
  cd "$proj"
}
# broken STEP: a scratch copy of a snapshot, plus the repo's lint config
# (the reader set theirs up in Chapter 1).
broken() {
  rm -rf "$work/broken"; mkdir -p "$work/broken"
  (cd "$wb/step$1" && tar cf - .) | (cd "$work/broken" && tar xf -)
  cp "$root/.golangci.yml" "$work/broken/"
  cd "$work/broken"
}
# edit FILE PERL: apply a perl substitution and insist that it changed FILE.
edit() {
  local before; before=$(cksum < "$1")
  perl -0pi -e "$2" "$1"
  [[ $(cksum < "$1") != "$before" ]] || { echo "edit did not apply to $1: $2"; exit 1; }
}
# deps STEP MODULE@VERSION: the reader's `go get` and `go mod tidy` for STEP,
# run on the previous step's go.mod. The result must equal the snapshot's.
deps() {
  local k=$1; shift
  cp "$wb/step$((k - 1))/go.mod" go.mod
  if [[ -f $wb/step$((k - 1))/go.sum ]]; then cp "$wb/step$((k - 1))/go.sum" go.sum; else rm -f go.sum; fi
  cap "s$k-goget.txt" "go get $*"
  cap "s$k-tidy.txt" 'go mod tidy'
  cmp -s go.mod "$wb/step$k/go.mod" || { echo "go.mod differs from step$k"; exit 1; }
}
# start_fleet: `go run ./cmd/fleet` from the project, as the reader runs it
# in a second terminal. A fresh fleet resets /flaky's counter.
start_fleet() {
  stop_fleet
  (cd "$proj" && exec go run ./cmd/fleet) 2> "$work/fleet.log" &
  fleet_pid=$!
  for _ in $(seq 100); do nc -z 127.0.0.1 8099 2>/dev/null && return; sleep 0.1; done
  echo "fleet did not start"; exit 1
}
fleetlog() { sleep 0.3; grep -v 'exit status\|signal:' "$work/fleet.log" > "$out/$1"; }
# interrupt FILE CMD: run CMD in the background, press "Ctrl-C" after one
# second, and record what it printed and its exit status.
interrupt() {
  local f=$1; shift
  set +e
  eval "$* > '$out/$f.raw' 2>&1 &"
  local pid=$!; sleep 1; kill -INT "$pid"; wait "$pid"; local status=$?
  set -e
  scrub < "$out/$f.raw" > "$out/$f"; rm -f "$out/$f.raw"
  echo "$status" > "$out/${f%.txt}-status.txt"
}

echo "== step 1: a sequential checker"
mkdir -p "$proj" && cd "$proj"
cap s1-modinit.txt 'go mod init sweep'
cap s1-goget.txt 'go get go@1.27.0'
use_step 1
cap s1-tree.txt "find . -name '*.go' | sort"
cap s1-test.txt 'go vet ./... && go test ./...'
cat > fleet.txt <<'EOF'
# Paths served by the fake fleet (go run ./cmd/fleet)
http://127.0.0.1:8099/ok
http://127.0.0.1:8099/down
http://127.0.0.1:8099/missing
http://127.0.0.1:8099/slow?a
http://127.0.0.1:8099/slow?b
EOF
cat > bad.txt <<'EOF'
http://127.0.0.1:8099/ok
ftp://files.example.com/
https://:8443/healthz
http://127.0.0.1:99999/ok
EOF
cap s1-cat.txt 'cat fleet.txt'
cap s1-catbad.txt 'cat bad.txt'
start_fleet
cap s1-run.txt 'go run ./cmd/sweep -timeout 2s fleet.txt'
fleetlog s1-fleet.txt
cap s1-bad.txt 'go run ./cmd/sweep bad.txt'
stop_fleet
cap s1-nofleet.txt 'go run ./cmd/sweep -timeout 2s fleet.txt'
key s1-nofleet.txt 'connect: connection refused'

broken 1; edit internal/sweep/probe.go 's/\tdefer resp.Body.Close\(\)\n//'
cap s1-bodyclose.txt 'golangci-lint run ./...'; key s1-bodyclose.txt 'bodyclose'
broken 1; edit go.mod 's/^module sweep$/module github.com\/you\/sweep/m'
cap s1-modpath.txt 'go build ./...'; key s1-modpath.txt 'is not in std'
broken 1; edit internal/sweep/runner.go 's/\tctx, cancel := context.WithTimeout/\tctx, cancel = context.WithTimeout/'
cap s1-assign.txt 'go build ./...'; key s1-assign.txt 'undefined: cancel'
broken 1; edit cmd/sweep/main.go 's/strings.ToUpper\(string\(r.Status\)\),/r.Status,/'
cap s1-unused.txt 'go build ./...'; key s1-unused.txt 'imported and not used'

echo "== step 2: concurrency"
use_step 2
deps 2 go.uber.org/goleak@v1.3.0
cap s2-tree.txt "find . -name '*.go' | sort"
cap s2-test.txt 'go vet ./... && go test ./...'
start_fleet
cap s2-run.txt 'go run ./cmd/sweep -timeout 2s fleet.txt'
cap s2-build.txt 'go build -o sweep ./cmd/sweep'
interrupt s2-ctrlc.txt ./sweep fleet.txt
rm -f sweep
stop_fleet

broken 2; edit internal/sweep/runner.go 's/\t\twg.Wait\(\) +\/\/ every check has sent its result...\n//'
cap s2-nowait.txt 'go test ./internal/sweep'; key s2-nowait.txt '^panic'
broken 2; edit internal/sweep/runner.go 's/\t\tclose\(results\) \/\/ ...so closing can.t race with a send\n//'
cap s2-noclose.txt 'go test ./internal/sweep'; key s2-noclose.txt '^panic'
broken 2; edit internal/sweep/runner.go 's/\t\twg.Go\(func\(\) \{\n\t\t\tresults <- r.check\(ctx, t\)\n\t\t\}\)/\t\tgo func() {\n\t\t\twg.Add(1)\n\t\t\tdefer wg.Done()\n\t\t\tresults <- r.check(ctx, t)\n\t\t}()/'
cap s2-addinside.txt 'go vet ./...'; key s2-addinside.txt 'WaitGroup.Add'
broken 2; edit internal/sweep/runner.go 's/type Runner struct \{\n\tcfg Config\n\}/type Runner struct {\n\tcfg     Config\n\tchecked int \/\/ progress, for a status line\n}/'
edit internal/sweep/runner.go 's/\t\t\tresults <- r.check\(ctx, t\)\n/\t\t\tresults <- r.check(ctx, t)\n\t\t\tr.checked++\n/'
cap s2-race.txt 'go test -race ./internal/sweep'; key s2-race.txt 'DATA RACE'
broken 2; cat > internal/sweep/failfast_test.go <<'EOF'
package sweep_test

import (
	"sync/atomic"
	"testing"
	"time"

	"sweep/internal/sweep"
)

// TestStopAtFirstDown stops reading after the first failure, as a
// "fail fast" option would.
func TestStopAtFirstDown(t *testing.T) {
	var peak atomic.Int64
	srv := fleet(t, &peak)
	runner := newRunner(t, srv, sweep.Config{Timeout: time.Second})
	inv := targets(t, srv.URL, "/missing", "/ok", "/ok")
	for r := range runner.Run(t.Context(), inv) {
		if r.Status == sweep.StatusDown {
			break
		}
	}
}
EOF
cap s2-leak.txt 'go test ./internal/sweep'; key s2-leak.txt 'goleak|Goroutine' 2
# The same test inside a synctest bubble: the bubble reports the leak itself.
perl -0pi -e 's/\tvar peak atomic.Int64\n(.*?)\n\}\n/\tsynctest.Test(t, func(t *testing.T) {\n\t\tvar peak atomic.Int64\n$1\n\t})\n}\n/s; s/"testing"\n/"testing"\n\t"testing\/synctest"\n/' internal/sweep/failfast_test.go
"$goroot/bin/gofmt" -w internal/sweep/failfast_test.go
cap s2-bubbleleak.txt 'go test ./internal/sweep'; key s2-bubbleleak.txt '^panic'

echo "== step 3: bounded and streaming"
use_step 3
deps 3 golang.org/x/sync@v0.24.0
cap s3-tree.txt "find . -name '*.go' | sort"
cap s3-test.txt 'go vet ./... && go test ./...'
for i in 1 2 3 4 5 6 7 8; do echo "http://127.0.0.1:8099/slow?$i"; done > many.txt
start_fleet
cap s3-c4.txt 'go run ./cmd/sweep -c 4 -timeout 1s many.txt'
fleetlog s3-fleet.txt
cap s3-c8.txt 'go run ./cmd/sweep -c 8 -timeout 1s many.txt 2>&1 | tail -2'
stop_fleet
cap s3-limits.txt 'go run ./cmd/sweep -c 0 -timeout 0s fleet.txt'

broken 3; edit conc/conc.go 's/(\t\t\t\tcancel\(\) +\/\/ ...and in-flight calls are cancelled\n)\t\t\t\tbreak\n/$1/'
cap s3-yield.txt 'go test ./conc'; key s3-yield.txt '^panic'
broken 3; edit conc/conc.go 's/\t\t<-done \/\/ every goroutine has exited; nothing outlives the loop\n//'
cap s3-nodone.txt 'go test ./conc'; key s3-nodone.txt 'Stream returned'
broken 3; cat > conc/types_test.go <<'EOF'
package conc_test

import (
	"context"
	"strconv"
	"testing"

	"sweep/conc"
)

func TestMapTypes(t *testing.T) {
	ports := []string{"80", "443"}
	label := func(ctx context.Context, n int) (string, error) {
		return "port " + strconv.Itoa(n), nil
	}
	_, _ = conc.Map(t.Context(), ports, 2, label)
}
EOF
cap s3-generic.txt 'go vet ./conc'; key s3-generic.txt 'in call to'
broken 3; edit conc/conc.go 's/g.SetLimit\(max\(limit, 1\)\)/g.SetLimit(limit)/'
cat > conc/zero_test.go <<'EOF'
package conc_test

import (
	"context"
	"testing"

	"sweep/conc"
)

func TestMapZeroLimit(t *testing.T) {
	double := func(_ context.Context, n int) (int, error) { return 2 * n, nil }
	_, _ = conc.Map(t.Context(), []int{1, 2, 3}, 0, double)
}
EOF
cap s3-zero.txt 'go test -timeout 10s -run TestMapZeroLimit ./conc'
key s3-zero.txt 'test timed out|\[chan send\]|errgroup.*Go\(' 3

echo "== step 4: probers"
use_step 4
cap s4-tree.txt "find . -name '*.go' | sort"
cap s4-test.txt 'go vet ./... && go test ./...'
cat > mixed.txt <<'EOF'
http://127.0.0.1:8099/ok
tcp://localhost:8099
tcp://127.0.0.1:9
tls://go.dev:443
dns://go.dev
dns://does-not-exist.invalid
EOF
cap s4-cat.txt 'cat mixed.txt'
start_fleet
cap s4-run.txt 'go run ./cmd/sweep mixed.txt'
stop_fleet
printf 'htps://example.com/healthz\ntcp://db.example.com\n' > typo.txt
cap s4-typo.txt 'go run ./cmd/sweep typo.txt'

broken 4; edit internal/sweep/probe.go 's/func \(p TCPProber\) Probe/func (p *TCPProber) Probe/'
cap s4-pointer.txt 'go build ./...'; key s4-pointer.txt 'does not implement'
broken 4; edit internal/sweep/probe.go 's/func \(p DNSProber\) Probe\(ctx context.Context, t Target\)/func (p DNSProber) Probe(ctx context.Context, t *Target)/'
cap s4-signature.txt 'go build ./...'; key s4-signature.txt 'does not implement|have Probe|want Probe' 3
broken 4; edit internal/sweep/resolver.go 's/\tif r.cache == nil \{\n\t\tr.cache = make\(map\[string\]cacheEntry\)\n\t\}\n//'
printf 'tcp://localhost:9\n' > one.txt
cap s4-nilmap.txt 'go run ./cmd/sweep one.txt'; key s4-nilmap.txt '^panic'

echo "== step 5: politeness and retries"
use_step 5
deps 5 golang.org/x/time@v0.16.0
cap s5-tree.txt "find . -name '*.go' | sort"
cap s5-test.txt 'go vet ./... && go test ./...'
cat > retry.txt <<'EOF'
http://127.0.0.1:8099/ok
http://127.0.0.1:8099/flaky
http://127.0.0.1:8099/down
http://127.0.0.1:8099/busy
http://127.0.0.1:8099/missing
http://127.0.0.1:8099/slow
EOF
cap s5-cat.txt 'cat retry.txt'
start_fleet
cap s5-run.txt 'go run ./cmd/sweep -timeout 1s retry.txt'
fleetlog s5-fleet-all.txt
grep -E 'busy|flaky' "$out/s5-fleet-all.txt" > "$out/s5-fleet.txt"; rm "$out/s5-fleet-all.txt"
stop_fleet

broken 5; edit retry/retry.go 's/\tp = p.withDefaults\(\)\n//'
cap s5-defaults.txt 'go test ./retry'; key s5-defaults.txt '^panic'
broken 5; edit retry/retry.go 's/\t\/\/nolint:gosec \/\/ G404: jitter needs spread, not unpredictability\n//'
cap s5-gosec.txt 'golangci-lint run ./...'; key s5-gosec.txt 'G404'
broken 5; edit internal/sweep/runner.go 's/if perr != nil && errors.Is\(context.Cause\(actx\), errAttemptTimeout\)/if perr != nil \&\& context.Cause(actx) == errAttemptTimeout/'
cap s5-errorlint.txt 'golangci-lint run ./...'; key s5-errorlint.txt 'errorlint'
broken 5; edit internal/sweep/probe.go 's/return detail, retry.Permanent\(&StatusError\{code\}\) \/\/ 4xx won.t fix itself/return detail, \&StatusError{code}/'
cap s5-permanent.txt 'go test ./internal/sweep'; key s5-permanent.txt '/missing'

echo "== step 6: reports"
use_step 6
cap s6-tree.txt "find . -name '*.go' | sort"
cap s6-test.txt 'go vet ./... && go test ./...'
start_fleet
cap s6-table.txt 'go run ./cmd/sweep -timeout 1s retry.txt'
start_fleet
cap s6-json.txt 'go run ./cmd/sweep -o json -timeout 1s retry.txt 2>/dev/null | head -22'
start_fleet
cap s6-jq.txt "go run ./cmd/sweep -o jsonl -timeout 1s retry.txt 2>/dev/null | jq -c 'select(.status==\"down\") | {target, attempts, error}'"
stop_fleet
cap s6-format.txt 'go run ./cmd/sweep -o yaml retry.txt'

broken 6; edit internal/sweep/runner.go 's/`json:"latency_ns"`/`json:latency_ns`/'
cap s6-tag.txt 'go vet ./...'; key s6-tag.txt 'struct field tag'
broken 6; edit internal/sweep/report.go 's/func \(s \*Summary\) Tally/func (s Summary) Tally/'
cap s6-receiver.txt 'go test ./internal/sweep'; key s6-receiver.txt 'String\(\) ='
cap s6-receiver-lint.txt 'golangci-lint run ./...'; key s6-receiver-lint.txt 'SA4005'
broken 6; edit internal/sweep/report.go 's/\treturn tw.Flush\(\)\n/\treturn nil\n/'
cap s6-flush.txt 'go test ./internal/sweep'; key s6-flush.txt 'want a header'

echo "== step 7: shutdown"
use_step 7
cap s7-tree.txt "find . -name '*.go' | sort"
cap s7-test.txt 'go vet ./... && go test -race ./...'
cap s7-synctest.txt "go test -v -run 'TestRunnerOutcomes|TestDoRetriesUntilSuccess' ./internal/sweep ./retry 2>&1 | grep -E '^(=== RUN|--- |ok)'"
cap s7-build.txt 'go build -o sweep ./cmd/sweep'
cap s7-version.txt './sweep -version'
cap s7-help.txt './sweep -h'
start_fleet
interrupt s7-ctrlc.txt ./sweep -c 2 many.txt
start_fleet
cap s7-deadline.txt './sweep -deadline 1500ms fleet.txt; echo "exit status $?"'
# The finished tool, for "What we're building": the fleet plus real hosts.
cat > tour.txt <<'EOF'
# Staging, as seen from the build agent
http://127.0.0.1:8099/ok
http://127.0.0.1:8099/flaky
http://127.0.0.1:8099/down
http://127.0.0.1:8099/missing
http://127.0.0.1:8099/slow
https://go.dev/
tcp://127.0.0.1:9
tls://go.dev:443
tls://expired.badssl.com:443
dns://does-not-exist.invalid
EOF
cap s7-tour-cat.txt 'cat tour.txt'
start_fleet
cap s7-tour.txt './sweep -timeout 2s tour.txt; echo "exit status $?"'
stop_fleet
rm -f sweep

broken 7; edit lifecycle/lifecycle.go 's/sigs := make\(chan os.Signal, 2\)/sigs := make(chan os.Signal)/'
cap s7-unbuffered.txt 'go vet ./...'; key s7-unbuffered.txt 'unbuffered'
broken 7; edit cmd/sweep/main.go 's/\t\tvar cancel context.CancelFunc\n\t\tctx, cancel = context.WithTimeoutCause/\t\tctx, _ = context.WithTimeoutCause/'
edit cmd/sweep/main.go 's/(opts.deadline\)\)\n)\t\tdefer cancel\(\)\n/$1/'
cap s7-lostcancel.txt 'go vet ./...'; key s7-lostcancel.txt 'cancel function'
broken 7; edit internal/sweep/runner_test.go 's/return httptest.NewTestServer\(t, mux\)/return httptest.NewServer(mux)/'
cap s7-realnet.txt 'go test -timeout 20s -run TestRunnerOutcomes ./internal/sweep'
key s7-realnet.txt 'test timed out|^ +TestRunnerOutcomes' 2
broken 7; edit cmd/sweep/main.go 's/\tcode := run\(ctx, os.Args\[1:\], os.Stdin, os.Stdout, os.Stderr\)\n\tstop\(\)\n\tos.Exit\(code\)/\tdefer stop()\n\tos.Exit(run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr))/'
cap s7-exitdefer.txt 'golangci-lint run ./...'; key s7-exitdefer.txt 'exitAfterDefer'

echo "== deep dive: the goroutine leak profile"
mkdir -p "$work/leak" && cp "$root/examples/ch04/leak/main.go" "$work/leak/"
cd "$work/leak" && printf 'module leak\n\ngo 1.27.0\n' > go.mod
cap leak.txt 'go run .'

echo "== exercise answers"
# 4.3: 200 instant targets on one host, with and without the rate limit.
cd "$proj"
for i in $(seq 200); do echo "http://127.0.0.1:8099/ok?$i"; done > ok200.txt
start_fleet
cap ex3-rate.txt 'go run ./cmd/sweep -o jsonl ok200.txt > /dev/null'
cap ex3-norate.txt 'go run ./cmd/sweep -o jsonl -rate 0 ok200.txt > /dev/null'
# 4.3: the four inventories simulated in a bubble (the solution module).
rm -rf "$work/ex3"; cp -R "$root/solutions/ch04/ex3" "$work/ex3"; cd "$work/ex3"
cap ex3-sim.txt "go test -v -run TestWhichLimitBinds ./internal/sweep 2>&1 | grep -E 'limits_test|^ok'"
# 4.4: the solution module against the fake fleet.
rm -rf "$work/ex4"; cp -R "$root/solutions/ch04/ex4" "$work/ex4"
cp "$proj/fleet.txt" "$work/ex4/"; cd "$work/ex4"
start_fleet
cap ex4-run.txt 'go run ./cmd/sweep -fail-fast fleet.txt'
stop_fleet
# 4.6: Stream without its consumerGone case.
broken 7; edit conc/conc.go 's/\t\t\t\t\tcase <-consumerGone: \/\/ nobody is listening; drop it\n//'
cap ex6-consumergone.txt 'go test ./conc 2>&1 | head -3'
cap ex6-stuck.txt "go test ./conc 2>&1 | grep -m 2 -A 1 'chan send'"

echo "captured into $out"
