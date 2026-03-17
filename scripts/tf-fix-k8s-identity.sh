#!/usr/bin/env bash
# tf-fix-k8s-identity.sh — Fix Kubernetes provider 'Unexpected Identity Change' bug
#
# Usage: tf-fix-k8s-identity.sh [--cleanup] [PATTERN ...]
#
#   --cleanup   Also kubectl-delete affected namespaces/resources before state rm
#               (use for destroy; skip for pre-apply where terraform recreates them)
#   PATTERN     grep patterns to match terraform state addresses
#               (default: all K8s/Consul/Helm resources)
#
# Removes ALL matching K8s resources from state unconditionally. The previous
# per-resource detection (checking metadata[0].name) missed resources where the
# provider's internal identity tracking was null but the resource metadata was intact.
#
# Run from the Terraform scenario directory.
set -euo pipefail

CLEANUP=false
PATTERNS=()
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP=true ;;
    *)         PATTERNS+=("$arg") ;;
  esac
done

# Default: all K8s-related resources
if [ ${#PATTERNS[@]} -eq 0 ]; then
  PATTERNS=(
    '^module\.mcp_agents\(\[0\]\)\?\.\(kubernetes_\|consul_\)'
    '^module\.gke\(\[0\]\)\?\.\(kubernetes_\|helm_release\.\)'
    '^kubernetes_'
  )
fi

# Collect matching state resources
ALL_STATE=$(terraform state list 2>/dev/null || true)
[ -z "$ALL_STATE" ] && exit 0

RESOURCES=""
for pat in "${PATTERNS[@]}"; do
  MATCHED=$(echo "$ALL_STATE" | grep "$pat" || true)
  [ -n "$MATCHED" ] && RESOURCES="${RESOURCES}${MATCHED}"$'\n'
done
RESOURCES=$(echo "$RESOURCES" | sed '/^$/d' | sort -u)
[ -z "$RESOURCES" ] && exit 0

echo "=== Fixing K8s provider identity bug ==="
echo "  Found $(echo "$RESOURCES" | wc -l | tr -d ' ') K8s resources to remove from state"

# Optional kubectl cleanup (for destroy path)
if [ "$CLEANUP" = "true" ] && kubectl cluster-info --request-timeout=5s &>/dev/null 2>&1; then
  if echo "$RESOURCES" | grep -q '^module\.mcp_agents'; then
    echo "  kubectl: deleting mcp-agents namespace"
    kubectl delete namespace mcp-agents --ignore-not-found --wait=true 2>/dev/null || true
  fi
  if echo "$RESOURCES" | grep -q '^module\.gke'; then
    echo "  kubectl: uninstalling consul helm + deleting namespace"
    helm uninstall consul -n consul --wait 2>/dev/null || true
    kubectl delete namespace consul --ignore-not-found --wait=true 2>/dev/null || true
  fi
  if echo "$RESOURCES" | grep -q '^kubernetes_.*vault.reviewer'; then
    echo "  kubectl: deleting vault-reviewer resources"
    kubectl delete secret vault-reviewer-token -n kube-system --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrolebinding vault-reviewer --ignore-not-found 2>/dev/null || true
    kubectl delete serviceaccount vault-reviewer -n kube-system --ignore-not-found 2>/dev/null || true
  fi
fi

# Remove all matched resources from state unconditionally
while IFS= read -r addr; do
  echo "  Removing from state: $addr"
  terraform state rm "$addr" 2>/dev/null || true
done <<< "$RESOURCES"
echo "  Done — terraform will recreate these resources."
