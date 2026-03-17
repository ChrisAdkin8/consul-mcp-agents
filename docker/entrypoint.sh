#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh
#
# Container entrypoint for the vault-mcp-agents pod.
#
# Startup sequence:
#   1. Wait for vault-agent init container to finish rendering secrets
#   2. Source LLM API keys from vault-agent rendered files
#   3. Copy vault-agent rendered config/policies to expected paths
#   4. Start ttyd web terminal wrapping the vault-mcp-agents CLI
#
# The vault-agent init container (defined in Terraform mcp-agents-k8s module)
# runs before this container starts and renders:
#   /vault/secrets/settings.yaml     — Vault KV → settings.yaml
#   /vault/secrets/capabilities.yaml — Vault KV → capabilities.yaml
#   /vault/secrets/anthropic-key     — Anthropic API key (raw value)
#   /vault/secrets/openai-key        — OpenAI API key (raw value)
#   /vault/secrets/.ready            — Sentinel file
#
# In local development (docker run without vault-agent init container),
# the script falls through to using /app/config/settings.yaml directly.
# =============================================================================

set -euo pipefail

READY_FILE="${VAULT_AGENT_READY_FILE:-/tmp/vault-agent-ready}"
CONFIG_PATH="${MCP_CONFIG_PATH:-/vault/secrets/settings.yaml}"
POLICIES_PATH="${MCP_POLICIES_PATH:-/vault/secrets/capabilities.yaml}"
MAX_WAIT="${VAULT_AGENT_TIMEOUT:-120}"
WAITED=0

echo "=== vault-mcp-agents container starting ==="
echo "Vault address: ${VAULT_ADDR:-not set}"

# ---- Step 1: Wait for vault-agent init container ----
if [ -d /vault/secrets ]; then
  echo "Waiting for vault-agent to render secrets (max ${MAX_WAIT}s)..."
  while [ ! -f "/vault/secrets/.ready" ] && [ "$WAITED" -lt "$MAX_WAIT" ]; do
    sleep 2
    WAITED=$((WAITED + 2))
    echo "  Waited ${WAITED}s..."
  done

  if [ ! -f "/vault/secrets/.ready" ]; then
    if [ "${ALLOW_BUNDLED_FALLBACK:-false}" = "true" ]; then
      echo "WARNING: vault-agent did not complete within ${MAX_WAIT}s."
      echo "Falling back to bundled config files in /app/config/ (ALLOW_BUNDLED_FALLBACK=true)"
      CONFIG_PATH="/app/config/settings.yaml"
      POLICIES_PATH="/app/policies/capabilities.yaml"
    else
      echo "ERROR: vault-agent did not complete within ${MAX_WAIT}s."
      echo "Set ALLOW_BUNDLED_FALLBACK=true to use bundled config, or increase VAULT_AGENT_TIMEOUT."
      exit 1
    fi
  else
    echo "vault-agent secrets are ready."
    touch "${READY_FILE}"
  fi
else
  echo "No /vault/secrets directory — using bundled config (local dev mode)."
  CONFIG_PATH="/app/config/settings.yaml"
  POLICIES_PATH="/app/policies/capabilities.yaml"
fi

# ---- Step 2: Source LLM API keys ----
if [ -f /vault/secrets/anthropic-key ]; then
  export ANTHROPIC_API_KEY
  ANTHROPIC_API_KEY=$(cat /vault/secrets/anthropic-key)
  echo "ANTHROPIC_API_KEY: loaded from Vault (${#ANTHROPIC_API_KEY} chars)"
fi

if [ -f /vault/secrets/openai-key ]; then
  export OPENAI_API_KEY
  OPENAI_API_KEY=$(cat /vault/secrets/openai-key)
  echo "OPENAI_API_KEY: loaded from Vault (${#OPENAI_API_KEY} chars)"
fi

# ---- Step 3: Validate config exists ----
if [ ! -f "${CONFIG_PATH}" ]; then
  echo "ERROR: Config file not found at ${CONFIG_PATH}"
  echo "Check that vault-agent rendered the settings.yaml template correctly."
  exit 1
fi

echo "Config: ${CONFIG_PATH}"
echo "Policies: ${POLICIES_PATH}"

# ---- Step 4: Start ttyd web terminal ----
# ttyd wraps the vault-mcp-agents CLI in a browser-accessible terminal.
# Each browser connection gets an interactive session where the user:
#   1. Logs in with Vault userpass credentials
#   2. Selects an agent (data_agent or compute_agent)
#   3. Runs natural-language commands
#
# --once: closes the ttyd connection when the CLI exits (clean session end)
# --writable: allows user keyboard input
# --port 7681: standard ttyd port
echo "=== Starting ttyd web terminal on port 7681 ==="

# Build credential args if TTYD_CREDENTIAL is set (format: user:pass)
CRED_ARGS=()
if [ -n "${TTYD_CREDENTIAL:-}" ]; then
  CRED_ARGS=(--credential "${TTYD_CREDENTIAL}")
fi

# Export variables so they are inherited by the ttyd-spawned shell.
# Avoid interpolating secrets into bash -c strings (shell injection risk).
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export MCP_CONFIG_PATH="${CONFIG_PATH}"
export MCP_POLICIES_PATH="${POLICIES_PATH}"

exec ttyd \
  --port 7681 \
  --writable \
  --once \
  "${CRED_ARGS[@]+"${CRED_ARGS[@]}"}" \
  bash -c '
    # Display login banner
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║         Vault MCP Agent — Interactive CLI            ║"
    echo "  ║   Log in with your Vault credentials to continue.   ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""

    # Start the vault-mcp-agents CLI (env vars inherited from parent)
    exec vault-mcp-agents \
      --config "${MCP_CONFIG_PATH}" \
      --policies "${MCP_POLICIES_PATH}"
  '
