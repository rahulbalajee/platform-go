#!/usr/bin/env bash
# End-to-end run on kind: build the operator image, deploy it with the real
# PrometheusRule CRD installed, apply the demo HealthChecks, wait for the
# expected conditions, and (optionally) capture output for the book.
#
#   hack/e2e-kind.sh            # run and assert
#   OUT=../../book/output/wt hack/e2e-kind.sh   # also capture output
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=${CLUSTER:-watchtower}
IMG=${IMG:-watchtower:dev}
PROM_OP_VERSION=${PROM_OP_VERSION:-v0.94.2}
OUT=${OUT:-}
capture() { # capture NAME CMD...: run CMD, show it, and save "$ CMD" + output
  local name=$1; shift
  echo "\$ $*"
  local out; out=$("$@" 2>&1)
  echo "$out"
  if [[ -n "$OUT" ]]; then mkdir -p "$OUT"; printf '%s\n' "$out" > "$OUT/$name.txt"; fi
}

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# The real PrometheusRule CRD. Server-side apply: it is too large for the
# last-applied-configuration annotation that client-side apply writes.
kubectl apply --server-side -f "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_OP_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml"

# Cross-compile on the host and package scratch images: no base images to
# pull, and the host's build cache makes rebuilds take seconds.
ARCH=$(go env GOARCH)
CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT
for ca in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
  [[ -f $ca ]] && { cp "$ca" "$CTX/ca-certificates.crt"; break; }
done
make manifests generate >/dev/null
CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build -trimpath -ldflags="-s -w" -o "$CTX/manager" ./cmd
CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build -trimpath -ldflags="-s -w" -o "$CTX/demoapp" ./hack/demoapp
docker build -q -f hack/scratch.Dockerfile --build-arg BINARY=manager -t "$IMG" "$CTX"
docker build -q -f hack/scratch.Dockerfile --build-arg BINARY=demoapp -t watchtower-demoapp:dev "$CTX"
kind load docker-image "$IMG" watchtower-demoapp:dev --name "$CLUSTER"
make deploy IMG="$IMG"
kubectl -n watchtower-system rollout restart deploy/watchtower-controller-manager
kubectl -n watchtower-system rollout status deploy/watchtower-controller-manager --timeout=180s

kubectl delete namespace shop --ignore-not-found --wait=true
kubectl apply -f config/samples/demo.yaml
kubectl -n shop rollout status deploy/storefront --timeout=180s

kubectl -n shop wait hc/storefront --for=condition=Healthy --timeout=120s
kubectl -n shop wait hc/storefront --for=condition=AlertingReady --timeout=60s
kubectl -n shop wait hc/payments-api --for=condition=Healthy=false --timeout=180s
kubectl -n shop wait hc/inventory --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].reason}'=TargetUnresolved --timeout=60s

capture get-hc kubectl get healthchecks -n shop
capture describe-payments kubectl describe hc payments-api -n shop
capture get-rules kubectl get prometheusrules -n shop
capture rule-yaml kubectl get prometheusrule watchtower-storefront -n shop -o yaml
capture events kubectl get events -n shop --field-selector reportingComponent=watchtower \
  -o custom-columns='REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' 

# Self-healing: delete an owned rule and watch it come back.
capture rule-deleted kubectl delete prometheusrule watchtower-storefront -n shop
sleep 3
capture rule-restored kubectl get prometheusrule watchtower-storefront -n shop

# Fix the missing Service: the check resolves within seconds, not at the
# next interval, because the controller watches Services.
kubectl -n shop create service clusterip inventory --tcp=8080:8080 --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n shop patch service inventory --type=merge -p '{"spec":{"selector":{"app":"storefront"}}}'
kubectl -n shop wait hc/inventory --for=jsonpath='{.status.resolvedURL}'=http://inventory.shop.svc.cluster.local:8080/healthz --timeout=30s
cols='NAME:.metadata.name,TARGET:.status.resolvedURL'
cols+=',REASON:.status.conditions[?(@.type=="Healthy")].reason'
capture resolved-inventory kubectl get hc inventory -n shop -o custom-columns="$cols"
kubectl -n shop wait hc/inventory --for=condition=Healthy --timeout=60s
capture get-hc-after kubectl get healthchecks -n shop

# Operator metrics (the endpoint is protected by authn/authz).
kubectl -n watchtower-system create serviceaccount metrics-probe --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding watchtower-metrics-probe --clusterrole=watchtower-metrics-reader --serviceaccount=watchtower-system:metrics-probe --dry-run=client -o yaml | kubectl apply -f -
TOKEN=$(kubectl -n watchtower-system create token metrics-probe)
kubectl -n watchtower-system port-forward svc/watchtower-controller-manager-metrics-service 8443:8443 >/dev/null 2>&1 &
PF=$!; disown; trap 'kill $PF 2>/dev/null || true; rm -rf "$CTX"' EXIT; sleep 3
capture metrics sh -c "curl -sk -H 'Authorization: Bearer $TOKEN' https://localhost:8443/metrics | grep -E '^watchtower_healthcheck_(up|probes_total)' | sort"
echo "e2e OK"
