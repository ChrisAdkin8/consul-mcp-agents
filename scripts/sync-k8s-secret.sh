#!/usr/bin/env bash
# sync-k8s-secret.sh — Create or update a K8s secret (idempotent)
# Usage: ./scripts/sync-k8s-secret.sh <namespace> <secret-name> <key> <value>
set -euo pipefail

NAMESPACE="${1:?Usage: sync-k8s-secret.sh <namespace> <secret-name> <key> <value>}"
SECRET_NAME="${2:?}"
KEY="${3:?}"
VALUE="${4:?}"

if ! kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; then
  echo "K8s not reachable — secret sync skipped." >&2
  exit 0
fi

if ! kubectl get namespace "$NAMESPACE" &>/dev/null 2>&1; then
  echo "Namespace '$NAMESPACE' not found — secret sync skipped." >&2
  exit 0
fi

kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal="${KEY}=${VALUE}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret ${NAMESPACE}/${SECRET_NAME} synced."
