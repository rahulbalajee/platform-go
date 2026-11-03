#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 2 (book/output/ch02): the
# checkpoints of the eight build steps and the lab, the troubleshooting
# tables (each made by breaking a copy of a snapshot), and the outputs the
# exercise solutions quote.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch02.sh "$TMPDIR/c2.sh" && bash "$TMPDIR/c2.sh"
#
# No network access is needed if golang.org/x/time v0.16.0 and
# golang.org/x/exp@v0.0.0-20261014143641-f0251eb4aa3e (apidiff) are in the
# module cache. About two minutes.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK
root=$(pwd)
out=$root/book/output/ch02
wb=$root/workbook/ch02
rm -rf "$out"; mkdir -p "$out/ts"
work=$(mktemp -d "${TMPDIR:-/tmp}/ch02.XXXXXX")
work=${work//\/\//\/} # macOS TMPDIR ends in a slash; Go prints clean paths
trap 'rm -rf "$work"' EXIT
export GOBIN=$work/bin PATH=$work/bin:$PATH # where the lab installs apidiff
# A private temporary directory, so golangci-lint's lock file is not shared
# with lint runs elsewhere on the machine.
mkdir -p "$work/tmp"; export TMPDIR=$work/tmp
apidiff_version=v0.0.0-20261014143641-f0251eb4aa3e

goroot=$(go env GOROOT)
# Absolute paths and addresses change on every run; nothing else is edited.
# Tabs are expanded the way a terminal shows them.
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
# PATTERN, quoted in the troubleshooting tables. UUIDs are shortened to
# their first eight digits so the quote fits a table cell.
key() {
  grep -E -m "${3:-1}" "$2" "$out/$1" |
    sed -E 's/([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/\1…/g' \
      > "$out/ts/$1" || true
  [[ -s $out/ts/$1 ]] || { echo "no match for '$2' in $1"; exit 1; }
}
# after FILE PATTERN N: the first line matching PATTERN and the N after it.
after() {
  grep -E -m 1 -A "$3" "$2" "$out/$1" > "$out/ts/$1" ||
    { echo "no match for '$2' in $1"; exit 1; }
}

# The reader's working directory. Each step replaces the source files.
proj=$work/platformapi
use_step() {
  mkdir -p "$proj"
  find "$proj" -name '*.go' -delete
  rm -f "$proj/go.mod" "$proj/go.sum"
  (cd "$wb/step$1" && tar cf - .) | (cd "$proj" && tar xf -)
  cd "$proj"
  go clean -testcache
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
lint='golangci-lint run ./...'

echo "== step 1: types and a first call"
mkdir -p "$proj" && cd "$proj"
cap s1-modinit.txt 'go mod init platformapi'
cap s1-goget.txt 'go get go@1.27.0'
use_step 1
cap s1-tree.txt "find . -name '*.go' | sort"
cap s1-test.txt 'go vet ./... && go test ./...'
cap s1-testv.txt "go test -v -run 'TestGet|TestMissing' ."
cap s1-doc.txt 'go doc .'

broken 1; edit api.go 's/c.getJSON\(ctx, &env, /c.getJSON(ctx, env, /'
cap s1-nonpointer.txt 'go test ./...'; key s1-nonpointer.txt 'staging: decoding'
broken 1; edit types.go 's/json:"updated_replicas"/json:"updatedReplicas"/'
cap s1-tag.txt 'go test ./...'; key s1-tag.txt 'FAIL: TestGetDeployment|GetDeployment\(d-2\) =' 2
broken 1; edit client_test.go 's/httptest.NewServer\(fake\)/httptest.NewServer(*fake)/'
cap s1-handler.txt 'go vet ./...'; key s1-handler.txt 'does not implement'
broken 1; edit go.mod 's/^module platformapi$/module github.com\/you\/platformapi/m'
cap s1-modpath.txt 'go vet ./...'; key s1-modpath.txt 'is not in std'
broken 1; edit transport.go 's/\tdefer drain\(resp\)\n//'
cap s1-bodyclose.txt "$lint"; key s1-bodyclose.txt 'bodyclose'

echo "== step 2: options"
use_step 2
deps 2 golang.org/x/time@v0.16.0
cap s2-tree.txt "find . -name '*.go' | sort"
cap s2-test.txt 'go vet ./... && go test ./...'
cap s2-every.txt "go test -v -run TestNewReportsEveryProblem . | fold -s -w 86"
cap s2-doc.txt 'go doc . Option'

broken 2; edit options_test.go 's/sealed := platformapi.TokenSourceFunc\(func\(context.Context\) \(string, error\) \{\n(.*?)\n\t\}\)/sealed := func(context.Context) (string, error) {\n$1\n\t}/s'
cap s2-funcvalue.txt 'go vet ./...'; key s2-funcvalue.txt 'does not implement'
broken 2; edit options_test.go 's/func \(l \*countingLimiter\) Wait\(context.Context\) error/func (l *countingLimiter) Wait() error/'
cap s2-signature.txt 'go vet ./...'; key s2-signature.txt 'does not implement|have Wait|want Wait' 3
broken 2; edit options_test.go 's/lim := &countingLimiter\{\}/lim := countingLimiter{}/'
cap s2-ptrrecv.txt 'go vet ./...'; key s2-ptrrecv.txt 'does not implement'
broken 2; cat > reconfigure_test.go <<'EOF'
package platformapi_test

import (
	"testing"

	"platformapi"
)

// TestReconfigure tries to change a client after New returned it.
func TestReconfigure(t *testing.T) {
	client, _ := newClient(t)
	_ = platformapi.WithToken("other-token")(client)
}
EOF
cap s2-reconfigure.txt 'go vet ./...'; key s2-reconfigure.txt 'cannot use client'

echo "== step 3: typed errors"
use_step 3
cap s3-tree.txt "find . -name '*.go' | sort"
cap s3-test.txt 'go vet ./... && go test ./...'
cap s3-log.txt "go test -v -run TestNotFoundIsAnAPIError . | fold -s -w 86"

broken 3; edit errors_test.go 's/\tif !errors.Is\(err, platformapi.ErrNotFound\) \{\n\t\tt.Fatalf\("err = %v, want ErrNotFound", err\)\n\t\}\n\tif errors.Is\(err, platformapi.ErrConflict\)/\tif err != platformapi.ErrNotFound {\n\t\tt.Fatalf("err = %v, want ErrNotFound", err)\n\t}\n\tif errors.Is(err, platformapi.ErrConflict)/'
cap s3-equal.txt "$lint"; key s3-equal.txt 'errorlint'
broken 3; edit transport.go 's/\tesc := make\(\[\]string, len\(path\)\)\n\tfor i, s := range path \{\n\t\tesc\[i\] = url.PathEscape\(s\)\n\t\}\n//; s/\tu.RawPath = c.base.EscapedPath\(\) \+ "\/v1\/" \+ strings.Join\(esc, "\/"\)\n//'
cap s3-escape.txt 'go test ./...'; key s3-escape.txt 'want ErrNotFound'
broken 3; edit errors.go 's/\n\/\/ Is makes errors.Is.*?\n\}\n//s; s/\t"net\/http"\n//'
cap s3-nois.txt 'go test ./...'; key s3-nois.txt 'want ErrNotFound'
broken 3; edit errors_test.go 's/apiErr, ok := errors.AsType\[\*platformapi.APIError\]\(err\)/apiErr, ok := errors.AsType[platformapi.APIError](err)/'
cap s3-astype.txt 'go vet ./...'; key s3-astype.txt 'does not satisfy'

echo "== step 4: calls"
use_step 4
cap s4-tree.txt "find . -name '*.go' | sort"
cap s4-test.txt 'go vet ./... && go test ./...'
cap s4-testv.txt "go test -v -run 'TestEveryCall|TestIdempotency|TestCancelled' ."

broken 4; edit go.mod 's/^go 1.27.0$/go 1.26.0/m'
cap s4-golang.txt 'go build ./...'; key s4-golang.txt 'requires go1.27'
broken 4; edit api.go 's/return c.call\[\*Environment\]\(ctx, /return c.call(ctx, /'
cap s4-infer.txt 'go build ./...'; key s4-infer.txt 'cannot infer'
broken 4; edit calls_test.go 's/platformapi.RequestID\("ci-run-77"\)/platformapi.WithUserAgent("ci-run-77")/'
cap s4-mixed.txt 'go vet ./...'; key s4-mixed.txt 'cannot use'
broken 4; edit transport.go 's/http.NewRequestWithContext\(ctx, r.method/http.NewRequestWithContext(context.Background(), r.method/'
cap s4-background.txt 'go test ./...'; key s4-background.txt 'calls_test.go:[0-9]+:' 2

echo "== step 5: pagination"
use_step 5
cap s5-tree.txt "find . -name '*.go' | sort"
cap s5-test.txt 'go vet ./... && go test ./...'
cap s5-doc.txt 'go doc . Client.ListDeployments'

broken 5; edit list.go 's/\t\t\t\tif !yield\(item, nil\) \{\n\t\t\t\t\treturn \/\/ the consumer broke out of the loop\n\t\t\t\t\}\n/\t\t\t\tyield(item, nil)\n/'
cap s5-yield.txt 'go test ./...'; key s5-yield.txt '^panic'
broken 5; edit list.go 's/\t\tif r.query == nil \{\n\t\t\tr.query = url.Values\{\}\n\t\t\}\n//'
cap s5-nilmap.txt 'go test ./...'; key s5-nilmap.txt '^panic'
broken 5; edit list_test.go 's/\tfor d, err := range client.ListDeployments\(t.Context\(\),\n\t\tplatformapi.DeploymentFilter\{\}, platformapi.PageSize\(3\)\) \{\n\t\tif err != nil \{\n\t\t\tt.Fatal\(err\)\n\t\t\}\n\t\tif seen/\tfor d := range client.ListDeployments(t.Context(),\n\t\tplatformapi.DeploymentFilter{}, platformapi.PageSize(3)) {\n\t\tif seen/'
cap s5-errcheck.txt "$lint"; key s5-errcheck.txt 'errcheck'

echo "== step 6: operations"
use_step 6
cap s6-tree.txt "find . -name '*.go' | sort"
cap s6-test.txt 'go vet ./... && go test ./...'
cap s6-synctest.txt "go test -v -run 'TestWait|TestCancelling' . 2>&1 | grep -E '^(=== RUN|--- |ok)'"

broken 6; cat > examples/promote/waiter.go <<'EOF'
package promote

import (
	"context"

	"platformapi"
)

// waiter lists the SDK's own Wait method, instantiated for deployments.
type waiter interface {
	Wait(ctx context.Context, op *platformapi.Operation[platformapi.Deployment],
		opts ...platformapi.CallOption) (*platformapi.Deployment, error)
}

var _ waiter = (*platformapi.Client)(nil)
EOF
cap s6-generic.txt 'go build ./examples/promote'
key s6-generic.txt 'does not implement|have Wait|want Wait' 3
cap s6-generic-page.txt 'go build ./examples/promote 2>&1 | fold -s -w 86'
broken 6; edit examples/promote/promote_test.go 's/Promote\(t.Context\(\), Client\{Client: client\},\n/Promote(t.Context(), client,\n/'
cap s6-adapter.txt 'go vet ./...'; key s6-adapter.txt 'does not implement'
broken 6; edit operation.go 's/\t\tcase cur.Done && cur.Error != nil:\n\t\t\treturn cur.Result, cur.Error \/\/ not a nil \*OperationError in an error\n\t\tcase cur.Done:\n\t\t\treturn cur.Result, nil\n/\t\tcase cur.Done:\n\t\t\treturn cur.Result, cur.Error\n/'
cap s6-typednil.txt 'go test ./...'; key s6-typednil.txt 'FAIL: TestWaitFollows|test.go:[0-9]+: <nil>$' 2
broken 6; edit client_test.go 's/\tsrv := httptest.NewTestServer\(t, fake\) \/\/ closed when the test ends\n/\tsrv := httptest.NewServer(fake)\n\tt.Cleanup(srv.Close)\n/'
cap s6-realnet.txt 'go test -timeout 10s -run TestWaitFollowsRolloutToSuccess .'
key s6-realnet.txt 'test timed out|^ +TestWaitFollowsRolloutToSuccess' 2

echo "== step 7: retries"
use_step 7
cap s7-tree.txt "find . -name '*.go' | sort"
cap s7-test.txt 'go vet ./... && go test ./...'
cap s7-synctest.txt "go test -v -run 'TestRetries|TestRetryAfter|TestLimiterGates' . 2>&1 | grep -E '^(=== RUN|--- |ok)'"

broken 7; edit api.go 's/r.body, r.needsKey, r.idempotent = req, true, true/r.body, r.needsKey = req, true/'
cap s7-notidem.txt 'go test ./...'; key s7-notidem.txt 'retry_test.go:[0-9]+: POST'
broken 7; edit transport.go 's/\tif r.needsKey \{\n\t\tr.call.idempotencyKey = cmp.Or\(r.call.idempotencyKey, uuid.New\(\).String\(\)\)\n\t\}\n//'
edit transport.go 's/\tif r.call.idempotencyKey != "" \{\n\t\treq.Header.Set\("Idempotency-Key", r.call.idempotencyKey\)\n\t\}\n/\tif r.needsKey { \/\/ a fresh key for every attempt\n\t\tkey := cmp.Or(r.call.idempotencyKey, uuid.New().String())\n\t\treq.Header.Set("Idempotency-Key", key)\n\t}\n/'
cap s7-keyperattempt.txt 'go test ./...'; key s7-keyperattempt.txt 'attempt sent key'
broken 7; edit transport.go 's/\tdefault: \/\/ other 4xx and 5xx will not fix themselves\n\t\treturn nil, retry.Permanent\(apiErr\)/\tdefault:\n\t\treturn nil, apiErr/'
cap s7-all.txt 'go test ./...'; key s7-all.txt 'not retryable'
broken 7; edit retry_test.go 's/client, fake := newClient\(t, platformapi.WithTokenSource\(tokens\)\)/client, fake := newClient(t,\n\t\tplatformapi.WithTokenSource(platformapi.TokenSourceFunc(tokens.Token)))/'
cap s7-wrapper.txt 'go test ./...'; key s7-wrapper.txt 'after rotation'

echo "== step 8: documentation, examples and a tour"
use_step 8
cap s8-tree.txt "find . -name '*.go' | sort"
cap s8-test.txt 'go vet ./... && go test ./...'
cap s8-godoc.txt 'go doc .'
cap s8-example.txt 'go doc . ExampleAPIError'
cap s8-fake.txt 'go doc ./platformapifake Server'
for s in pages deploy flaky errors; do cap "s8-tour-$s.txt" "go run ./examples/tour $s"; done
cap s8-usage.txt 'go run ./examples/tour'
key s8-usage.txt 'usage'

broken 8; edit example_test.go 's/\/\/ Output: d-9 checkout v1.5.0 succeeded/\/\/ Output: d-9 checkout v1.5.0 deployed/'
cap s8-output.txt 'go test ./...'; after s8-output.txt '^--- FAIL: Example ' 4
broken 8; edit example_test.go 's/func ExampleClient_ListDeployments\(\)/func ExampleClient_Deployments()/'
cap s8-exname.txt 'go vet ./...'; key s8-exname.txt 'refers to unknown'

echo "== lab: evolving the API"
use_step 9
cap s9-tree.txt "find ./evolve -name '*.go' | sort"
cap s9-install.txt "go install golang.org/x/exp/cmd/apidiff@$apidiff_version"
cap s9-apidiff.txt 'apidiff ./evolve/before ./evolve/after | fold -s -w 86'
cap s9-write.txt 'apidiff -w platformapi-v1.api .'
cap s9-same.txt 'apidiff platformapi-v1.api .'
cap s9-test.txt 'go test -race ./...'
cap s9-noversion.txt 'go install golang.org/x/exp/cmd/apidiff'
key s9-noversion.txt 'no required module|go get' 2
(cd "$work" && cap s9-outside.txt 'apidiff ./evolve/before ./evolve/after')
key s9-outside.txt '.' 2

echo "== exercise answers"
# 2.1: a map from sentinel to status looks neater than a switch, and
# panics when errors.Is is given an error of an unhashable type.
rm -rf "$work/ex1"; cp -R "$root/solutions/ch02/ex1" "$work/ex1"; cd "$work/ex1"
edit errors.go 's/\tswitch target \{\n.*?\n\t\}\n\treturn false\n/\tcode, ok := sentinels[target]\n\treturn ok && e.StatusCode == code\n/s'
cat >> errors.go <<'EOF'

var sentinels = map[error]int{
	ErrNotFound:     http.StatusNotFound,
	ErrConflict:     http.StatusConflict,
	ErrUnauthorized: http.StatusUnauthorized,
	ErrRateLimited:  http.StatusTooManyRequests,
}
EOF
cat > unhashable_test.go <<'EOF'
package platformapi_test

import (
	"errors"
	"testing"

	"platformapi"
)

// multiError is a perfectly good error whose type cannot be a map key.
type multiError []error

func (m multiError) Error() string { return errors.Join(m...).Error() }

func TestIsWithUnhashableTarget(t *testing.T) {
	client, _ := newClient(t)
	_, err := client.GetDeployment(t.Context(), "d-404")
	_ = errors.Is(err, multiError{platformapi.ErrNotFound})
}
EOF
cap ex1-unhashable.txt 'go test -run TestIsWithUnhashableTarget .'
key ex1-unhashable.txt '^panic: runtime|\(\*APIError\)\.Is' 2

# 2.3: seven proposed changes to the finished SDK, judged by apidiff.
rm -rf "$work/ex3"; cp -R "$wb/step9" "$work/ex3"; cd "$work/ex3"
apidiff -w ../v1.api .
edit types.go 's/(\tCreatedAt time.Time `json:"created_at"`\n\}\n\n\/\/ Service)/\tCreatedAt time.Time         `json:"created_at"`\n\tLabels    map[string]string `json:"labels,omitempty"`\n}\n\n\/\/ Service/'
edit types.go 's/StateCancelled  DeploymentState = "cancelled"/StateCancelled  DeploymentState = "canceled"/'
edit transport.go 's/func PageSize\(n int\) CallOption \{/func PageSize(n int32) CallOption {/'
edit transport.go 's/return func\(c \*callConfig\) \{ c.pageSize = n \}/return func(c *callConfig) { c.pageSize = int(n) }/'
edit client.go 's/\tWait\(ctx context.Context\) error\n\}/\tWait(ctx context.Context) error\n\t\/\/ Tokens reports how many requests may be sent right now.\n\tTokens() float64\n}/'
edit token.go 's/(\/\/ StaticToken returns)/\/\/ String describes the source without revealing the token.\nfunc (f TokenSourceFunc) String() string { return "TokenSourceFunc" }\n\n$1/'
edit api.go 's/(\/\/ START logs OMIT)/\/\/ GetOperation returns the current state of operation id.\nfunc (c *Client) GetOperation(ctx context.Context, id string,\n\topts ...CallOption) (*Operation[Deployment], error) {\n\n\tr := newRequest("GET", opts, "operations", id)\n\treturn c.call[*Operation[Deployment]](ctx, r)\n}\n\n$1/'
edit operation.go 's/(\tResult  \*T              `json:"result"` \/\/ latest state of the resource\n)/$1\tLabels  map[string]string `json:"labels,omitempty"`\n/'
go build ./... || { echo "ex3 edits do not compile"; exit 1; }
cap ex3-apidiff.txt 'apidiff ../v1.api .'

echo "captured into $out"
