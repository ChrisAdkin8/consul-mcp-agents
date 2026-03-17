# =============================================================================
# MCP Agents K8s Module — namespace.tf
#
# Creates the dedicated namespace for MCP agent workloads with appropriate
# labels for Consul service mesh injection and Vault agent injection.
# =============================================================================

resource "kubernetes_namespace" "mcp_agents" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by"        = "terraform"
      "app.kubernetes.io/part-of"           = "vault-mcp-agents"
      "consul.hashicorp.com/connect-inject" = "true"
      "vault.hashicorp.com/agent-inject"    = "true"
    }

    annotations = {
      "description" = "Namespace for Vault-secured MCP AI agents — GCS/BigQuery/GCE tools"
    }
  }
}
