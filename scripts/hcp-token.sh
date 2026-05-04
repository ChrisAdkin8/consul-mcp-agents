#!/usr/bin/env bash
# Print an HCP API access token to stdout.
#
# Reads `hcp_client_id` from the supplied tfvars file and `TF_VAR_hcp_client_secret`
# from the environment. Exits non-zero with a diagnostic if either is missing or
# the OAuth exchange fails. No secrets are printed; only the access token.
#
# Usage: scripts/hcp-token.sh <path-to-terraform.tfvars>
set -euo pipefail

TFVARS="${1:?usage: $0 <terraform.tfvars>}"

CLIENT_ID="$(grep -E '^hcp_client_id' "$TFVARS" 2>/dev/null | awk -F'"' '{print $2}' || true)"
CLIENT_SECRET="${TF_VAR_hcp_client_secret:-${HCP_CLIENT_SECRET:-}}"

if [ -z "$CLIENT_ID" ]; then
  echo "ERROR: hcp_client_id not found in $TFVARS" >&2
  exit 1
fi
if [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: TF_VAR_hcp_client_secret env var is not set" >&2
  echo "       export TF_VAR_hcp_client_secret='...' (HCP service-principal secret)" >&2
  exit 1
fi

RESP="$(curl -fsS --request POST \
  --url 'https://auth.idp.hashicorp.com/oauth2/token' \
  --data 'grant_type=client_credentials' \
  --data "client_id=$CLIENT_ID" \
  --data "client_secret=$CLIENT_SECRET" \
  --data 'audience=https://api.hashicorp.cloud')" || {
    echo "ERROR: HCP OAuth token exchange failed" >&2
    exit 1
  }

echo "$RESP" | python3 -c "import sys,json; t=json.load(sys.stdin).get('access_token'); print(t) if t else sys.exit('no access_token in response')"
