# =============================================================================
# MCP Agents K8s Module — variables.tf
# =============================================================================

variable "namespace" {
  description = "Kubernetes namespace to deploy MCP agent pods into."
  type        = string
  default     = "mcp-agents"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.namespace))
    error_message = "namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, starting with alphanumeric)."
  }
}

variable "replicas" {
  description = "Number of MCP agent pod replicas. Each replica handles one concurrent terminal session."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1 && var.replicas <= 50
    error_message = "replicas must be between 1 and 50."
  }
}

variable "app_image_repository" {
  description = "Container image repository for the vault-mcp-agents application."
  type        = string
  # e.g. "us-central1-docker.pkg.dev/my-project/vault-mcp/vault-mcp-agents"

  validation {
    condition     = var.app_image_repository != ""
    error_message = "app_image_repository must not be empty."
  }
}

variable "app_image_tag" {
  description = "Container image tag for the vault-mcp-agents application."
  type        = string
  default     = "latest"

  validation {
    condition     = var.app_image_tag != ""
    error_message = "app_image_tag must not be empty."
  }
}

variable "vault_address" {
  description = "Vault address for in-pod env var. Use the private endpoint for in-cluster access."
  type        = string

  validation {
    condition     = can(regex("^https://", var.vault_address))
    error_message = "vault_address must start with https:// (e.g. https://vault-cluster.private.vault.hashicorp.cloud:8200)."
  }
}

variable "vault_k8s_role" {
  description = "Vault Kubernetes auth role name for the mcp-server ServiceAccount."
  type        = string
  default     = "mcp-server"

  validation {
    condition     = var.vault_k8s_role != ""
    error_message = "vault_k8s_role must not be empty."
  }
}

variable "vault_k8s_agent_role" {
  description = "Vault Kubernetes auth role name for the mcp-agent ServiceAccount."
  type        = string
  default     = "mcp-agent"

  validation {
    condition     = var.vault_k8s_agent_role != ""
    error_message = "vault_k8s_agent_role must not be empty."
  }
}

variable "vault_agent_version" {
  description = "Vault version for the vault-agent init container image."
  type        = string
  default     = "1.21.3"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+", var.vault_agent_version))
    error_message = "vault_agent_version must be a valid semantic version (e.g. 1.19.0)."
  }
}

variable "gcp_project_id" {
  description = "GCP project ID injected as an env var into MCP pods."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "data_agent_sa_email" {
  description = "Email of the data-agent GCP SA for Workload Identity annotation."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.data_agent_sa_email))
    error_message = "data_agent_sa_email must be a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}

variable "compute_agent_sa_email" {
  description = "Email of the compute-agent GCP SA for Workload Identity annotation."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.compute_agent_sa_email))
    error_message = "compute_agent_sa_email must be a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}

variable "ttyd_credential" {
  description = <<-EOT
    Basic auth credential for the ttyd web terminal in the format "user:password".
    This is a first line of defence only — use Cloud IAP for production access control.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^:]+:.+$", var.ttyd_credential))
    error_message = "ttyd_credential must be in user:password format and must not be empty."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDR ranges allowed to reach the MCP agents LoadBalancer. Must be explicitly set — no default."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
    error_message = "allowed_ingress_cidrs must be non-empty and must not contain 0.0.0.0/0. Specify explicit CIDR ranges."
  }
}
