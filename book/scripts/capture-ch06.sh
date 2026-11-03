#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 6 (book/output/ch06): the
# checkpoints of the nine labs, the troubleshooting tables (each made by
# breaking a copy of a lab snapshot), and the exercise answers.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch06.sh "$TMPDIR/c6.sh" && bash "$TMPDIR/c6.sh"
#
# Needs Docker with postgres:17-alpine in the local image cache (Lab 9),
# network access for benchstat, and a free port 8099 on 127.0.0.1 for the
# fake fleet. About fifteen minutes; fuzzing and benchmarks take most of it.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK GOCOVERDIR
export GIT_AUTHOR_NAME=reader GIT_AUTHOR_EMAIL=reader@example.com
export GIT_COMMITTER_NAME=reader GIT_COMMITTER_EMAIL=reader@example.com
root=$(pwd)
out=$root/book/output/ch06
wb=$root/workbook/ch06
ch4=$root/workbook/ch04/step7
# ONLY="5 6" re-captures just those labs (and keeps the other files).
ONLY=${ONLY:-}
want() { [[ -z $ONLY || " $ONLY " == *" $1 "* ]]; }
if [[ -z $ONLY ]]; then rm -rf "$out"; fi
mkdir -p "$out/ts"
work=$(mktemp -d "${TMPDIR:-/tmp}/ch06.XXXXXX")
fleet_pid=
stop_fleet() {
  if [[ -n $fleet_pid ]]; then
    pkill -P "$fleet_pid" 2>/dev/null || true
    kill "$fleet_pid" 2>/dev/null || true
    wait "$fleet_pid" 2>/dev/null || true
    fleet_pid=
  fi
}
trap 'stop_fleet; go clean -fuzzcache; rm -rf "$work"' EXIT

goroot=$(go env GOROOT)
# Absolute paths, kernel-chosen ports and goroutine addresses change on every
# run; nothing else is edited. Tabs are expanded the way a terminal shows them.
scrub() {
  sed -E -e "s#${work}/#~/#g" -e "s#${goroot}#\$GOROOT#g" -e "s#${HOME}#~#g" \
    -e 's#(127\.0\.0\.1|localhost|\[::1\]):[0-9]{5}#\1:PORT#g' \
    -e 's#0x[0-9a-f]{9,}#0x…#g' -e 's#[0-9a-f]{32}#<hash>#g' | expand -t 8
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
    { echo "no match for '$2' in $1"; cat "$out/$1"; exit 1; }
}
# keep: the lines of `go test -v` output that say what ran and how it ended.
keep() { grep -E '^(=== RUN|ok|PASS|FAIL|\?| *--- )' || true; }
# benchfmt: benchmark lines are tab-aligned for wide terminals; re-space them.
benchfmt() {
  awk '/^Benchmark/ { printf "%-25s %6s", $1, $2
                      for (i = 3; i < NF; i += 2) printf "  %s %s", $i, $(i + 1)
                      print ""; next }
       { gsub(/\t/, "  "); print }'
}

# The reader's project directory: their sweep from Chapter 4, under git.
# Each lab replaces the files with that lab's snapshot and keeps .git and the
# reader's inventories (*.txt at the top).
proj=$work/sweep
use_step() {
  find "$proj" -mindepth 1 -maxdepth 1 ! -name .git ! -name '*.txt' -exec rm -rf {} +
  (cd "$wb/step$1" && tar cf - .) | (cd "$proj" && tar xf -)
  # No lab may change a file that came from Chapter 4.
  (cd "$ch4" && find . -type f ! -name go.mod ! -name go.sum) | while read -r f; do
    cmp -s "$ch4/$f" "$proj/$f" || { echo "step$1 changed Chapter 4's $f"; exit 1; }
  done
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
# deps STEP PREVDIR MODULE@VERSION: the reader's `go get` and `go mod tidy`,
# run on the previous go.mod. The result must equal the snapshot's.
deps() {
  local k=$1 prev=$2; shift 2
  cp "$prev/go.mod" go.mod; cp "$prev/go.sum" go.sum
  cap "s$k-goget.txt" "go get $*"
  cap "s$k-tidy.txt" 'go mod tidy'
  cmp -s go.mod "$wb/step$k/go.mod" || { echo "go.mod differs from step$k"; exit 1; }
}
# start_fleet: `go run ./cmd/fleet` from the project, as the reader runs it
# in a second terminal.
start_fleet() {
  stop_fleet
  (cd "$proj" && exec go run ./cmd/fleet) 2> "$work/fleet.log" &
  fleet_pid=$!
  for _ in $(seq 100); do nc -z 127.0.0.1 8099 2>/dev/null && return; sleep 0.1; done
  echo "fleet did not start"; exit 1
}

echo "== before the labs"
mkdir -p "$proj"
(cd "$ch4" && tar cf - .) | (cd "$proj" && tar xf -)
cp "$wb/step1/.gitignore" "$proj/"
cd "$proj"
cap s0-git.txt 'git init -q && git add -A && git commit -qm "sweep from Chapter 4"'
cap s0-test.txt 'go test ./...'

if want 1; then
echo "== lab 1: table tests"
use_step 1
deps 1 "$ch4" github.com/google/go-cmp@v0.7.0
cap s1-status.txt 'git status -s -uall'
cap s1-test.txt 'go test ./internal/sweep'
cap s1-run.txt "go test -v -run '^TestParseTargets\$/^(tcp|tls)\$' ./internal/sweep"
broken 1; edit internal/sweep/target_test.go 's/\{0, sweep.KindTCP, "\[::1\]:5432", "tcp/{0, sweep.KindTCP, "::1", "tcp/'
cap s1-fail.txt "go test -run '^TestParseTargets\$' ./internal/sweep"

broken 1; cat > internal/sweep/line_test.go <<'EOF'
package sweep_test

import (
	"testing"

	"sweep/internal/sweep"
)

func TestParseOneLine(t *testing.T) {
	if _, err := sweep.parseTarget("tcp://db:5432"); err != nil {
		t.Fatal(err)
	}
}
EOF
cap s1-unexported.txt 'go vet ./internal/sweep'; key s1-unexported.txt 'parseTarget'
broken 1; cp "$ch4/go.mod" go.mod; cp "$ch4/go.sum" go.sum
cap s1-nomod.txt 'go test ./internal/sweep'; key s1-nomod.txt 'no required module|go get' 2
broken 1; edit internal/sweep/target_test.go 's/if diff := cmp.Diff\(tc.want, project\(got\)\); diff != "" \{\n\t+t.Errorf\("ParseTargets\(%q\) mismatch \(-want \+got\):\\n%s", tc.in, diff\)/if p := project(got); p != tc.want {\n\t\t\t\tt.Errorf("ParseTargets(%q) = %v, want %v", tc.in, p, tc.want)/'
cap s1-slicecmp.txt 'go vet ./internal/sweep'; key s1-slicecmp.txt 'compared to nil'
broken 1; edit internal/sweep/target_test.go 's/(func TestParseTargets\(t \*testing.T\) \{.*?t.Parallel\(\)\n)/$1\t\t\tt.Setenv("TZ", "UTC")\n/s'
cap s1-setenv.txt 'go test ./internal/sweep'; key s1-setenv.txt '^panic'
broken 1
cap s1-norun.txt "go test -run '^TestParseTarget\$/tcp' ./internal/sweep"; key s1-norun.txt 'no tests to run'
fi

if want 2; then
echo "== lab 2: fakes"
use_step 2
cap s2-status.txt 'git status -s -uall'
cap s2-run.txt "go test -v -run 'TestRunnerHonoursRetryAfter|TestRunnerRateLimitSpacesAttempts' ./internal/sweep"
cap s2-fleet.txt 'go test -v ./internal/sweep/sweeptest'
broken 2; edit internal/sweep/fake_test.go 's/func \(p \*scriptedProber\) Probe/func (p scriptedProber) Probe/'
cap s2-copylocks.txt 'go vet ./internal/sweep'; key s2-copylocks.txt 'lock'
broken 2; edit internal/sweep/fake_test.go 's/sweep.KindHTTP: fake\}/sweep.KindHTTP: *fake}/'
cap s2-pointer.txt 'go vet ./internal/sweep'; key s2-pointer.txt 'does not implement'
broken 2; edit internal/sweep/fake_test.go 's/(func TestRunnerHonoursRetryAfter\(t \*testing.T\) \{\n)\tsynctest.Test\(t, func\(t \*testing.T\) \{\n(.*?)\n\t\}\)\n\}/$1\tfunc(t *testing.T) {\n$2\n\t}(t)\n}/s'
cap s2-nobubble.txt "go test -run 'TestRunnerHonoursRetryAfter' ./internal/sweep"; key s2-nobubble.txt 'retried after'
broken 2; edit internal/sweep/fake_test.go 's/retry.Policy\{MaxAttempts: 3, MaxDelay: 10 \* time.Second\}/retry.Policy{MaxAttempts: 3, MaxDelay: 2 * time.Second}/'
cap s2-maxdelay.txt "go test -run 'TestRunnerHonoursRetryAfter' ./internal/sweep"; key s2-maxdelay.txt 'retried after'
fi

if want 3; then
echo "== lab 3: golden files"
use_step 3
rm -rf internal/sweep/testdata/golden cmd/sweep/testdata
cap s3-missing.txt 'go test -run TestReportersGolden ./internal/sweep'; key s3-missing.txt 'no such file' 1
cap s3-update.txt 'go test ./internal/sweep -run TestReportersGolden -update'
cap s3-ls.txt 'ls internal/sweep/testdata/golden'
cap s3-cli-update.txt 'go test ./cmd/sweep -run TestRunGolden -update'
for g in "$wb"/step3/internal/sweep/testdata/golden/* "$wb"/step3/cmd/sweep/testdata/golden/*; do
  rel=${g#"$wb"/step3/}
  cmp -s "$g" "$rel" || { echo "-update wrote a different $rel"; diff "$g" "$rel"; exit 1; }
done
cap s3-pass.txt "go test -count=1 -v -run 'TestReportersGolden|TestRunGolden' ./internal/sweep ./cmd/sweep | grep -E '^(---|    ---|ok)'"
cap s3-status.txt 'git status -s -uall'
broken 3; edit internal/sweep/runner.go 's/json:"latency_ns"/json:"latency_ms"/'
cap s3-rename.txt "go test -run 'TestReportersGolden/^json\$' ./internal/sweep"
broken 3
cap s3-updateall.txt 'go test ./... -update'; key s3-updateall.txt 'flag provided but not defined'
broken 3; edit cmd/sweep/golden_test.go 's/path := filepath.Join\(testDir, "testdata"/path := filepath.Join("testdata"/'
cap s3-relpath.txt 'go test ./cmd/sweep'; key s3-relpath.txt 'no such file'
broken 3; edit cmd/sweep/golden_test.go 's/return elapsedRE.ReplaceAllString\(s, " in ELAPSED: "\)/return s/'
cap s3-noscrub.txt 'go test ./cmd/sweep'; key s3-noscrub.txt 'mismatch|^ +[-+] +"' 3
broken 3; edit cmd/sweep/golden_test.go 's/(func TestRunGolden\(t \*testing.T\) \{\n)/$1\tt.Parallel()\n/'
cap s3-chdir.txt 'go test ./cmd/sweep'; key s3-chdir.txt '^panic'
fi

if want 4; then
echo "== lab 4: testscript"
use_step 4
deps 4 "$wb/step3" github.com/rogpeppe/go-internal@v1.16.0
cap s4-status.txt 'git status -s -uall'
cap s4-run.txt 'go test -count=1 -v ./sweepscript | grep -E "^(=== RUN|---|    ---|ok|PASS|FAIL)"'
# The script's environment dump (PATH and friends) is dropped: it is long
# and specific to this machine.
cap s4-interrupt.txt "go test -count=1 -v -run 'TestScripts/^interrupt\$' ./sweepscript 2>&1 | awk '/testscript.go:[0-9]+: WORK=/ {skip=1; next} skip && /^ *\$/ {skip=0; next} !skip'"
broken 4; edit sweepscript/testdata/script/exit_status.txtar 's/exits 2 sweep -c 0 healthy.txt/exits 1 sweep -c 0 healthy.txt/'
cap s4-exits.txt 'go test ./sweepscript'; key s4-exits.txt 'exited with status'
broken 4; edit sweepscript/testdata/script/exit_status.txtar 's/^envsubst healthy.txt\n//m'
cap s4-envsubst.txt 'go test ./sweepscript'; key s4-envsubst.txt 'unsupported scheme|exited with status' 2
broken 4; edit sweepscript/script_test.go 's/\t\t\tpath := binDir.*\n\t\t\tenv.Setenv\("PATH", path\)\n//'
cap s4-path.txt 'go test ./sweepscript'; key s4-path.txt 'executable file not found'
broken 4; edit sweepscript/testdata/script/exit_status.txtar 's/ \+1 \+200 OK\$/ +2 +200 OK\$/'
cap s4-regex.txt 'go test ./sweepscript'; key s4-regex.txt 'no match for'
broken 4; edit sweepscript/testdata/script/help.txtar 's/concurrently \(default 32\)/concurrently (default 16)/'
cap s4-cmp.txt 'go test ./sweepscript'; key s4-cmp.txt 'differ|^ +[-+] +max targets' 3
fi

if want 5; then
echo "== lab 5: fuzzing"
use_step 5
cap s5-status.txt 'git status -s -uall'
cap s5-seeds.txt "go test -count=1 -v -run '^Fuzz' ./internal/sweep | grep -E '^(---|    ---|ok)'"
# The reader breaks the parser the way Chapter 4's first draft had it, in
# their own project, before any corpus file exists; then fuzzes, restores the
# file with git, and replays the saved input.
go clean -fuzzcache
rm -rf internal/sweep/testdata/fuzz
# The rows that pin the port rule come after the fuzzing in the text.
cp "$wb/step4/internal/sweep/target_test.go" internal/sweep/target_test.go
edit internal/sweep/target.go 's/\t"strconv"\n//'
edit internal/sweep/target.go 's/\tif p := u.Port\(\); p != "" \{\n.*?\n\t\}\n//s'
cap s5-fuzz-targets.txt "go test -run '^\$' -fuzz '^FuzzParseTargets\$' -fuzztime 60s ./internal/sweep"
cap s5-corpus-ls.txt 'ls internal/sweep/testdata/fuzz/FuzzParseTargets'
cap s5-corpus-cat.txt 'cat internal/sweep/testdata/fuzz/FuzzParseTargets/*'
cap s5-regress.txt 'go test ./internal/sweep'
key s5-regress.txt 'FAIL: FuzzParseTargets/|accepted' 2
cap s5-restore.txt 'git restore internal/sweep/target.go'
cap s5-replay.txt "go test -v -run '^FuzzParseTargets\$' ./internal/sweep | grep -E '^(---|    ---|ok)'"
rm -rf internal/sweep/testdata/fuzz
edit internal/sweep/probe.go 's/return time.Duration\(min\(secs, maxSecs\)\) \* time.Second, true/return time.Duration(secs) * time.Second, true/'
cap s5-fuzz-retryafter.txt "go test -run '^\$' -fuzz '^FuzzParseRetryAfter\$' -fuzztime 60s ./internal/sweep"
cap s5-restore2.txt 'git restore internal/sweep/probe.go'
use_step 5
cap s5-fuzz-after.txt "go test -run '^\$' -fuzz '^FuzzParseTargets\$' -fuzztime 60s ./internal/sweep 2>&1 | tail -3"
broken 5
cap s5-multi.txt "go test -run '^\$' -fuzz Fuzz ./internal/sweep"; key s5-multi.txt 'will not fuzz'
cap s5-pkgs.txt "go test -run '^\$' -fuzz '^FuzzParseTargets\$' ./..."; key s5-pkgs.txt 'multiple packages'
broken 5; edit internal/sweep/probe_fuzz_test.go 's/^package sweep$/package sweep_test/m'
cap s5-external.txt 'go vet ./internal/sweep'; key s5-external.txt 'undefined: parseRetryAfter'
broken 5; edit internal/sweep/probe_fuzz_test.go 's/f.Add\("120"\)/f.Add(120)/'
cap s5-addtype.txt "go test -run '^FuzzParseRetryAfter\$' ./internal/sweep"; key s5-addtype.txt 'mismatched type' 1
fi

if want 6; then
echo "== lab 6: benchmarks"
use_step 6
cap s6-status.txt 'git status -s -uall'
cap s6-bench.txt "go test -run '^\$' -bench . -benchmem ./internal/sweep | benchfmt"
cap s6-count.txt "go test -run '^\$' -bench 'ParseTargets' -count 5 ./internal/sweep | benchfmt"
go test -run '^$' -bench 'Report/table' -benchmem -memprofile mem.out ./internal/sweep > /dev/null
cap s6-pprof.txt 'go tool pprof -sample_index=alloc_objects -top -nodecount=8 mem.out'
cap s6-pprof-inuse.txt 'go tool pprof -top -nodecount=3 mem.out'; key s6-pprof-inuse.txt 'Showing nodes'
# The grep names the three lines of the Fprintf call that prints a row; the
# chapter shows the command exactly as it ran, from s6-escape-cmd.txt.
fp=$(grep -n 'fmt.Fprintf(tw, "%s\\t%s' internal/sweep/report.go | cut -d: -f1)
escmd="go build -gcflags=-m ./internal/sweep 2>&1 | grep -E 'report.go:($fp|$((fp + 1))|$((fp + 2))):' | grep -v inlining"
echo "$escmd" > "$out/s6-escape-cmd.txt"
cap s6-escape.txt "$escmd"
go test -c -o v2.test ./internal/sweep
GOEXPERIMENT=nojsonv2 go test -c -o v1.test ./internal/sweep
for _ in $(seq 10); do
  ./v1.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v1.txt
  ./v2.test -test.run '^$' -test.bench 'Report|Decode' -test.benchmem >> v2.txt
done
cap s6-benchstat.txt 'go run golang.org/x/perf/cmd/benchstat@latest v1.txt v2.txt'
rm -f v1.test v2.test v1.txt v2.txt mem.out sweep.test
broken 6
cap s6-benchpath.txt 'go test -bench ./internal/sweep'; key s6-benchpath.txt 'no Go files'
go test -c -o one.test ./internal/sweep
./one.test -test.run '^$' -test.bench 'Report/json' -test.benchmem > a.txt
./one.test -test.run '^$' -test.bench 'Report/json' -test.benchmem > b.txt
cap s6-onerun.txt 'go run golang.org/x/perf/cmd/benchstat@latest a.txt b.txt'
key s6-onerun.txt 'need >= 6 samples'
cap s6-memprofile.txt "go test -run '^\$' -bench . -memprofile mem.out ./..."
key s6-memprofile.txt 'multiple packages'
fi

if want 7; then
echo "== lab 7: coverage"
use_step 7
cap s7-status.txt 'git status -s -uall'
printf 'http://127.0.0.1:8099/ok\nhttp://127.0.0.1:8099/missing\n' > cov.txt
cap s7-cat.txt 'cat cov.txt'
start_fleet
cap s7-build.txt 'go build -cover -o sweep-cover ./cmd/sweep'
cap s7-run.txt 'mkdir -p cov/run && GOCOVERDIR=cov/run ./sweep-cover cov.txt'
cap s7-ls.txt 'ls cov/run'
cap s7-percent.txt 'go tool covdata percent -i=cov/run'
cap s7-nocoverdir.txt './sweep-cover cov.txt'; key s7-nocoverdir.txt 'GOCOVERDIR'
stop_fleet
cap s7-unit.txt 'mkdir -p cov/unit && go test -cover ./cmd/sweep ./internal/sweep ./conc ./retry ./lifecycle \
  -args -test.gocoverdir="$PWD/cov/unit"'
# A shared GOCOVERDIR is the flake Lab 8 diagnoses; retry until a clean run.
for _ in 1 2 3 4 5; do
  rm -rf cov/e2e
  cap s7-e2e.txt 'mkdir -p cov/e2e && GOCOVERDIR=$PWD/cov/e2e go test -count=1 ./sweepscript'
  grep -q '^ok' "$out/s7-e2e.txt" && break
done
cap s7-e2e-percent.txt 'go tool covdata percent -i=cov/e2e'
cap s7-merge.txt 'mkdir -p cov/all && go tool covdata merge -i=cov/unit,cov/e2e -o=cov/all'
cap s7-all-percent.txt 'go tool covdata percent -i=cov/all'
cap s7-textfmt.txt 'go tool covdata textfmt -i=cov/all -o=cov/all.out'
cap s7-func.txt 'go tool cover -func=cov/all.out | sort -k3 -n | head -12'
cap s7-relative.txt 'go test -cover ./internal/sweep -args -test.gocoverdir=cov/unit'
key s7-relative.txt 'inaccessible' 1
cap s7-mergeout.txt 'go tool covdata merge -i=cov/unit -o=cov/nowhere'; key s7-mergeout.txt '.' 1
rm -rf cov sweep-cover cov.txt
broken 6; mkdir -p cov/e2e
cap s7-nocover.txt 'GOCOVERDIR=$PWD/cov/e2e go test -count=1 ./sweepscript && go tool covdata percent -i=cov/e2e'
key s7-nocover.txt 'no applicable|warning|error' 1
fi

if want 8; then
echo "== lab 8: flaky tests"
use_step 8
cap s8-status.txt 'git status -s -uall'
cap s8-count.txt "go test -tags flakydemo -count=2 -run 'TestRegistry|TestRegister' ./flaky"
for _ in $(seq 20); do
  cap s8-shuffle.txt "go test -tags flakydemo -count=1 -shuffle=on -run 'TestRegistry|TestRegister' ./flaky"
  grep -q '^FAIL' "$out/s8-shuffle.txt" && break
done
sed -n 's/^-test.shuffle //p' "$out/s8-shuffle.txt" > "$out/s8-seed.txt"
seed=$(cat "$out/s8-seed.txt")
cap s8-replay.txt "go test -tags flakydemo -count=1 -shuffle=$seed -run 'TestRegistry|TestRegister' ./flaky"
cap s8-defer.txt "go test -tags flakydemo -count=1 -run 'TestEndpoints' ./flaky"
key s8-defer.txt 'refused' 1
cap s8-setenv.txt "go test -tags flakydemo -count=1 -run 'TestProxyFromEnvironment' ./flaky 2>&1 | head -2 | fold -s -w 88"
key s8-setenv.txt '^panic|^t.Parallel' 2
cap s8-notags.txt "go test -run 'TestRegistry|TestRegister' ./flaky"; key s8-notags.txt 'no test files'
cap s8-covrace.txt 'flaky/covrace.sh'; key s8-covrace.txt 'emit failed' 1
cap s8-after.txt 'for i in $(seq 30); do \
  rm -rf cov/e2e && mkdir -p cov/e2e && \
  GOCOVERDIR=$PWD/cov/e2e go test -count=1 ./sweepscript > /dev/null 2>&1 \
    && echo pass || echo FAIL; \
done | sort | uniq -c'
cap s8-ls.txt 'ls cov/e2e'
mkdir -p cov/unit
go test -cover ./cmd/sweep ./internal/sweep ./conc ./retry ./lifecycle \
  -args -test.gocoverdir="$PWD/cov/unit" > /dev/null
cap s8-merge.txt 'mkdir -p cov/all && go tool covdata merge -i="cov/unit,$(echo cov/e2e/* | tr " " ,)" -o=cov/all'
cap s8-all-percent.txt 'go tool covdata percent -i=cov/all'
rm -rf cov
fi

if want 9; then
echo "== lab 9: testcontainers"
use_step 8
mkdir containers && cd containers
cap s9-modinit.txt 'go mod init sweep/containers'
cap s9-gogo.txt 'go get go@1.27.0'
cap s9-edit.txt 'go mod edit -require=sweep@v0.0.0 -replace=sweep=../'
cp "$wb/step9/containers/doc.go" "$wb/step9/containers/containers_test.go" .
cap s9-goget.txt 'go get github.com/testcontainers/testcontainers-go@v0.44.0 2>&1 | tail -3'
cap s9-tidy.txt 'go mod tidy'
cmp -s go.mod "$wb/step9/containers/go.mod" || { echo "containers go.mod differs"; exit 1; }
cap s9-short.txt "go test -count=1 -short -v ./... | grep -E '^ *(=== RUN|--- |ok|PASS|FAIL|containers_test)'"
cap s9-full.txt 'go test -count=1 -v ./...'
perl -CSD -pi -e 's/[\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}]\x{FE0F}? ?//g' "$out/s9-full.txt"
grep -E '^ *(=== RUN|--- |ok|PASS|FAIL|containers_test)' "$out/s9-full.txt" > "$out/s9-run.txt" || true
grep -E 'Building image|Built image|Creating container for image' "$out/s9-full.txt" \
  | sed -E 's/^[0-9/]+ //; s/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/<id>/g' \
  > "$out/s9-log.txt"
cd ..
use_step 9
cap s9-status.txt 'git status -s -uall'
cap s9-test.txt 'go vet ./... && go test -race ./...'
broken 9; cd containers; edit go.mod 's/\nreplace sweep => ..\/\n//'
cap s9-noreplace.txt 'go mod tidy'; key s9-noreplace.txt 'sweep'
broken 9; cd containers; edit containers_test.go 's/"CGO_ENABLED=0", "GOOS=linux", /"CGO_ENABLED=0", /'
cap s9-goos.txt "go test -count=1 -run TestSweepAgainstFleetContainer ./..."
key s9-goos.txt 'exec format|exited|exit code|failed' 2
fi

if want ex; then
echo "== exercise answers"
# 6.1: the new script fails on the finished labs.
broken 9; cp "$wb/exercises/ex1/sweepscript/testdata/script/empty.txtar" sweepscript/testdata/script/
cap ex1-fail.txt "go test -run 'TestScripts/^empty\$' ./sweepscript"
# 6.3: the stronger property finds signed values in seconds.
rm -rf "$work/ex3"; cp -R "$root/solutions/ch06/ex3" "$work/ex3"; cd "$work/ex3"
cp "$wb/step9/internal/sweep/probe.go" internal/sweep/probe.go
cat >> internal/sweep/probe.go <<'EOF'

// allDigits reports whether s is one or more ASCII digits.
func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := range len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
EOF
rm -f internal/sweep/retryafter_rfc_test.go
go clean -fuzzcache
cap ex3-fuzz.txt "go test -run '^\$' -fuzz '^FuzzParseRetryAfter\$' -fuzztime 60s ./internal/sweep"
# 6.7: the table reporter before and after, interleaved.
cd "$wb/step9" && go test -c -o "$work/old.test" ./internal/sweep
cd "$root/solutions/ch06/ex7" && go test -c -o "$work/new.test" ./internal/sweep
cd "$work"
for _ in $(seq 10); do
  ./old.test -test.run '^$' -test.bench 'Report/table' -test.benchmem >> old.txt
  ./new.test -test.run '^$' -test.bench 'Report/table' -test.benchmem >> new.txt
done
cap ex7-benchstat.txt 'go run golang.org/x/perf/cmd/benchstat@latest old.txt new.txt'
fi

echo "captured into $out"
