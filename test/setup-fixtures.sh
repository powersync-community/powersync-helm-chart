#!/usr/bin/env bash
# Idempotent setup of the local test cluster + fixtures the chart needs at runtime.
# Re-runs are safe; existing resources are reused.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="powersync-test"
NAMESPACE="powersync-test"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---
missing=()
for tool in helm kind kubectl docker kubeconform; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
  fail "Missing tools: ${missing[*]}. Install with: brew install ${missing[*]}"
fi

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not running. Start Docker Desktop and retry."
fi

# --- kind cluster ---
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists"
else
  log "creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config "$SCRIPT_DIR/kind-config.yaml"
fi

kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# --- helm repos ---
log "ensuring helm repos"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null

# --- ingress-nginx ---
log "installing ingress-nginx"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set-string controller.nodeSelector.ingress-ready=true \
  --set "controller.tolerations[0].key=node-role.kubernetes.io/control-plane" \
  --set "controller.tolerations[0].operator=Exists" \
  --set "controller.tolerations[0].effect=NoSchedule" \
  --wait --timeout 5m >/dev/null

# --- namespace ---
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# --- mongo (storage + source as separate releases) ---
mongo_install() {
  local release="$1"
  log "installing $release (Bitnami MongoDB replica set)"
  helm upgrade --install "$release" bitnami/mongodb \
    --namespace "$NAMESPACE" \
    --set architecture=replicaset \
    --set replicaCount=1 \
    --set auth.rootUser=root \
    --set auth.rootPassword=test \
    --set persistence.enabled=false \
    --set arbiter.enabled=false \
    --set replicaSetName=rs0 \
    --wait --timeout 5m >/dev/null
}

mongo_install mongo-storage
mongo_install mongo-source

# --- TLS secret stub (chart's ingress.tls is disabled in values-test, but having
#     a placeholder secret lets us exercise the TLS path manually if needed) ---
if ! kubectl -n "$NAMESPACE" get secret test-tls >/dev/null 2>&1; then
  log "creating self-signed TLS secret 'test-tls'"
  tmp=$(mktemp -d)
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
    -subj "/CN=powersync.test.local" -days 30 >/dev/null 2>&1
  kubectl -n "$NAMESPACE" create secret tls test-tls \
    --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
  rm -rf "$tmp"
fi

log "fixtures ready. context: kind-$CLUSTER_NAME, ns: $NAMESPACE"
log "next: ./test/run.sh"
