#!/usr/bin/env bash
# consul-bootstrap-acl.sh — Bootstrap Consul ACLs (idempotent)
# Updates terraform.tfvars and K8s secret with the bootstrap token.
# Usage: ./scripts/consul-bootstrap-acl.sh <TF_DIR> <PROJECT> <REGION> <TOKEN_FILE>
set -euo pipefail

TF_DIR="${1:?Usage: consul-bootstrap-acl.sh <TF_DIR> <PROJECT> <REGION> <TOKEN_FILE>}"
PROJECT="${2:?}"
REGION="${3:?}"
TOKEN_FILE="${4:?}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SSH="$SCRIPT_DIR/consul-ssh.sh $TF_DIR $PROJECT $REGION"
SYNC="$SCRIPT_DIR/sync-k8s-secret.sh"
TVSET="$SCRIPT_DIR/tfvars-set.sh"
TVGET="$SCRIPT_DIR/tfvars-get.sh"
TFVARS="$TF_DIR/terraform.tfvars"

echo "=== Consul ACL bootstrap ==="

# Fast path: if we already have a valid token, sync K8s secret and exit
EXISTING_TOKEN=$($TVGET "$TFVARS" consul_bootstrap_token || true)
if [ -n "$EXISTING_TOKEN" ]; then
  ACL_CHECK=$($SSH "consul acl token list -token='${EXISTING_TOKEN}' 2>&1" || true)
  if echo "$ACL_CHECK" | grep -q "AccessorID"; then
    echo "  ACLs already bootstrapped and token is valid."
    $SYNC consul consul-bootstrap-acl-token token "${EXISTING_TOKEN}" || true
    exit 0
  fi
fi

# No valid token — wait for Consul leader before bootstrapping
echo "  Waiting for Consul leader..."
LEADER=""
DELAY=2
for i in $(seq 1 12); do
  LEADER=$($SSH "curl -sf http://127.0.0.1:8500/v1/status/leader 2>/dev/null || true" || true)
  if [ -n "$LEADER" ] && [ "$LEADER" != '""' ]; then
    echo "  Consul leader elected: ${LEADER}"
    break
  fi
  echo "  Attempt $i/12... waiting ${DELAY}s"
  sleep "$DELAY"
  # Exponential backoff: 2, 4, 8, 15, 15, 15, ...
  DELAY=$((DELAY * 2))
  [ "$DELAY" -gt 15 ] && DELAY=15
done
[ -z "$LEADER" ] || [ "$LEADER" = '""' ] && echo "ERROR: Consul server not ready after ~3 minutes." && exit 1

echo "  Bootstrapping..."
BOOTSTRAP_OUTPUT=$($SSH "consul acl bootstrap 2>&1")

# If already bootstrapped, extract reset index and retry
if echo "$BOOTSTRAP_OUTPUT" | grep -q "already been bootstrapped\|bootstrap no longer allowed"; then
  RESET_INDEX=$(echo "$BOOTSTRAP_OUTPUT" | grep -oE 'reset index: [0-9]+' | awk '{print $3}')
  [ -z "$RESET_INDEX" ] && echo "ERROR: ACLs already bootstrapped but could not extract reset index." && echo "$BOOTSTRAP_OUTPUT" && exit 1
  echo "  ACLs already bootstrapped (token lost). Resetting via index ${RESET_INDEX}..."
  $SSH "echo ${RESET_INDEX} | sudo tee /opt/consul/acl-bootstrap-reset"
  BOOTSTRAP_OUTPUT=$($SSH "sudo /usr/local/bin/consul acl bootstrap 2>&1")
fi

NEW_TOKEN=$(echo "$BOOTSTRAP_OUTPUT" | grep 'SecretID:' | awk '{print $2}')
[ -z "$NEW_TOKEN" ] && echo "ERROR: Failed to parse token:" && echo "$BOOTSTRAP_OUTPUT" && exit 1
echo "  Token: ${NEW_TOKEN}"

# Update tfvars + token file
$TVSET "$TFVARS" set consul_bootstrap_token "${NEW_TOKEN}" --quoted
echo "${NEW_TOKEN}" > "$TOKEN_FILE"

# Sync K8s secret
$SYNC consul consul-bootstrap-acl-token token "${NEW_TOKEN}" || true
echo "  Bootstrap complete."
