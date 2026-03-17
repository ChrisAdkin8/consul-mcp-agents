#!/usr/bin/env bash
# consul-ssh.sh — Look up Consul server VM and run a command via IAP SSH
# Usage: ./scripts/consul-ssh.sh <TF_DIR> <PROJECT> <REGION> "<command>"
set -euo pipefail

TF_DIR="${1:?Usage: consul-ssh.sh <TF_DIR> <PROJECT> <REGION> <command>}"
PROJECT="${2:?}"
REGION="${3:?}"
COMMAND="${4:?}"

PREFIX=$(cd "$TF_DIR" && terraform output -raw name_prefix 2>/dev/null)
VM_NAME=$(gcloud compute instances list \
  --project "$PROJECT" \
  --filter="name~${PREFIX}-consul-server" \
  --format="value(name)" | head -1)
[ -z "$VM_NAME" ] && echo "ERROR: No Consul server VM found." >&2 && exit 1
echo "$VM_NAME" >&2

gcloud compute ssh "$VM_NAME" \
  --zone "${REGION}-a" --project "$PROJECT" \
  --tunnel-through-iap \
  --command "$COMMAND" 2>/dev/null
