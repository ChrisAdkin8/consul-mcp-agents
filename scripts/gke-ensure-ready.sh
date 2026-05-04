#!/usr/bin/env bash
# gke-ensure-ready.sh — Wait for GKE, set kubeconfig, write private endpoint +
# gke_cluster_ready=true into terraform.tfvars. Exits 0 (no-op) when REQUIRED!=true
# and the cluster isn't running yet, so it's safe to chain into early-phase tasks.
#
# Usage: scripts/gke-ensure-ready.sh <tf-dir> <gcp-project> <gcp-region> <required>
#   <required>: "true" → fail loud on missing cluster / unreachable API
#               anything else → silent no-op
set -uo pipefail

TF_DIR="${1:?usage: $0 <tf-dir> <gcp-project> <gcp-region> <required>}"
GCP_PROJECT="${2:?missing gcp-project}"
GCP_REGION="${3:?missing gcp-region}"
REQUIRED="${4:-false}"
TVSET="$(dirname "$0")/tfvars-set.sh"
TVGET="$(dirname "$0")/tfvars-get.sh"
TFVARS="$TF_DIR/terraform.tfvars"
LOC=(--project "$GCP_PROJECT" --region "$GCP_REGION")

cd "$TF_DIR"

fail() {
  if [ "$REQUIRED" = "true" ]; then
    echo "ERROR: $1" >&2
    exit 1
  fi
  exit 0
}

CLUSTER="$("$TVGET" "$TFVARS" gke_cluster_name 2>/dev/null || true)"
[ -z "$CLUSTER" ] && fail "no gke_cluster_name in tfvars"

STATUS="$(gcloud container clusters describe "$CLUSTER" "${LOC[@]}" --format='value(status)' 2>/dev/null || echo NOT_FOUND)"
[ "$STATUS" != "RUNNING" ] && fail "cluster '$CLUSTER' status='$STATUS'"

gcloud container clusters get-credentials "$CLUSTER" "${LOC[@]}" --quiet
kubectl cluster-info --request-timeout=10s &>/dev/null || fail "K8s API not reachable"

ENDPOINT="$(gcloud container clusters describe "$CLUSTER" "${LOC[@]}" \
  --format='value(privateClusterConfig.privateEndpoint)' 2>/dev/null || true)"
[ -z "$ENDPOINT" ] && echo "WARNING: empty private endpoint — TokenReview from Consul VMs may fail"

"$TVSET" terraform.tfvars remove gke_cluster_endpoint gke_cluster_ca_certificate gke_cluster_private_endpoint gke_cluster_ready
[ -n "$ENDPOINT" ] && "$TVSET" terraform.tfvars set gke_cluster_private_endpoint "$ENDPOINT" --quoted
"$TVSET" terraform.tfvars set gke_cluster_ready true

echo "GKE ready — kubeconfig set, gke_cluster_ready=true, private endpoint: ${ENDPOINT:-<empty>}"
