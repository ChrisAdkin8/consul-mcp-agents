#!/usr/bin/env bash
# tfvars-get.sh — Read a value from terraform.tfvars
# Usage: ./scripts/tfvars-get.sh <tfvars-file> <key>
# Prints the value to stdout. Exits 1 if not found.
set -euo pipefail

TFVARS="${1:?Usage: tfvars-get.sh <tfvars-file> <key>}"
KEY="${2:?Usage: tfvars-get.sh <tfvars-file> <key>}"

VALUE=$(grep -E "^${KEY}[[:space:]]*=" "$TFVARS" 2>/dev/null | awk -F'"' '{print $2}')
[ -z "$VALUE" ] && exit 1
echo "$VALUE"
