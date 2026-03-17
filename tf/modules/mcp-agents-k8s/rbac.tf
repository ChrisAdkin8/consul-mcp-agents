# =============================================================================
# MCP Agents K8s Module — rbac.tf
#
# Creates Kubernetes ServiceAccounts for MCP workloads and binds them to
# the Vault Kubernetes auth roles. The ServiceAccount name must match exactly
# what is configured in vault_kubernetes_auth_backend_role.mcp_server
# (bound_service_account_names).
#
# The vault-agent sidecar uses the pod's ServiceAccount JWT to authenticate
# to Vault and obtain a Vault token. It then uses that token to:
#   1. Render /app/config/settings.yaml from Vault KV
#   2. Render /app/policies/capabilities.yaml from Vault KV
#   3. Inject ANTHROPIC_API_KEY as an environment variable
# =============================================================================

# ---------------------------------------------------------------------------
# ServiceAccounts for MCP server pods — names must match Consul service names
# for consul-connect-inject ACL token validation.
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "mcp_server" {
  for_each = local.mcp_servers

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name

    # Workload Identity annotation — each server gets its own GCP SA binding
    annotations = lookup({
      "mcp-data-server"    = { "iam.gke.io/gcp-service-account" = var.data_agent_sa_email }
      "mcp-compute-server" = { "iam.gke.io/gcp-service-account" = var.compute_agent_sa_email }
    }, each.key, {})

    labels = {
      "app.kubernetes.io/component" = "mcp-server"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }
}

# ---------------------------------------------------------------------------
# ServiceAccount for MCP agent/CLI pods (prompt layer)
# Separate SA so Vault policies can be scoped independently if needed.
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "mcp_agent" {
  metadata {
    name      = "mcp-agent"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name

    labels = {
      "app.kubernetes.io/component" = "mcp-agent"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }
}

# ---------------------------------------------------------------------------
# ClusterRoleBinding — allow Vault to verify ServiceAccount tokens
# Vault's TokenReview API call requires this permission on the SA.
# ---------------------------------------------------------------------------
resource "kubernetes_cluster_role_binding" "vault_token_review" {
  metadata {
    name = "vault-token-review-${var.namespace}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  # Agent SA
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.mcp_agent.metadata[0].name
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
  }

  # MCP server SAs
  dynamic "subject" {
    for_each = local.mcp_servers
    content {
      kind      = "ServiceAccount"
      name      = kubernetes_service_account.mcp_server[subject.key].metadata[0].name
      namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    }
  }
}
