# =============================================================================
# Vault Config Module — auth-k8s.tf
#
# Configures the Vault Kubernetes auth method so GKE pods can authenticate
# to Vault without static credentials. Each pod's K8s ServiceAccount JWT is
# validated against the GKE API server — if the JWT is valid and the SA name
# matches the role's bound_service_account_names, Vault issues a token.
#
# This file also defines the roles that MCP agent pods use:
#   mcp-server — for MCP server pods (data_server, compute_server)
#   mcp-agent  — for the agent orchestrator / CLI pods (if separated)
#
# NOTE: The K8s auth backend config (jwt_validation_pubkeys / kubernetes_host)
# cannot be applied until the GKE cluster exists. The Taskfile runs:
#   task vault:configure-k8s-auth
# as a separate step after `terraform apply -target=module.gke`.
# =============================================================================

# ---------------------------------------------------------------------------
# Kubernetes auth backend
# ---------------------------------------------------------------------------
resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  path        = "kubernetes"
  description = "Kubernetes auth for GKE pods — validates ServiceAccount JWTs against the GKE API"
}

# ---------------------------------------------------------------------------
# K8s auth backend configuration
#
# kubernetes_host     — GKE cluster API endpoint (filled in by Taskfile post-GKE)
# kubernetes_ca_cert  — GKE cluster CA certificate (base64-decoded PEM)
# token_reviewer_jwt  — Long-lived JWT for Vault to call TokenReview API
#
# Uses a terraform_data resource to allow deferred configuration:
# the null-equivalent resource is replaced by `vault write` in the Taskfile.
# ---------------------------------------------------------------------------
resource "vault_kubernetes_auth_backend_config" "main" {
  count = var.gke_endpoint != "" ? 1 : 0

  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.gke_endpoint
  kubernetes_ca_cert = var.gke_ca_certificate

  # token_reviewer_jwt: long-lived SA token for a SA bound to system:auth-delegator.
  # Required for HCP Vault (external) + GKE Workload Identity: WI tokens use a
  # different audience than the K8s API server and cannot be used as bearer auth
  # to call the TokenReview API. This dedicated reviewer JWT authenticates Vault
  # to K8s so it can validate the pod's projected SA token (audience="vault").
  token_reviewer_jwt = var.token_reviewer_jwt != "" ? var.token_reviewer_jwt : null

  issuer = "https://container.googleapis.com/v1/projects/${var.gcp_project_id}/locations/${var.gcp_region}/clusters/${var.gke_cluster_name}"

  disable_iss_validation = true
  disable_local_ca_jwt   = true
}

# ---------------------------------------------------------------------------
# MCP server role — for data_server and compute_server pods
#
# These pods need to:
#   • Read Vault KV (settings.yaml, capabilities.yaml, llm-keys)
#   • Call the GCP secrets engine to get 5-minute OAuth2 tokens
# ---------------------------------------------------------------------------
resource "vault_kubernetes_auth_backend_role" "mcp_server" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "mcp-server"
  bound_service_account_names      = ["mcp-server", "mcp-data-server", "mcp-compute-server"]
  bound_service_account_namespaces = [var.mcp_namespace]
  token_ttl                        = 3600 # vault-agent renews automatically
  token_max_ttl                    = 86400
  token_policies = [
    vault_policy.mcp_server.name,
    "default",
  ]
  # audience omitted — TokenReview validates the SA identity; no separate
  # audience claim check needed when using external token_reviewer_jwt.
}

# ---------------------------------------------------------------------------
# MCP agent role — for the CLI / prompt pod (separate from MCP servers)
# Needs userpass auth passthrough (handled by the app, not Vault agent)
# ---------------------------------------------------------------------------
resource "vault_kubernetes_auth_backend_role" "mcp_agent" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "mcp-agent"
  bound_service_account_names      = ["mcp-agent"]
  bound_service_account_namespaces = [var.mcp_namespace]
  token_ttl                        = 3600
  token_max_ttl                    = 86400
  token_policies = [
    vault_policy.mcp_server.name,
    "default",
  ]
}

# ---------------------------------------------------------------------------
# Policy for MCP server pods
# ---------------------------------------------------------------------------
resource "vault_policy" "mcp_server" {
  name = "mcp-server-policy"

  policy = <<-EOT
    # ---- KV: read application configuration ----
    path "secret/data/mcp-agents/config" {
      capabilities = ["read"]
    }

    path "secret/data/mcp-agents/policies" {
      capabilities = ["read"]
    }

    # ---- KV: read LLM API keys (injected as env vars by vault-agent) ----
    path "secret/data/mcp-agents/llm-keys" {
      capabilities = ["read"]
    }

    # ---- GCP secrets engine: generate 5-minute OAuth2 tokens ----
    path "${var.gcp_secrets_mount_path}/impersonated-account/data-agent-gcp/token" {
      capabilities = ["read"]
    }

    path "${var.gcp_secrets_mount_path}/impersonated-account/compute-agent-gcp/token" {
      capabilities = ["read"]
    }

    # ---- Consul ACL token: read for service registration ----
    path "secret/data/consul/acl-token" {
      capabilities = ["read"]
    }

    # ---- Token self-management ----
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}
