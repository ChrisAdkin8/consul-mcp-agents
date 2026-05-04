#!/usr/bin/env bash
# List HCP HVNs in this org/project whose names match the random_pet pattern
# (`^[a-z]+-[a-z]+-hvn$`) — i.e. likely orphans from prior `terraform apply` runs
# that were never destroyed. Delete the cluster first, then the HVN, via the HCP UI.
#
# Usage: scripts/hcp-list-orphans.sh <terraform.tfvars>
set -euo pipefail

TFVARS="${1:?usage: $0 <terraform.tfvars>}"
HERE="$(dirname "$0")"

TOKEN="$("$HERE/hcp-token.sh" "$TFVARS")"
IDENT="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
  https://api.cloud.hashicorp.com/iam/2019-12-10/caller-identity)"

read -r ORG PROJ <<<"$(echo "$IDENT" | python3 -c "
import sys, json
p = json.load(sys.stdin)['principal']['service']
print(p['organization_id'], p['project_id'])
")"

echo "Scanning org=$ORG project=$PROJ for HVNs matching ^[a-z]+-[a-z]+-hvn\$ ..."
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "https://api.cloud.hashicorp.com/network/2020-09-07/organizations/$ORG/projects/$PROJ/networks" \
  | python3 -c "
import sys, json, re
hits = [n for n in json.load(sys.stdin).get('networks', []) if re.match(r'^[a-z]+-[a-z]+-hvn$', n['id'])]
if not hits:
    print('No orphan-shaped HVNs found.'); sys.exit()
print(f'Found {len(hits)} HVNs matching the random_pet pattern:')
for n in hits:
    print(f\"  {n['id']:30s} created={n['created_at'][:10]} cidr={n['cidr_block']}\")
print('\\nDelete (cluster first, then HVN) via the HCP UI or API.')
"
