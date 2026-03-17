#!/usr/bin/env bash
# preflight.sh — Check all required tools are installed and GCP auth is configured
# Usage: ./scripts/preflight.sh <GCP_PROJECT> <GCP_REGION>
set -euo pipefail

GCP_PROJECT="${1:?Usage: preflight.sh <GCP_PROJECT> <GCP_REGION>}"
GCP_REGION="${2:?Usage: preflight.sh <GCP_PROJECT> <GCP_REGION>}"

echo "=== Preflight checks ==="

echo ""
echo "--- CLI tools ---"
FAIL=false
for tool in terraform packer gcloud kubectl docker vault jq uuidgen; do
  if command -v "$tool" &>/dev/null; then
    echo "  ✓ $tool"
  else
    echo "  ✗ $tool NOT FOUND"
    FAIL=true
  fi
done

echo ""
echo "--- GCP authentication ---"

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -n "$ACTIVE_ACCOUNT" ]; then
  echo "  ✓ gcloud auth (${ACTIVE_ACCOUNT})"
else
  echo "  ✗ No active gcloud account. Run: gcloud auth login"
  FAIL=true
fi

if ! ADC_CHECK=$(gcloud auth application-default print-access-token 2>&1); then
  echo "  ✗ ADC not configured. Run: gcloud auth application-default login"
  FAIL=true
else
  ADC_API_CHECK=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${ADC_CHECK}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/$(gcloud config get-value project 2>/dev/null)" 2>&1 || true)
  if [ "$ADC_API_CHECK" = "200" ]; then
    echo "  ✓ ADC valid (API verified)"
  else
    echo "  ✗ ADC token exists but API call failed (HTTP ${ADC_API_CHECK}). Run: gcloud auth application-default login"
    FAIL=true
  fi
fi

GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -n "$GCLOUD_PROJECT" ] && [ "$GCLOUD_PROJECT" != "(unset)" ]; then
  echo "  ✓ gcloud project: ${GCLOUD_PROJECT}"
  if [ "$GCP_PROJECT" != "UNSET" ] && [ "$GCLOUD_PROJECT" != "$GCP_PROJECT" ]; then
    echo "    ⚠ WARNING: gcloud project differs from tfvars '${GCP_PROJECT}'"
  fi
else
  echo "  ✗ No gcloud project set. Run: gcloud config set project <project-id>"
  FAIL=true
fi

if docker info &>/dev/null; then
  echo "  ✓ Docker daemon running"
else
  echo "  ✗ Docker daemon not running. Start Docker Desktop or dockerd"
  FAIL=true
fi

AR_HOST="${GCP_REGION}-docker.pkg.dev"
if cat ~/.docker/config.json 2>/dev/null | grep -q "${AR_HOST}"; then
  echo "  ✓ Docker configured for ${AR_HOST}"
else
  echo "  ✗ Docker not configured for ${AR_HOST}. Run: gcloud auth configure-docker ${AR_HOST}"
  FAIL=true
fi

echo ""
echo "--- Project ---"
echo "  GCP Project: ${GCP_PROJECT}"
echo "  GCP Region:  ${GCP_REGION}"
if [ "$GCP_PROJECT" = "UNSET" ]; then
  echo "  ✗ gcp_project_id not set in terraform.tfvars"
  FAIL=true
fi

echo ""
if [ "$FAIL" = "true" ]; then
  echo "PREFLIGHT FAILED"
  exit 1
fi
echo "All checks passed."
