# =============================================================================
# MCP Agents K8s Module — vault-agent-config.tf
#
# Vault-agent ConfigMaps rendered from external .hcl.tpl template files:
#   1. vault-agent-agent  — for the mcp-agent pod (LLM keys, settings, policies)
#   2. vault-agent-<server> — per MCP server pod (GCP credentials), via for_each
# =============================================================================

# ---------------------------------------------------------------------------
# Agent pod vault-agent config — full config + LLM keys
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "vault_agent_agent" {
  metadata {
    name      = "vault-agent-agent"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "vault-agent"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }

  data = {
    "vault-agent.hcl" = templatefile("${path.module}/templates/vault-agent-agent.hcl.tpl", {
      vault_address  = var.vault_address
      vault_k8s_role = var.vault_k8s_agent_role
    })
  }
}

# ---------------------------------------------------------------------------
# MCP server vault-agent configs — GCP credentials only (one per server)
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "vault_agent_server" {
  for_each = local.mcp_servers

  metadata {
    name      = "vault-agent-${each.key}"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "vault-agent"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }

  data = {
    "vault-agent.hcl" = templatefile("${path.module}/templates/vault-agent-server.hcl.tpl", {
      vault_address   = var.vault_address
      vault_k8s_role  = var.vault_k8s_role
      gcp_secret_path = each.value.gcp_secret_path
      server_type     = each.value.description
    })
  }
}
