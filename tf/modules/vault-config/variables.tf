# =============================================================================
# Vault Config Module — variables.tf
# =============================================================================

variable "gcp_project_id" {
  description = "GCP project ID for all GCP resources in this module."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "gcp_region" {
  description = "GCP region used for constructing the GKE OIDC issuer URL."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.gcp_region))
    error_message = "gcp_region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
}

variable "gcp_secrets_mount_path" {
  description = "Mount path for the Vault GCP secrets engine."
  type        = string
  default     = "gcp"

  validation {
    condition     = var.gcp_secrets_mount_path != ""
    error_message = "gcp_secrets_mount_path must not be empty."
  }
}

variable "vault_sa_id" {
  description = "Service account ID for the Vault GCP secrets engine impersonator SA."
  type        = string
  default     = "vault-gcp-impersonator"

  validation {
    condition     = var.vault_sa_id != ""
    error_message = "vault_sa_id must not be empty."
  }
}

variable "vault_private_endpoint_url" {
  description = "Private endpoint URL of the HCP Vault cluster (used in rendered config)."
  type        = string

  validation {
    condition     = can(regex("^https://", var.vault_private_endpoint_url))
    error_message = "vault_private_endpoint_url must start with https:// (e.g. https://vault-cluster.private.vault.hashicorp.cloud:8200)."
  }
}

variable "llm_provider" {
  description = "LLM provider: 'anthropic' or 'openai'."
  type        = string
  default     = "anthropic"

  validation {
    condition     = contains(["anthropic", "openai"], var.llm_provider)
    error_message = "llm_provider must be 'anthropic' or 'openai'."
  }
}

variable "llm_model" {
  description = "LLM model identifier passed to the LangChain agent."
  type        = string
  default     = "claude-sonnet-4-6"

  validation {
    condition     = var.llm_model != ""
    error_message = "llm_model must not be empty."
  }
}

variable "anthropic_api_key" {
  description = "Anthropic API key. Stored in Vault KV — never in K8s ConfigMaps or env."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key. Only required if llm_provider = 'openai'."
  type        = string
  sensitive   = true
  default     = ""
}

variable "consul_bootstrap_token" {
  description = <<-EOT
    Consul ACL bootstrap token. Set initially to the UUID from the Taskfile
    bootstrap step, then updated to the real token after `consul acl bootstrap`.
    Stored in Vault KV secret/consul/acl-token.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = var.consul_bootstrap_token != ""
    error_message = "consul_bootstrap_token must not be empty."
  }
}

variable "gke_endpoint" {
  description = <<-EOT
    GKE cluster API server URL (e.g. https://1.2.3.4). Required for the
    Kubernetes auth backend config. Populated after GKE apply in the Taskfile.
    Leave as empty string during the initial apply; the Taskfile handles
    sequencing via vault:configure-k8s-auth.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.gke_endpoint == "" || can(regex("^https://", var.gke_endpoint))
    error_message = "gke_endpoint must be empty or start with https:// (e.g. https://1.2.3.4)."
  }
}

variable "gke_ca_certificate" {
  description = <<-EOT
    Base64-decoded GKE cluster CA certificate PEM. Used by Vault to verify
    ServiceAccount JWTs during Kubernetes auth. Populated after GKE apply.
  EOT
  type        = string
  default     = ""
}

variable "token_reviewer_jwt" {
  description = <<-EOT
    Long-lived K8s ServiceAccount token for a SA bound to system:auth-delegator.
    Vault uses this to call the TokenReview API when validating pod SA JWTs.
    Required for external Vault (HCP Vault) with GKE Workload Identity enabled,
    because WI-issued tokens can't be used as bearer auth to call the K8s API.
    Create via: kubectl create sa vault-reviewer -n kube-system
                kubectl create clusterrolebinding vault-reviewer --clusterrole=system:auth-delegator --serviceaccount=kube-system:vault-reviewer
    Leave empty to omit the field (relies on Vault calling TokenReview with the
    submitted JWT itself, which fails when WI is enabled).
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "gke_cluster_name" {
  description = "GKE cluster name — used in the OIDC issuer URL."
  type        = string
  default     = "vault-mcp-cluster"

  validation {
    condition     = var.gke_cluster_name != ""
    error_message = "gke_cluster_name must not be empty."
  }
}

variable "mcp_namespace" {
  description = "Kubernetes namespace where MCP agent pods run."
  type        = string
  default     = "mcp-agents"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.mcp_namespace))
    error_message = "mcp_namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, starting with alphanumeric)."
  }
}

variable "vault_users" {
  description = <<-EOT
    Map of Vault userpass users to create. Key = username.
    Value = { password = string, policies = list(string) }
    Must be set explicitly — no default credentials in code.
  EOT
  type = map(object({
    password = string
    policies = list(string)
  }))
  sensitive = true

  validation {
    condition     = length(var.vault_users) > 0
    error_message = "vault_users must contain at least one user."
  }
}
