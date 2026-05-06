#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="powersync-test"

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "[teardown] deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "[teardown] no cluster '$CLUSTER_NAME'; nothing to do"
fi
