#!/usr/bin/env bash
# Regenerates the real terminal output shown in Chapter 3.
# Usage: book/scripts/capture-ch03.sh   (from the repository root)
#
# Most commands here fail on purpose. Each capture is the combined stdout
# and stderr of one command, exactly as a terminal shows it, plus a .code
# file with its exit status.
set -uo pipefail
root=$(pwd)
out=$root/book/output/ch03
mkdir -p "$out"
# Shorten long hex addresses in stack traces so they fit the page.
scrub() { sed -E -e 's#0x[0-9a-f]{9,}#0x…#g' -e 's#0x[0-9a-f]{9,}\?#0x…?#g'; }

work=$(mktemp -d)
bin=$work/bin
mkdir -p "$bin"
trap 'kill "${api:-}" 2>/dev/null; rm -rf "$work"' EXIT

# Release-style builds: -trimpath keeps build-machine paths out of stacks.
go build -trimpath -o "$bin/deployctl" ./examples/ch03/deployctl
go build -trimpath -o "$bin/fakeapi" ./examples/ch03/fakeapi/cmd/fakeapi

# --- Error chains, panics, net/http ------------------------------------------
go run ./examples/ch03/chain wrap > "$out/chain-wrap.txt" 2>&1
go run ./examples/ch03/chain tree > "$out/chain-tree.txt" 2>&1
go build -trimpath -o gopanic ./examples/ch03/gopanic
./gopanic > "$out/gopanic.txt" 2>&1; echo $? > "$out/gopanic.code"
go build -trimpath -o exitcount ./examples/ch03/exitcount
./exitcount > "$out/exitcount.txt" 2>&1; echo $? > "$out/exitcount.code"
rm -f gopanic exitcount
go run examples/ch03/testdata/ptrwrap.go > "$out/run-ptrwrap.txt" 2>&1
go run ./examples/ch03/httppanic > "$out/httppanic.txt" 2>&1
go vet examples/ch03/testdata/ptrwrap.go 2>&1 | fold -s -w 80 > "$out/vet-ptrwrap.txt"

# --- deployctl against the fake API -------------------------------------------
"$bin/fakeapi" -addr 127.0.0.1:8787 2> "$work/fakeapi.log" &
api=$!
for _ in $(seq 50); do curl -s -o /dev/null 127.0.0.1:8787 && break; sleep 0.1; done

cp examples/ch03/deployctl/testdata/prod.json examples/ch03/deployctl/testdata/staging.json \
  "$work/"
cd "$work"
export PATH="$bin:$PATH" DEPLOYCTL_TOKEN=dev-token TMPDIR=/tmp
rm -f /tmp/deployctl-crash-*.txt

# cap NAME COMMAND: run COMMAND in bash, save its output and exit status.
cap() {
  bash -c "$2" > "$out/$1.txt" 2>&1
  echo $? > "$out/$1.code"
}

cap badflag  'deployctl -config prod.json deploy -parallel=many v1.4.2'
cap noconfig 'deployctl deploy v1.4.2'
cap auth     'DEPLOYCTL_TOKEN=expired deployctl -config prod.json deploy v1.4.2'
cap partial  'deployctl -config prod.json deploy v1.4.2'
cap timeout  'deployctl -config staging.json deploy -timeout 2s v1.4.2'
cap panic    'deployctl -config staging.json status'
head -n 20 /tmp/deployctl-crash-*.txt | scrub > "$out/crashfile.txt"
cap interrupt 'deployctl -config staging.json deploy v1.4.2 & sleep 1; kill -INT $!; wait $!'

# JSON errors on stderr, and what a pipeline does to the exit status.
cap json 'deployctl -config prod.json -o json deploy v1.4.2 2>&1 >/dev/null | jq .error'
set +o pipefail
{ deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo "exit $?"
} > "$out/pipe-nopipefail.txt"
set -o pipefail
{ deployctl -config prod.json deploy v1.4.2 2>/dev/null | grep -c deployed; echo "exit $?"
} > "$out/pipe-pipefail.txt"

# The operator log: debug records with a redacted token, then the failure.
deployctl -config prod.json -log deploy.log deploy v1.4.2 > /dev/null 2>&1
jq -c 'select(.level == "DEBUG") | {msg, method, path, token}' deploy.log | head -n 3 \
  > "$out/log-debug.txt"
jq 'select(.level == "ERROR") | {msg, exit_code, error_id, chain}' deploy.log \
  > "$out/log-error.txt"

# Kubernetes validates the Job that maps exit codes to retry decisions.
cd "$root"
kubectl --context kind-watchtower apply --dry-run=server \
  -f examples/ch03/deployctl/job.yaml > "$out/job-dryrun.txt" 2>&1 \
  || echo "(kind cluster not available)" > "$out/job-dryrun.txt"

# --- Tests ------------------------------------------------------------------------
go test -count=1 -v -run 'TestExitCodes' ./examples/ch03/deployctl 2>&1 \
  | grep -E '^(=== RUN|--- |    --- |ok|PASS|FAIL)' | grep -v '=== RUN' > "$out/exitcodes-run.txt"
go test -race -count=1 ./pkg/clierr ./examples/ch03/... 2>&1 \
  | grep -v 'no test files' | sed -e "s#${root}/##g" > "$out/test-ch03.txt"
echo "captured into $out"
