#!/usr/bin/env bash
# consul-iap-tunnel.sh — Start IAP tunnel: Consul server :8501 → localhost:18501
# Usage: ./scripts/consul-iap-tunnel.sh <GCP_PROJECT> <GCP_REGION>
set -euo pipefail

GCP_PROJECT="${1:?Usage: consul-iap-tunnel.sh <GCP_PROJECT> <GCP_REGION>}"
GCP_REGION="${2:?Usage: consul-iap-tunnel.sh <GCP_PROJECT> <GCP_REGION>}"
PID_FILE=/tmp/consul-iap-tunnel.pid

lsof -ti:18501 | xargs kill -9 2>/dev/null || true

VM=$(gcloud compute instances list --project "$GCP_PROJECT" \
  --filter="name~consul-server" --format="value(name)" | head -1)
[ -z "$VM" ] && { echo "ERROR: no Consul server VM found" >&2; exit 1; }

echo "Tunnel: $VM:8501 → localhost:18501"
gcloud compute start-iap-tunnel "$VM" 8501 \
  --local-host-port=localhost:18501 \
  --zone="${GCP_REGION}-a" --project="$GCP_PROJECT" &
echo $! > "$PID_FILE"

for _ in $(seq 1 30); do
  if lsof -i :18501 -P >/dev/null 2>&1; then
    echo "Tunnel up (PID $(cat "$PID_FILE"))."
    exit 0
  fi
  sleep 1
done

echo "ERROR: port 18501 not bound after 30s. Check IAP firewall rule." >&2
exit 1
