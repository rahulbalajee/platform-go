#!/usr/bin/env bash
# End-to-end run on kind: build the operator image, deploy it with the real
# PrometheusRule CRD installed, apply the demo HealthChecks, and check that
# they reach the expected conditions at the expected pace.
#
#   hack/e2e-kind.sh               # run and assert
#   OUT=/tmp/wt hack/e2e-kind.sh   # also save each shown output in /tmp/wt
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=${CLUSTER:-watchtower}
IMG=${IMG:-watchtower:dev}
PROM_OP_VERSION=${PROM_OP_VERSION:-v0.94.2}
OUT=${OUT:-}
show() { # show NAME CMD...: run CMD, print it with its output, save the output
  local name=$1; shift
  echo "\$ $*"
  local out; out=$("$@" 2>&1)
  echo "$out"
  if [[ -n $OUT ]]; then mkdir -p "$OUT"; printf '%s\n' "$out" > "$OUT/$name.txt"; fi
}

# START cluster OMIT
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# The real PrometheusRule CRD. Server-side apply: it is too large for the
# last-applied-configuration annotation that client-side apply writes.
crds=https://raw.githubusercontent.com/prometheus-operator/prometheus-operator
crds+=/$PROM_OP_VERSION/example/prometheus-operator-crd
kubectl apply --server-side -f "$crds/monitoring.coreos.com_prometheusrules.yaml"
# END cluster OMIT

# START build OMIT
# Cross-compile on the host and package scratch images: no base images to
# pull, and the host's build cache makes rebuilds take seconds.
CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT
for ca in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
  [[ -f $ca ]] && { cp "$ca" "$CTX/ca-certificates.crt"; break; }
done
image() { # image PACKAGE BINARY TAG
  CGO_ENABLED=0 GOOS=linux GOARCH=$(go env GOARCH) \
    go build -trimpath -ldflags="-s -w" -o "$CTX/$2" "$1"
  docker build -q -f hack/scratch.Dockerfile --build-arg BINARY="$2" -t "$3" "$CTX"
}
make manifests generate >/dev/null
image ./cmd manager "$IMG"
image ./hack/demoapp demoapp watchtower-demoapp:dev
kind load docker-image "$IMG" watchtower-demoapp:dev --name "$CLUSTER"

make deploy IMG="$IMG"
deploy=deploy/watchtower-controller-manager
kubectl -n watchtower-system rollout restart "$deploy"
kubectl -n watchtower-system rollout status "$deploy" --timeout=180s
# Wait until the new pod leads. The old one may still be reconciling on its
# way out, and two operators would probe the demo checks twice as often.
pod=$(kubectl -n watchtower-system get pods -l control-plane=controller-manager \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
for _ in $(seq 60); do
  holder=$(kubectl -n watchtower-system get lease 8bdb4b95.platformgo.dev \
    -o jsonpath='{.spec.holderIdentity}')
  [[ $holder == "${pod}_"* ]] && break
  sleep 1
done
[[ $holder == "${pod}_"* ]] || { echo "FAIL: $pod never became leader" >&2; exit 1; }
# END build OMIT

# START demo OMIT
# The app first, then the checks, so every check can probe from the start.
kubectl delete namespace shop --ignore-not-found --wait=true
kubectl apply -f config/samples/demo.yaml -l demo=app
kubectl -n shop rollout status deploy/storefront --timeout=180s
kubectl apply -f config/samples/demo.yaml
wait_hc() { kubectl -n shop wait "hc/$1" --for="$2" --timeout="${3:-120s}"; }
# END demo OMIT

# START cadence OMIT
# payments-api fails every probe. Its third failure, two 10s intervals
# after the first, turns it unhealthy about 20s after it was created.
# Much sooner means reconciles triggered by watch events probed early.
wait_hc payments-api condition=Healthy=false 120s
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %FT%TZ "$1" +%s; }
hc() { kubectl -n shop get hc payments-api -o "jsonpath=$1"; }
created=$(hc '{.metadata.creationTimestamp}')
failed=$(hc '{.status.conditions[?(@.type=="Healthy")].lastTransitionTime}')
secs=$(( $(epoch "$failed") - $(epoch "$created") ))
echo "payments-api turned unhealthy ${secs}s after it was created"
if (( secs < 15 )); then
  echo "FAIL: 3 failures 10s apart took ${secs}s: probes ran early" >&2
  exit 1
fi
# END cadence OMIT

# START ready OMIT
wait_hc storefront condition=Healthy
wait_hc storefront condition=AlertingReady 60s
reason='{.status.conditions[?(@.type=="Healthy")].reason}'
wait_hc inventory "jsonpath=$reason=TargetUnresolved" 60s
# END ready OMIT

# START capture OMIT
show get-hc kubectl get healthchecks -n shop
show describe-payments kubectl describe hc payments-api -n shop
show get-rules kubectl get prometheusrules -n shop
show rule-yaml kubectl get prometheusrule watchtower-storefront -n shop -o yaml
show events kubectl get events -n shop \
  --field-selector reportingComponent=watchtower \
  -o custom-columns='REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message'

# Self-healing: delete an owned rule and watch it come back.
show rule-deleted kubectl delete prometheusrule watchtower-storefront -n shop
sleep 3
show rule-restored kubectl get prometheusrule watchtower-storefront -n shop
# END capture OMIT

# START service OMIT
# Create the missing Service: the check resolves within seconds, not at the
# next interval, because the controller watches Services.
kubectl -n shop create service clusterip inventory --tcp=8080:8080 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n shop patch service inventory --type=merge \
  -p '{"spec":{"selector":{"app":"storefront"}}}'
url=http://inventory.shop.svc.cluster.local:8080/healthz
wait_hc inventory "jsonpath={.status.resolvedURL}=$url" 30s
cols='NAME:.metadata.name,TARGET:.status.resolvedURL'
cols+=',REASON:.status.conditions[?(@.type=="Healthy")].reason'
show resolved-inventory kubectl get hc inventory -n shop -o custom-columns="$cols"
wait_hc inventory condition=Healthy 60s
show get-hc-after kubectl get healthchecks -n shop
# END service OMIT

# START metrics OMIT
# Operator metrics. The endpoint wants a token allowed to GET /metrics.
ns=watchtower-system
kubectl -n $ns create serviceaccount metrics-probe --dry-run=client -o yaml |
  kubectl apply -f -
kubectl create clusterrolebinding watchtower-metrics-probe \
  --clusterrole=watchtower-metrics-reader --serviceaccount=$ns:metrics-probe \
  --dry-run=client -o yaml | kubectl apply -f -
TOKEN=$(kubectl -n $ns create token metrics-probe)
svc=svc/watchtower-controller-manager-metrics-service
kubectl -n $ns port-forward $svc 8443:8443 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true; rm -rf "$CTX"' EXIT; sleep 3
metrics() {
  curl -sk -H "Authorization: Bearer $TOKEN" https://localhost:8443/metrics |
    grep -E '^watchtower_healthcheck_(up|probes_total)' | sort
}
show metrics metrics
echo "e2e OK"
# END metrics OMIT
