# =============================================================================
# MCP Agents K8s Module — secret.tf
#
# Kubernetes Secrets for sensitive values that must reach pods without being
# rendered in the deployment spec (kubectl describe pod, audit logs).
# =============================================================================

# ttyd basic auth credential — referenced via secret_key_ref in deployment.tf
# rather than as a plain env value, so the credential never appears in
# `kubectl describe pod` output.
resource "kubernetes_secret" "ttyd_credential" {
  metadata {
    name      = "ttyd-credential"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "vault-mcp-agents"
    }
  }

  type = "Opaque"

  data = {
    credential = var.ttyd_credential
  }
}
