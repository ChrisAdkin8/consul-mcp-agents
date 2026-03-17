#!/usr/bin/env bash
# tfvars-set.sh — Set or remove a key in terraform.tfvars (idempotent)
# Usage:
#   tfvars-set.sh <tfvars-file> remove <key> [<key2> ...]
#   tfvars-set.sh <tfvars-file> set    <key> <value> [--quoted]
set -euo pipefail

TFVARS="${1:?Usage: tfvars-set.sh <tfvars-file> <action> ...}"
ACTION="${2:?}"
shift 2

case "$ACTION" in
  remove)
    [ $# -eq 0 ] && echo "ERROR: remove requires at least one key" >&2 && exit 1
    TMP="${TFVARS}.tmp"
    cp "$TFVARS" "$TMP"
    for KEY in "$@"; do
      grep -v "^${KEY}[[:space:]]*=" "$TMP" > "${TMP}.2" && mv "${TMP}.2" "$TMP"
    done
    mv "$TMP" "$TFVARS"
    ;;
  set)
    KEY="${1:?set requires <key> <value>}"
    VALUE="${2:?set requires <key> <value>}"
    QUOTED="${3:-}"
    grep -v "^${KEY}[[:space:]]*=" "$TFVARS" > "${TFVARS}.tmp" && mv "${TFVARS}.tmp" "$TFVARS"
    if [ "$QUOTED" = "--quoted" ]; then
      printf '%-28s= "%s"\n' "$KEY" "$VALUE" >> "$TFVARS"
    else
      printf '%-28s= %s\n' "$KEY" "$VALUE" >> "$TFVARS"
    fi
    ;;
  *)
    echo "ERROR: unknown action '$ACTION' (use 'set' or 'remove')" >&2
    exit 1
    ;;
esac
