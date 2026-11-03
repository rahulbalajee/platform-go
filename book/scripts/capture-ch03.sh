#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 3 (book/output/ch03): the
# checkpoints of all eight build steps, the troubleshooting tables (each made
# by breaking a copy of a snapshot), and the exercise answers.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch03.sh "$TMPDIR/c3.sh" && bash "$TMPDIR/c3.sh"
#
# Needs jq, git, golangci-lint, a free port 8787 on 127.0.0.1 for the fake
# deployment API, and (for one capture) the kind cluster "watchtower".
# About four minutes.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK
export PATH="$HOME/go/bin:$PATH"
root=$(pwd)
out=$root/book/output/ch03
wb=$root/workbook/ch03
rm -rf "$out"; mkdir -p "$out/ts"
work=$(mktemp -d "${TMPDIR:-/tmp}/ch03.XXXXXX")
work=$(cd "$work" && pwd) # no "//" from a TMPDIR that ends in a slash
# Crash reports and the runtime's fatal-error files go to $TMPDIR. /tmp is
# where they land on Linux; macOS gives each user a directory of its own.
export TMPDIR=/tmp
api_pid=
stop_api() {
  if [[ -n $api_pid ]]; then
    pkill -P "$api_pid" 2>/dev/null || true
    kill "$api_pid" 2>/dev/null || true
    wait "$api_pid" 2>/dev/null || true
    api_pid=
  fi
}
trap 'stop_api; rm -rf "$work"' EXIT

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
# capx FILE CMD: cap, plus the exit status in FILE with .code for .txt,
# shown in the book as the output of `echo $?`.
capx() {
  local f=$1; shift
  set +e; ( eval "$*" ) > "$out/$f.raw" 2>&1; local s=$?; set -e
  scrub < "$out/$f.raw" > "$out/$f"; rm -f "$out/$f.raw"
  echo "$s" > "$out/${f%.txt}.code"
}
# key FILE PATTERN [N]: the first N (default 1) lines of a capture matching
# PATTERN, quoted in the troubleshooting tables.
key() {
  grep -E -m "${3:-1}" "$2" "$out/$1" > "$out/ts/$1" ||
    { echo "no match for '$2' in $1:"; cat "$out/$1"; exit 1; }
}

# The reader's project directory. Each step replaces the sources and keeps
# whatever the reader created by hand.
proj=$work/deployctl
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
  rm -f go.sum
  cap "s$k-goget.txt" "go get $*"
  cap "s$k-tidy.txt" 'go mod tidy'
  cmp -s go.mod "$wb/step$k/go.mod" || { echo "go.mod differs from step$k"; exit 1; }
}
# start_api: `go run ./cmd/fakeapi` from the project, as the reader runs it
# in a second terminal. Its request log goes to $work/api.log.
start_api() {
  stop_api
  (cd "$proj" && exec go run ./cmd/fakeapi) 2> "$work/api.log" &
  api_pid=$!
  for _ in $(seq 100); do nc -z 127.0.0.1 8787 2>/dev/null && return; sleep 0.1; done
  echo "fake API did not start"; exit 1
}
apilog() { sleep 0.3; grep -v 'exit status\|signal:' "$work/api.log" > "$out/$1"; }
export DEPLOYCTL_TOKEN=dev-token

echo "== step 1: errors are values"
mkdir -p "$proj" && cd "$proj"
cap s1-modinit.txt 'go mod init deployctl'
cap s1-goget.txt 'go get go@1.27.0'
use_step 1
cap s1-tree.txt "find . -name '*.go' -o -name '*.json' | sort"
cap s1-test.txt 'go vet ./... && go test ./...'
start_api
cap s1-build.txt 'go build ./cmd/deployctl'
capx s1-run.txt './deployctl -config prod.json deploy v1.4.2'
apilog s1-api.txt
capx s1-noconfig.txt './deployctl deploy v1.4.2'
capx s1-badflag.txt './deployctl -config prod.json deploy -parallel=2 v1.4.2'
cap s1-chain.txt 'go run ./lab/chain'
cap s1-notoken.txt 'DEPLOYCTL_TOKEN= ./deployctl -config prod.json deploy v1.4.2'
key s1-notoken.txt '401'
stop_api
cap s1-noapi.txt './deployctl -config prod.json deploy v1.4.2'
key s1-noapi.txt 'connection refused'
rm -f deployctl

broken 1; edit cmd/deployctl/config.go 's/fmt.Errorf\("load config: %w", err\)/fmt.Errorf("load config: %v", err)/'
cap s1-percentv.txt 'go test ./cmd/deployctl'; key s1-percentv.txt 'want one that wraps'
broken 1; edit cmd/deployctl/client.go 's/\tdefer resp.Body.Close\(\)\n//'
cap s1-bodyclose.txt 'golangci-lint run ./...'; key s1-bodyclose.txt 'bodyclose'
broken 1; edit cmd/deployctl/config.go 's/\tif err := json.Unmarshal\(data, &cfg\); err != nil \{\n\t\treturn cfg, fmt.Errorf\("load config %s: %w", path, err\)\n\t\}\n/\tjson.Unmarshal(data, &cfg)\n/'
cap s1-errcheck.txt 'golangci-lint run ./...'; key s1-errcheck.txt 'errcheck'

echo "== step 2: sentinels, types and behaviours"
use_step 2
cap s2-tree.txt "find . -name '*.go' | sort"
cap s2-test.txt 'go vet ./... && go test ./...'
start_api
go build ./cmd/deployctl
capx s2-run.txt './deployctl -config prod.json deploy v1.4.2'
apilog s2-api.txt
capx s2-auth.txt 'DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2'
capx s2-noconfig.txt './deployctl deploy v1.4.2'
cap s2-init.txt './deployctl init && cat deployctl.json'
capx s2-init2.txt './deployctl init'
rm -f deployctl.json
cap s2-chain.txt 'go run ./lab/chain'
cap s2-vet-ptrwrap.txt 'go vet lab/testdata/ptrwrap.go 2>&1 | fold -s -w 80'
cap s2-run-ptrwrap.txt 'go run lab/testdata/ptrwrap.go'
stop_api
rm -f deployctl

broken 2; edit cmd/deployctl/client.go 's/\tapiErr, ok := errors.AsType\[\*APIError\]\(err\)\n/\tvar apiErr *APIError\n\tok := errors.As(err, apiErr)\n/'
cap s2-as.txt 'go vet ./...'; key s2-as.txt 'errors.As'
broken 2; edit cmd/deployctl/config.go 's/case errors.Is\(err, fs.ErrNotExist\):/case err == fs.ErrNotExist:/'
cap s2-equal.txt 'golangci-lint run ./...'; key s2-equal.txt 'errorlint'
broken 2; edit cmd/deployctl/client.go 's/\tapiErr, ok := errors.AsType\[\*APIError\]\(err\)\n/\tapiErr, ok := err.(*APIError)\n/'
cap s2-assert.txt 'golangci-lint run ./...'; key s2-assert.txt 'errorlint'
broken 2; edit cmd/deployctl/client.go 's/\t\treturn apiErr.Temporary\(\), apiErr\n/\t\treturn true, apiErr\n/'
cap s2-retry409.txt 'go test ./cmd/deployctl'; key s2-retry409.txt '409 was retried'
broken 2; edit cmd/deployctl/client.go 's/\/\/ Unwrap makes the last attempt.s error part of the chain.\nfunc \(e \*RetryError\) Unwrap\(\) error \{ return e.Err \}\n//'
cap s2-nounwrap.txt 'go test ./cmd/deployctl'; key s2-nounwrap.txt 'is lost'

echo "== step 3: one error, many failures"
use_step 3
cap s3-tree.txt "find . -name '*.go' | sort"
cap s3-test.txt 'go vet ./... && go test -race ./...'
start_api
go build ./cmd/deployctl
capx s3-run.txt './deployctl -config prod.json deploy v1.4.2'
capx s3-only.txt './deployctl -config prod.json deploy -only us-east-1,us-west-2 v1.4.2'
echo '{"service": "checkout"}' > incomplete.json
cap s3-catincomplete.txt 'cat incomplete.json'
capx s3-incomplete.txt './deployctl -config incomplete.json deploy v1.4.2'
cap s3-chain.txt 'go run ./lab/chain tree'
stop_api
rm -f deployctl incomplete.json

broken 3; edit cmd/deployctl/deploy.go 's/\t\twg.Wait\(\) \/\/ every worker has sent its result...\n\t\tclose\(results\)\n/\t\tclose(results)\n\t\twg.Wait()\n/'
cap s3-closeearly.txt 'go test ./cmd/deployctl'; key s3-closeearly.txt '^panic'
broken 3; edit cmd/deployctl/deploy.go 's/\t\tclose\(results\)\n//'
cap s3-noclose.txt 'go test -timeout 10s ./cmd/deployctl'
# The timeout, then the goroutine that is stuck: rollout, ranging forever.
{ grep -m1 'test timed out' "$out/s3-noclose.txt"
  grep -B1 -m1 'deployctl\.rollout(' "$out/s3-noclose.txt" |
    sed -E 's/rollout\(.*/rollout(...)/'; } > "$out/ts/s3-noclose.txt"
grep -q 'chan receive' "$out/ts/s3-noclose.txt" || { cat "$out/s3-noclose.txt"; exit 1; }
# Workers count the targets they deployed: two of them write one variable.
broken 3; edit cmd/deployctl/deploy.go 's/\tresults := make\(chan result\)\n/\tresults := make(chan result)\n\tdeployed := 0\n/'
edit cmd/deployctl/deploy.go 's/\t\t\t\tresults <- deployOne\(ctx, c, target, service, version\)\n/\t\t\t\tr := deployOne(ctx, c, target, service, version)\n\t\t\t\tif r.Err == nil {\n\t\t\t\t\tdeployed++\n\t\t\t\t}\n\t\t\t\tresults <- r\n/'
edit cmd/deployctl/deploy.go 's/\tif len\(failed\) == 0 \{\n/\tfmt.Fprintf(stdout, "%d deployed\\n", deployed)\n\tif len(failed) == 0 {\n/'
cap s3-race.txt 'go test -race ./cmd/deployctl'
key s3-race.txt 'DATA RACE|^(Read|Previous write) at|deploy.go:' 5

echo "== step 4: an exit-code contract"
use_step 4
cap s4-tree.txt "find . -name '*.go' -o -name '*.yaml' | sort"
rm -f pkg/clierr/testdata/partial.text.golden
cap s4-nogolden.txt 'go test ./pkg/clierr'
cap s4-update.txt 'go test ./pkg/clierr -update'
cap s4-golden.txt 'cat pkg/clierr/testdata/partial.text.golden'
cap s4-test.txt 'go vet ./... && go test ./...'
start_api
go build ./cmd/deployctl
capx s4-badflag.txt './deployctl -config prod.json deploy -parallel=many v1.4.2'
capx s4-help.txt './deployctl -h'
capx s4-noconfig.txt './deployctl deploy v1.4.2'
capx s4-auth.txt 'DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2'
capx s4-partial.txt './deployctl -config prod.json deploy v1.4.2'
set +o pipefail
cap s4-nopipefail.txt './deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo "exit $?"'
set -o pipefail
cap s4-pipefail.txt './deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo "exit $?"'
stop_api
go build -o exitcount ./lab/exitcount
capx s4-exitcount.txt './exitcount'
rm -f exitcount
# The Job is checked by a real API server: the kind cluster from Chapter 20.
if kubectl config view --raw --minify --context kind-watchtower > "$work/kubeconfig" 2>/dev/null; then
  export KUBECONFIG=$work/kubeconfig
  cap s4-job.txt 'kubectl apply --dry-run=server -f job.yaml'
  unset KUBECONFIG
fi
grep -qs 'created (server dry run)' "$out/s4-job.txt" ||
  echo "(the kind cluster was not available for this capture)" > "$out/s4-job.txt"
rm -f deployctl

broken 4; edit cmd/deployctl/main.go 's/\tfs.SetOutput\(io.Discard\)\n//'
go build ./cmd/deployctl
cap s4-twice.txt './deployctl -config prod.json deploy -parallel=many v1.4.2'
key s4-twice.txt 'invalid value' 2
broken 4; edit cmd/deployctl/main.go 's/\tif errors.Is\(err, flag.ErrHelp\) \{\n.*?\n\t\}\n//s'
go build ./cmd/deployctl
cap s4-helpexit.txt './deployctl -h; echo "exit $?"'
key s4-helpexit.txt 'exit'
grep -q usage "$out/s4-helpexit.txt" && { echo "s4-helpexit: usage was printed"; exit 1; }
broken 4; edit pkg/clierr/code.go 's/(\tif e, ok := errors.AsType\[\*Error\]\(err\); ok && e.Code != ExitOK \{\n\t\treturn e.Code\n\t\}\n)(\tif t, ok := errors.AsType\[timeouter\]\(err\); ok && t.Timeout\(\) \{\n\t\treturn ExitTempFail\n\t\}\n)/$2$1/'
cap s4-order.txt 'go test ./pkg/clierr'; key s4-order.txt 'CodeOf\(' 1
broken 4; edit pkg/clierr/program.go 's/\tfor _, d := range r.Details \{\n\t\tfmt.Fprintf\(&b, "  - %s\\n", indent\(d\)\)\n\t\}\n//'
cap s4-details.txt 'go test ./pkg/clierr'; key s4-details.txt 'stderr mismatch|(got|want):$|^ +- ' 5

echo "== step 5: context causes and signals"
use_step 5
cap s5-tree.txt "find . -name '*.go' -o -name '*.json' | sort"
cap s5-test.txt 'go vet ./... && go test ./...'
start_api
go build ./cmd/deployctl
cap s5-catstaging.txt 'cat staging.json'
capx s5-timeout.txt './deployctl -config staging.json deploy -timeout 2s v1.4.2'
capx s5-interrupt.txt './deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -INT $!; wait $!'
capx s5-term.txt './deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -TERM $!; wait $!'
rm -f deployctl

broken 5; edit cmd/deployctl/deploy.go 's/if cause := context.Cause\(ctx\); cause != nil && errors.Is\(err, cause\) \{/if errors.Is(err, context.Canceled) {/'
go build ./cmd/deployctl
cap s5-canceled.txt './deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -INT $!; wait $!'
key s5-canceled.txt '  - ap-south-1'
stop_api
broken 5; edit cmd/deployctl/deploy.go 's/\t\tErr: context.DeadlineExceeded,\n//'
cap s5-nowrap.txt 'go test ./cmd/deployctl'; key s5-nowrap.txt 'CodeOf = |message = ' 2
broken 5; edit cmd/deployctl/deploy.go 's/\tctx, cancel := context.WithTimeoutCause/\tctx, _ = context.WithTimeoutCause/'
edit cmd/deployctl/deploy.go 's/\tdefer cancel\(\)\n//'
cap s5-lostcancel.txt 'go vet ./...'; key s5-lostcancel.txt 'cancel function'
broken 5; edit pkg/clierr/signal.go 's/make\(chan os.Signal, 1\)/make(chan os.Signal)/'
cap s5-unbuffered.txt 'go vet ./...'; key s5-unbuffered.txt 'unbuffered'

echo "== step 6: messages for people, records for operators"
use_step 6
cap s6-tree.txt "find . -name '*.go' | sort"
rm -f pkg/clierr/testdata/partial.json.golden
cap s6-update.txt 'go test ./pkg/clierr -update'
cap s6-golden.txt 'cat pkg/clierr/testdata/partial.json.golden'
cap s6-test.txt 'go vet ./... && go test ./...'
start_api
go build ./cmd/deployctl
cap s6-jsonout.txt './deployctl -config prod.json -o json deploy v1.4.2 2>/dev/null'
cap s6-json.txt './deployctl -config prod.json -o json deploy v1.4.2 2>&1 >/dev/null | jq .error'
./deployctl -config prod.json -log deploy.log deploy v1.4.2 > /dev/null 2>&1 || true
cap s6-logdebug.txt "jq -c 'select(.level == \"DEBUG\") | {msg, method, path, token}' deploy.log | head -n 3"
cap s6-logerror.txt "jq 'select(.level == \"ERROR\") | {msg, exit_code, error_id, chain}' deploy.log"
stop_api
rm -f deployctl deploy.log

broken 6; edit cmd/deployctl/main.go 's/\tp.Cleanup\(closeLog\) \/\/ not defer: Run logs the failure after we return\n/\tdefer closeLog()\n/'
cap s6-defer.txt 'go test ./cmd/deployctl'; key s6-defer.txt 'lacks the failure record'
broken 6; edit pkg/clierr/error.go 's/func \(Secret\) Format\(f fmt.State, _ rune\) +\{ fmt.Fprint\(f, redacted\) \}\n//'
cap s6-leak.txt 'go test ./pkg/clierr'; key s6-leak.txt 'secret leaked'
broken 6; edit cmd/deployctl/client.go 's/\t\t"token", c.Token\) \/\/ logs \[REDACTED\]\n/\t\t"token") \/\/ logs [REDACTED]\n/'
cap s6-slogkv.txt 'go vet ./...'; key s6-slogkv.txt 'missing a final value'

echo "== step 7: panics and crash reports"
use_step 7
deps 7 go.uber.org/goleak@v1.3.0
cap s7-tree.txt "find . -name '*.go' | sort"
cap s7-test.txt 'go vet ./... && go test ./...'
start_api
rm -rf .git
export GIT_AUTHOR_NAME=reader GIT_AUTHOR_EMAIL=reader@example.com
export GIT_COMMITTER_NAME=reader GIT_COMMITTER_EMAIL=reader@example.com
cap s7-git.txt 'git init -q && git add . && git commit -qm "deployctl, step 7"'
cap s7-build.txt 'go build -trimpath ./cmd/deployctl'
rm -f /tmp/deployctl-crash-*.txt /tmp/deployctl-fatal-*.txt
capx s7-panic.txt './deployctl -config staging.json status'
cap s7-crashfile.txt 'head -n 20 $TMPDIR/deployctl-crash-*.txt'
cap s7-nofatal.txt 'ls $TMPDIR/deployctl-fatal-*'
rm -f /tmp/deployctl-crash-*.txt
stop_api
go build -trimpath -o gopanic ./lab/gopanic
capx s7-gopanic.txt './gopanic'
cap s7-httppanic.txt 'go run ./lab/httppanic'
rm -rf gopanic deployctl .git

broken 7; edit pkg/clierr/program.go 's/\t\tif v := recover\(\); v != nil \{\n\t\t\tcode = p.report/\t\tif v := catch(); v != nil {\n\t\t\tcode = p.report/'
printf '\n// catch recovers a panic. Or does it?\nfunc catch() any { return recover() }\n' >> pkg/clierr/program.go
cap s7-catch.txt 'go test ./pkg/clierr'; key s7-catch.txt '^panic'
broken 7; edit pkg/clierr/program.go 's/\tf, err := os.CreateTemp\(p.crashDir\(\), p.Name\+"-crash-\*.txt"\)/\tf, err := os.Create("\/tmp\/" + p.Name + "-crash.txt")/'
cap s7-tmp.txt 'golangci-lint run ./...'; key s7-tmp.txt 'G303'
broken 7; edit pkg/clierr/clierr_test.go 's/\twg.Wait\(\)\n\n\terr := errors.Join/\n\terr := errors.Join/'
cap s7-nowait.txt 'go test ./pkg/clierr'
key s7-nowait.txt 'found unexpected goroutines|want a \*PanicError|DATA RACE' 2

echo "== step 8: testing error paths"
use_step 8
cap s8-tree.txt "find . -name '*.go' -o -name '*.golden' | sort"
cap s8-test.txt 'go vet ./... && go test -race ./...'
cap s8-exitcodes.txt "go test -count=1 -v -run TestExitCodes ./cmd/deployctl 2>&1 | grep -E '^(--- |    --- |ok)'"
cap s8-catgolden.txt 'cat cmd/deployctl/testdata/partial.golden'
# What we're building: the finished tool against the fake API.
start_api
go build ./cmd/deployctl
cap s8-tour.txt './deployctl -config prod.json deploy v1.4.2; echo "exit status $?"'
cap s8-tour-auth.txt 'DEPLOYCTL_TOKEN=expired ./deployctl -config prod.json deploy v1.4.2; echo "exit status $?"'
stop_api
rm -f deployctl

broken 8; edit cmd/deployctl/config.go 's/fmt.Sprintf\("config file %s not found", path\)/fmt.Sprintf("no config file at %s", path)/'
cap s8-golden.txt 'go test ./cmd/deployctl'; key s8-golden.txt 'differs from|^ +deployctl: ' 3
cap s8-update.txt 'go test ./cmd/deployctl -update'
broken 8; edit cmd/deployctl/main_test.go 's/\tif exitErr, ok := errors.AsType\[\*exec.ExitError\]\(err\); ok \{/\tif exitErr, ok := err.(*exec.ExitError); ok {/'
cap s8-assert.txt 'golangci-lint run ./...'; key s8-assert.txt 'errorlint'
broken 8; edit pkg/clierr/program.go 's/\tctx, stop := notifyContext\(context.Background\(\), p.stderr\(\)\)\n/\tctx, stop := context.Background(), func() {}\n/'
cap s8-nosignal.txt 'go test -run TestInterruptExits130 ./cmd/deployctl'
key s8-nosignal.txt 'want exit status 130'

echo "captured into $out"
