#!/usr/bin/env bash
# Regenerates every terminal block in Chapter 20 (book/output/ch20): the
# scaffold, the checkpoints of all eight build steps, the troubleshooting
# tables (each made by breaking a copy of a snapshot), and the end-to-end run
# on kind, with and without the cadence gate.
#
# Usage, from the repository root (bash reads a script while it runs it, so
# run a copy if you might edit this file meanwhile):
#   cp book/scripts/capture-ch20.sh "$TMPDIR/c20.sh" && bash "$TMPDIR/c20.sh"
#   STEPS="3 4" bash "$TMPDIR/c20.sh"   # only some steps (keeps other files)
#
# Needs kubebuilder 4.16, Docker, kind, kubectl, golangci-lint v2.15, and
# network access (Go modules, envtest binaries, the PrometheusRule CRD from
# GitHub, and go.dev as a probe target). Uses (and resets) the kind cluster
# `watchtower`. About fifteen minutes.
set -euo pipefail
unset GOFLAGS GOPROXY GOMODCACHE GONOSUMDB GOTOOLCHAIN GOWORK KUBEBUILDER_ASSETS
root=$(pwd)
out=$root/book/output/ch20
wb=$root/workbook/ch20
STEPS=${STEPS:-1 2 3 4 5 6 7 8}
if [[ $STEPS == "1 2 3 4 5 6 7 8" ]]; then rm -rf "$out"; fi
mkdir -p "$out/ts" "$out/e2e"
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ch20.XXXXXX")" && pwd -P)
run_pid=
stop_run() {
  if [[ -n $run_pid ]]; then
    pkill -P "$run_pid" 2>/dev/null || true
    kill "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
    run_pid=
  fi
}
# The module cache under $work is read-only; make it writable before removing.
trap 'stop_run; chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
kubectl config use-context kind-watchtower >/dev/null

# The reader's lab layout from Chapter 1: $LAB/platform-go is a clone of the
# book's repository, which holds the shared lint configuration.
export LAB=$work/lab
mkdir -p "$LAB"; ln -s "$root" "$LAB/platform-go"
lint='golangci-lint run --config "$LAB/platform-go/.golangci.yml" ./...'

goroot=$(go env GOROOT)
# Absolute paths change on every run; nothing else is edited. Tabs are
# expanded the way a terminal shows them.
scrub() {
  sed -E -e "s#${work}/#~/#g" -e "s#${goroot}#\$GOROOT#g" -e "s#${HOME}#~#g" |
    expand -t 8
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

# The reader's project. Each step replaces every file except bin/, where
# the Makefile keeps its tools and the envtest binaries.
proj=$work/watchtower
use_step() {
  if [[ ! -d $proj/bin ]]; then
    mkdir -p "$proj/bin"
    cp -R "$root/projects/watchtower/bin/k8s" "$proj/bin/"
  fi
  rsync -a --delete --exclude /bin "$wb/step$1/" "$proj/"
  cd "$proj"
}
# broken STEP: a scratch copy of a snapshot that shares the project's bin/.
broken() {
  rm -rf "$work/broken"; mkdir -p "$work/broken"
  rsync -a --exclude /bin "$wb/step$1/" "$work/broken/"
  ln -s "$proj/bin" "$work/broken/bin"
  cd "$work/broken"
}
# edit FILE PERL: apply a perl substitution and insist that it changed FILE.
edit() {
  local before; before=$(cksum < "$1")
  perl -0pi -e "$2" "$1"
  [[ $(cksum < "$1") != "$before" ]] || { echo "edit did not apply to $1: $2"; exit 1; }
}
# same_as STEP: the files the reader produced equal the snapshot.
same_as() {
  diff -r -x bin -x cover.out "$wb/step$1" . ||
    { echo "the replayed project differs from step$1"; exit 1; }
}
gotest='go test ./...'

step1() {
  echo "== step 1: scaffold"
  # A clean slate in the cluster: no operator, no CRD, no demo.
  kubectl delete namespace watchtower-system shop --ignore-not-found --wait=true >/dev/null
  kubectl delete crd healthchecks.watchtower.platformgo.dev --ignore-not-found >/dev/null

  rm -rf "$proj"; mkdir -p "$proj"; cd "$proj"
  cap s1-version.txt 'kubebuilder version'
  cap s1-modinit.txt 'go mod init watchtower'
  cap s1-init.txt 'kubebuilder init --domain platformgo.dev --license none'
  cap s1-api.txt 'kubebuilder create api --group watchtower --version v1alpha1 --kind HealthCheck --resource --controller'
  cap s1-scaffold.txt "find . -type f -not -path './bin/*' | sort"
  cap s1-goget.txt 'go get go@1.27.0'
  cap s1-rm.txt 'rm -r .devcontainer .github test internal/controller/*_test.go'
  # The reader now writes the files this step prints.
  for f in cmd/main.go api/v1alpha1/healthcheck_types.go \
    internal/controller/healthcheck_controller.go \
    internal/controller/suite_test.go internal/controller/healthcheck_controller_test.go \
    config/samples/watchtower_v1alpha1_healthcheck.yaml; do
    cp "$wb/step1/$f" "$f"
  done
  cap s1-tidy.txt 'go mod tidy'
  cap s1-make.txt 'make manifests generate'
  same_as 1
  cp -R "$root/projects/watchtower/bin/k8s" bin/
  cap s1-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s1-envtest.txt 'make setup-envtest'
  cap s1-test.txt "go vet ./... && $gotest"
  cap s1-testv.txt 'go test -v ./internal/controller/'
  cap s1-lint.txt "$lint"

  # The development loop against a real cluster: CRD in, operator on the host.
  cap s1-install.txt 'make install'
  (exec go run ./cmd) > "$work/run.log" 2>&1 &
  run_pid=$!
  for _ in $(seq 120); do grep -q 'Starting workers' "$work/run.log" && break; sleep 0.5; done
  cap s1-apply.txt 'kubectl apply -f config/samples/watchtower_v1alpha1_healthcheck.yaml'
  sleep 2
  cap s1-get.txt 'kubectl get healthchecks'
  kubectl delete -f config/samples/watchtower_v1alpha1_healthcheck.yaml >/dev/null || true
  sleep 1
  stop_run
  grep -E 'Starting workers|Reconciling' "$work/run.log" | scrub > "$out/s1-run.txt"
  cap s1-uninstall.txt 'make uninstall'

  broken 1; edit go.mod 's/^module watchtower$/module github.com\/you\/watchtower/m'
  cap s1-modpath.txt 'go build ./...'; key s1-modpath.txt 'is not in std'
  broken 1; rm bin
  cap s1-noenvtest.txt 'go test -v ./internal/controller/'
  key s1-noenvtest.txt 'envtest (binaries )?not' 2
  broken 1
  cap s1-scaffoldlint.txt 'golangci-lint run ./...'; key s1-scaffoldlint.txt 'plugin'
  broken 1; edit internal/controller/suite_test.go 's/client.Options\{Scheme: scheme\}/client.Options{}/'
  cap s1-scheme.txt 'go test ./internal/controller/'; key s1-scheme.txt 'no kind is registered'
  broken 1; rm -r config/crd/bases
  cap s1-nocrd.txt 'go test ./internal/controller/'; key s1-nocrd.txt 'starting envtest'
}

step2() {
  echo "== step 2: the API"
  use_step 2
  cap s2-make.txt 'make manifests generate'
  cap s2-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s2-cel.txt "grep -B1 -A2 'rule:' config/crd/bases/watchtower.platformgo.dev_healthchecks.yaml"
  cap s2-test.txt "go vet ./... && $gotest"
  cap s2-testv.txt "go test -v -run 'CRD' ./internal/controller/ | grep -v '^=== RUN'"
  cap s2-lint.txt "$lint"

  broken 2; cp "$wb/step1/config/crd/bases/"*.yaml config/crd/bases/
  cap s2-stale.txt 'go test ./internal/controller/'; key s2-stale.txt 'want Invalid'
  broken 2; edit api/v1alpha1/healthcheck_types.go 's/has\(self.url\) != has\(self.service\)/has(self.uri) != has(self.service)/'
  make manifests >/dev/null 2>&1
  cap s2-celtypo.txt 'go test ./internal/controller/'; key s2-celtypo.txt 'undefined field'
  broken 2; edit api/v1alpha1/healthcheck_types.go 's/\/\/ \+kubebuilder:object:root=true\n\n(\/\/ HealthCheckList contains)/$1/'
  make generate >/dev/null 2>&1
  cap s2-noroot.txt 'go build ./...'; key s2-noroot.txt 'DeepCopyObject'
  broken 2; edit api/v1alpha1/healthcheck_types.go 's/`json:"failureThreshold,omitempty"`/`json:"failureThreshold,omitempty`/'
  cap s2-tag.txt 'go vet ./api/...'; key s2-tag.txt 'struct field tag'
}

step3() {
  echo "== step 3: probe and report"
  use_step 3
  cap s3-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s3-make.txt 'make manifests generate'
  cap s3-test.txt "go vet ./... && $gotest"
  cap s3-testv.txt "go test -v -run 'ApplyProbe|Saturated|Lifecycle' ./internal/controller/ | grep -v '^=== RUN'"
  cap s3-lint.txt "$lint"

  broken 3; edit internal/controller/healthcheck_controller.go 's/r.Status\(\).Patch\(ctx, &hc, client.MergeFromWithOptions\(base, lock\)\)/r.Patch(ctx, \&hc, client.MergeFromWithOptions(base, lock))/'
  cap s3-nostatus.txt 'go test ./internal/controller/'; key s3-nostatus.txt 'condition not met'
  broken 3; edit internal/controller/status.go 's/case st.ConsecutiveFailures >= threshold:/case st.ConsecutiveFailures > threshold:/'
  cap s3-threshold.txt 'go test ./internal/controller/'; key s3-threshold.txt 'step [0-9]+:'
  broken 3; edit internal/probe/probe.go 's/\tdefer resp.Body.Close\(\)\n//'
  cap s3-bodyclose.txt "$lint"; key s3-bodyclose.txt 'bodyclose'
  broken 3; edit internal/probe/probe.go 's/\tctx, cancel := context.WithTimeout\(ctx, s.Timeout\)\n\tdefer cancel\(\)\n/\tctx, _ = context.WithTimeout(ctx, s.Timeout)\n/'
  cap s3-cancel.txt 'go vet ./internal/probe/'; key s3-cancel.txt 'cancel'
}

step4() {
  echo "== step 4: metrics and Events"
  use_step 4
  cap s4-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s4-make.txt 'make manifests generate'
  cap s4-rbac.txt "grep -A6 events.k8s.io config/rbac/role.yaml"
  cap s4-test.txt "go vet ./... && $gotest"
  cap s4-lint.txt "$lint"

  broken 4; edit internal/controller/suite_test.go 's/\t\tRecorder: mgr.GetEventRecorder\("watchtower"\),\n//'
  cap s4-norecorder.txt 'go test ./internal/controller/'
  key s4-norecorder.txt 'condition not met'
  broken 4; edit internal/controller/metrics.go 's/(\tmetrics.Registry.MustRegister\(checkUp, probeDuration, probesTotal\)\n)/$1$1/'
  cap s4-dupreg.txt 'go test ./internal/controller/'; key s4-dupreg.txt 'duplicate metrics collector'
  broken 4; edit internal/controller/healthcheck_controller.go 's/\t\t\tforget\(req.Namespace, req.Name\) \/\/ gone: stop exporting its series\n//'
  cap s4-noforget.txt "$lint"
  key s4-noforget.txt 'forget is unused'
}

step5() {
  echo "== step 5: the Service watch"
  use_step 5
  cap s5-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s5-make.txt 'make manifests generate'
  cap s5-test.txt "go vet ./... && $gotest"
  cap s5-testv.txt "go test -v -run 'ServiceTarget' ./internal/controller/ | grep -v '^=== RUN'"
  cap s5-lint.txt "$lint"

  broken 5; edit internal/controller/healthcheck_controller.go 's/(var servicePortsChanged = predicate.Funcs\{\n)/$1\tCreateFunc: func(event.CreateEvent) bool { return false },\n/'
  cap s5-nowatch.txt 'go test ./internal/controller/'; key s5-nowatch.txt 'Healthy=Unknown'
  broken 5; edit internal/controller/healthcheck_controller.go 's/(\terr := mgr.GetFieldIndexer\(\).IndexField\(ctx,\n.*?\n\t\t\}\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n)//s'
  cap s5-noindex.txt 'go test ./internal/controller/'; key s5-noindex.txt 'Healthy=Unknown'
  broken 5; edit internal/controller/suite_test.go 's/clusterDNSProber\{probe.HTTP\{Client: http.DefaultClient\}\}/probe.HTTP{Client: http.DefaultClient}/'
  cap s5-nodns.txt 'go test ./internal/controller/'; key s5-nodns.txt 'Healthy=Unknown|Healthy=False'
}

step6() {
  echo "== step 6: PrometheusRules"
  use_step 6
  cap s6-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s6-make.txt 'make manifests generate'
  cap s6-test.txt "go vet ./... && $gotest"
  cap s6-testv.txt "go test -v -run 'PrometheusRule' ./... 2>&1 | grep -E '^(---|ok|FAIL)'"
  cap s6-lint.txt "$lint"

  broken 6; edit internal/controller/suite_test.go 's/\n[^\n]*START testcrds OMIT\n[^\n]*\n[^\n]*END testcrds OMIT//'
  cap s6-nocrd.txt 'go test ./internal/controller/'; key s6-nocrd.txt 'condition not met'
  broken 6; edit internal/alerting/prometheus.go 's/controllerutil.SetControllerReference\(hc, u, p.Scheme\)/controllerutil.SetOwnerReference(hc, u, p.Scheme)/'
  cap s6-noowner.txt 'go test ./...'; key s6-noowner.txt 'controller (of the rule )?= ' 2
  broken 6; edit internal/controller/suite_test.go 's/\t\tWatchRules:              true,\n//'
  cap s6-noowns.txt 'go test ./internal/controller/'; key s6-noowns.txt 'rule still missing'
  broken 6; edit internal/alerting/prometheus.go 's/\tapply := client.ApplyConfigurationFromUnstructured\(desired\)\n\tif err := p.Client.Apply\(ctx, apply, client.FieldOwner\(FieldOwner\),\n\t\tclient.ForceOwnership\); err != nil \{/\tif err := p.Client.Patch(ctx, desired, client.Apply,\n\t\tclient.FieldOwner(FieldOwner), client.ForceOwnership); err != nil {/'
  cap s6-deprecated.txt "$lint"; key s6-deprecated.txt 'SA1019'
}

step7() {
  echo "== step 7: Datadog and finalizers"
  use_step 7
  cap s7-tree.txt "find . -name '*.go' -not -path './bin/*' | sort"
  cap s7-make.txt 'make manifests generate'
  cap s7-test.txt "go vet ./... && $gotest"
  cap s7-testv.txt "go test -v -run 'Datadog' ./... 2>&1 | grep -E '^(---|ok|FAIL)'"
  cap s7-lint.txt "$lint"

  broken 7; edit internal/alerting/datadog.go 's/\tif id == 0 \{\n\t\tfound, err := d.findByTag\(ctx, uidTag\(hc\)\)\n\t\tif err != nil \{\n\t\t\treturn "", err\n\t\t\}\n\t\tid = found\n\t\}\n//'
  cap s7-notag.txt 'go test ./internal/alerting/'; key s7-notag.txt 'monitors|creates'
  broken 7; edit internal/controller/healthcheck_controller.go 's/\tcontrollerutil.RemoveFinalizer\(hc, finalizerName\)\n\treturn r.Update\(ctx, hc\)/\tcontrollerutil.RemoveFinalizer(hc, finalizerName)\n\treturn nil/'
  cap s7-noupdate.txt 'go test ./internal/controller/'; key s7-noupdate.txt 'still present'
  broken 7; edit internal/alerting/datadog.go 's/\tif d.APIKey == "" \|\| d.AppKey == "" \{\n.*?\n\t\}\n//s'
  cap s7-nokeys.txt 'go test ./internal/alerting/'; key s7-nokeys.txt 'want ErrUnavailable'
}

step8() {
  echo "== step 8: cadence and kind"
  use_step 8
  cap s8-tree.txt "find hack config/samples -type f | sort"
  cap s8-make.txt 'make manifests generate'
  cap s8-test.txt "go vet ./... && $gotest"
  cap s8-testv.txt "go test -v -run 'Cadence' ./internal/controller/ | grep -v '^=== RUN'"
  cap s8-lint.txt "$lint"

  broken 8; edit internal/controller/healthcheck_controller.go 's/\tif wait := r.untilDue\(hc\); wait > 0 \{\n\t\treturn wait\n\t\}\n//'
  cap s8-nogate.txt 'go test ./internal/controller/'; key s8-nogate.txt 'probes, want 1'
  broken 8; edit internal/controller/healthcheck_controller.go 's/last.generation != hc.Generation \|\| //'
  cap s8-nogen.txt 'go test ./internal/controller/'; key s8-nogen.txt 'spec change'
  # The step 7 behaviour on kind: the end-to-end script catches it.
  broken 8; edit internal/controller/healthcheck_controller.go 's/\tif wait := r.untilDue\(hc\); wait > 0 \{\n\t\treturn wait\n\t\}\n//'
  cap s8-e2e-nogate.txt 'bash hack/e2e-kind.sh'
  key s8-e2e-nogate.txt 'turned unhealthy|FAIL' 2

  use_step 8
  rm -rf /tmp/wt
  cap s8-e2e.txt 'OUT=/tmp/wt bash hack/e2e-kind.sh'
  cp /tmp/wt/*.txt "$out/e2e/"
  grep -E 'turned unhealthy|e2e OK' "$out/s8-e2e.txt" > "$out/s8-e2e-key.txt"
  grep -q 'e2e OK' "$out/s8-e2e.txt" || { echo "e2e failed"; exit 1; }
}

for s in $STEPS; do "step$s"; done
echo "captured into $out"
