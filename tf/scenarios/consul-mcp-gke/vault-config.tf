# =============================================================================
# Scenario: consul-mcp-gke — vault-config.tf
# Layer 4a: Vault application config (KV, GCP engine, userpass, K8s auth)
# Depends on: module.vault_pki (PKI must exist for GCP auth to be configured)
#
# vault-reviewer: dedicated K8s ServiceAccount in kube-system that Vault uses
# to call the TokenReview API when validating pod SA JWTs. Required for HCP
# Vault (external) + GKE because Workload Identity tokens use a different
# audience than the K8s API server. Created here so it's managed as code;
# the long-lived token secret is passed directly to vault_config.
# =============================================================================

# ---------------------------------------------------------------------------
# vault-reviewer ServiceAccount — Vault calls K8s TokenReview with this JWT
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "vault_reviewer" {
  count = local.cluster_endpoint != "" ? 1 : 0

  metadata {
    name      = "vault-reviewer"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_cluster_role_binding" "vault_reviewer" {
  count = local.cluster_endpoint != "" ? 1 : 0

  metadata {
    name = "vault-reviewer"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault_reviewer[0].metadata[0].name
    namespace = "kube-system"
  }
}

# Long-lived SA token — Kubernetes rotates projected tokens; this Secret-based
# token has no expiry and remains valid as long as the SA exists.
resource "kubernetes_secret" "vault_reviewer_token" {
  count = local.cluster_endpoint != "" ? 1 : 0

  metadata {
    name      = "vault-reviewer-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.vault_reviewer[0].metadata[0].name
    }
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account.vault_reviewer]
}

# ---------------------------------------------------------------------------
# Vault application config module
# ---------------------------------------------------------------------------
module "vault_config" {
  source = "../../modules/vault-config"

  gcp_project_id             = var.gcp_project_id
  gcp_region                 = var.gcp_region
  gcp_secrets_mount_path     = var.gcp_secrets_mount_path
  vault_private_endpoint_url = module.hcp_vault.vault_private_endpoint_url
  llm_provider               = var.llm_provider
  llm_model                  = var.llm_model
  anthropic_api_key          = var.anthropic_api_key
  openai_api_key             = var.openai_api_key
  consul_bootstrap_token     = var.consul_bootstrap_token
  gke_cluster_name           = var.gke_cluster_name
  mcp_namespace              = local.mcp_namespace
  vault_users                = var.vault_users

  # GKE details — populated from data source once gke_cluster_ready = true
  gke_endpoint       = local.cluster_endpoint != "" ? "https://${local.cluster_endpoint}" : ""
  gke_ca_certificate = local.cluster_ca_cert != "" ? base64decode(local.cluster_ca_cert) : ""

  # Use the Terraform-managed reviewer token; fall back to tfvars override if set.
  token_reviewer_jwt = (
    local.cluster_endpoint != "" && length(kubernetes_secret.vault_reviewer_token) > 0
    ? kubernetes_secret.vault_reviewer_token[0].data["token"]
    : var.token_reviewer_jwt
  )

  depends_on = [
    module.vault_pki,
    kubernetes_secret.vault_reviewer_token,
  ]
}
