#!/usr/bin/env bash
# wait-acl-init.sh — Wait for the consul-server-acl-init Job; surface failures.
# Returns 0 on success or kubectl-wait timeout (caller verifies auth method).
set -euo pipefail

NS=consul
JOB=consul-server-acl-init
TIMEOUT=360s

if ! kubectl get job "$JOB" -n "$NS" &>/dev/null; then
  echo "$JOB not found (cleaned up after success)."
  exit 0
fi

if kubectl wait --for=condition=Complete "job/$JOB" -n "$NS" --timeout="$TIMEOUT" 2>/dev/null; then
  echo "$JOB completed."
  exit 0
fi

FAILED=$(kubectl get job "$JOB" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
if [ "$FAILED" = "True" ]; then
  kubectl logs -n "$NS" -l "job-name=$JOB" --tail=100 || true
  echo "ERROR: $JOB FAILED. Run 'task consul:helm-clean' then re-run phase2:apply." >&2
  exit 1
fi

echo "$JOB: kubectl wait timed out; proceeding to auth-method verify."
