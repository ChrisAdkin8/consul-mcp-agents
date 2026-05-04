# =============================================================================
# Scenario: consul-mcp-gke — variables.tf
# =============================================================================

# ---- GCP ----
variable "gcp_project_id" {
  description = "GCP project ID for all resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "gcp_region" {
  description = "GCP region for VPC, GKE cluster, and Cloud NAT."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.gcp_region))
    error_message = "gcp_region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
}

variable "gcp_zone" {
  description = "GCP zone for Consul server VMs."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.gcp_zone))
    error_message = "gcp_zone must be a valid GCP zone (e.g. us-central1-a, europe-west4-b)."
  }
}

variable "environment" {
  description = "Deployment environment tag applied to all resources (dev/staging/prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "artifact_registry_repo" {
  description = "Artifact Registry repository name for the MCP agent Docker image."
  type        = string
  default     = "vault-mcp"

  validation {
    condition     = var.artifact_registry_repo != ""
    error_message = "artifact_registry_repo must not be empty."
  }
}

# ---- HCP ----
variable "hcp_client_id" {
  description = "HCP service principal client ID. Create in HCP portal → Access control → Service principals."
  type        = string
  sensitive   = true

  validation {
    condition     = var.hcp_client_id != ""
    error_message = "hcp_client_id must not be empty."
  }
}

variable "hcp_client_secret" {
  description = "HCP service principal client secret."
  type        = string
  sensitive   = true

  validation {
    condition     = var.hcp_client_secret != ""
    error_message = "hcp_client_secret must not be empty."
  }
}

variable "hcp_hvn_cidr" {
  description = "CIDR for the HCP HVN. Must not overlap var.subnet_cidr, var.pods_cidr, or var.services_cidr."
  type        = string
  default     = "172.25.16.0/20"

  validation {
    condition     = can(cidrhost(var.hcp_hvn_cidr, 0))
    error_message = "hcp_hvn_cidr must be a valid CIDR block (e.g. 172.25.16.0/20)."
  }
}

variable "hcp_vault_tier" {
  description = "HCP Vault cluster tier (plus_small recommended for production)."
  type        = string
  default     = "plus_small"

  validation {
    condition     = contains(["plus_small", "plus_medium", "plus_large", "starter_small"], var.hcp_vault_tier)
    error_message = "hcp_vault_tier must be one of: plus_small, plus_medium, plus_large, starter_small."
  }
}

variable "vault_address_override" {
  description = "Override the Vault address used by the Vault provider. Leave empty to use HCP public endpoint."
  type        = string
  default     = ""

  validation {
    condition     = var.vault_address_override == "" || can(regex("^https://", var.vault_address_override))
    error_message = "vault_address_override must be empty or start with https://."
  }
}

# ---- Network ----
variable "subnet_cidr" {
  description = "Primary subnet CIDR for Consul VMs and GKE nodes."
  type        = string
  default     = "10.128.64.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block (e.g. 10.128.64.0/24)."
  }
}

variable "pods_cidr" {
  description = "Secondary range CIDR for GKE pods."
  type        = string
  default     = "10.128.72.0/22"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid CIDR block (e.g. 10.128.72.0/22)."
  }
}

variable "services_cidr" {
  description = "Secondary range CIDR for GKE services."
  type        = string
  default     = "10.128.69.0/24"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid CIDR block (e.g. 10.128.69.0/24)."
  }
}

# ---- Consul ----
variable "datacenter" {
  description = "Consul datacenter name."
  type        = string
  default     = "dc1"

  validation {
    condition     = var.datacenter != ""
    error_message = "datacenter must not be empty."
  }
}

variable "consul_address_override" {
  description = "Override the Consul provider address. Use 'localhost:18501' when accessing via IAP tunnel. Leave empty to use the first Consul server's internal IP."
  type        = string
  default     = ""
}

variable "consul_instance_count" {
  description = "Number of Consul server VMs."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5], var.consul_instance_count)
    error_message = "consul_instance_count must be 1, 3, or 5 (Raft quorum requirements)."
  }
}

variable "consul_bootstrap_token" {
  description = "Consul ACL bootstrap token (UUID). Generated by: task token:ensure"
  type        = string
  sensitive   = true

  validation {
    condition     = var.consul_bootstrap_token != ""
    error_message = "consul_bootstrap_token must not be empty."
  }
}

# ---- GKE phase gate ----
variable "gke_cluster_ready" {
  description = "Set to true once the GKE cluster has been created (phase 2+). Enables kubernetes/helm resources and auto-discovers the cluster endpoint via GCP data source. Leave false during initial cluster creation."
  type        = bool
  default     = false
}

variable "gke_cluster_private_endpoint" {
  description = "GKE cluster private API endpoint (for Consul VM k8s auth method). Reachable from VMs in the same VPC. Fill in after phase 1 apply."
  type        = string
  default     = ""
}

variable "token_reviewer_jwt" {
  description = <<-EOT
    Override for the vault-reviewer JWT. Normally left empty — the SA and token
    are created by Terraform (kubernetes_secret.vault_reviewer_token) and wired
    automatically. Set this only when importing an existing token or recovering
    from a cluster rebuild before Terraform has created the SA.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# ---- GKE ----
variable "gke_cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "vault-mcp-cluster"

  validation {
    condition     = var.gke_cluster_name != ""
    error_message = "gke_cluster_name must not be empty."
  }
}

variable "gke_node_count" {
  description = "Number of GKE worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.gke_node_count >= 1 && var.gke_node_count <= 100
    error_message = "gke_node_count must be between 1 and 100."
  }
}

variable "gke_machine_type" {
  description = "Machine type for GKE worker nodes."
  type        = string
  default     = "e2-standard-4"

  validation {
    condition     = var.gke_machine_type != ""
    error_message = "gke_machine_type must not be empty."
  }
}

variable "gke_master_cidr" {
  description = "CIDR for GKE master private endpoint."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.gke_master_cidr, 0))
    error_message = "gke_master_cidr must be a valid CIDR block (e.g. 172.16.0.0/28)."
  }
}

variable "gke_authorized_cidrs" {
  description = "Additional CIDRs allowed to reach the GKE API server (e.g. operator workstation IPs). Only applied when gke_enable_master_authorized_networks = true. 0.0.0.0/0 is rejected."
  type = list(object({
    cidr = string
    name = string
  }))
  default = []

  validation {
    condition     = !contains([for c in var.gke_authorized_cidrs : c.cidr], "0.0.0.0/0")
    error_message = "gke_authorized_cidrs must not contain 0.0.0.0/0. Specify explicit operator and HCP Vault CIDRs."
  }
}

variable "gke_enable_master_authorized_networks" {
  description = "Restrict GKE master endpoint to gke_authorized_cidrs + internal subnet. Default false: HCP Vault Public Tier has no stable egress IPs to allowlist, and no HVN→VPC peering exists, so vault-agent-init pods can't auth when restricted. See CLAUDE.md 'Architectural gap: HCP Vault → GKE master access'."
  type        = bool
  default     = false
}

variable "gke_deletion_protection" {
  description = "Block terraform destroy on the GKE cluster. Set to false only for dev environments."
  type        = bool
  default     = true
}

variable "gke_database_encryption_key" {
  description = "Cloud KMS key resource name for GKE Application-layer Secrets Encryption (CIS 8.5.5). Empty string disables (default Google encryption applies)."
  type        = string
  default     = ""

  validation {
    condition     = var.gke_database_encryption_key == "" || can(regex("^projects/.+/locations/.+/keyRings/.+/cryptoKeys/.+$", var.gke_database_encryption_key))
    error_message = "gke_database_encryption_key must be empty or a full KMS key resource name (projects/.../cryptoKeys/...)."
  }
}

variable "consul_config_force_destroy" {
  description = "Allow Terraform to delete the Consul config GCS bucket even when it contains objects. Set to false for staging/prod."
  type        = bool
  default     = true
}

variable "helm_chart_version" {
  description = "Consul Helm chart version."
  type        = string
  default     = "1.9.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+", var.helm_chart_version))
    error_message = "helm_chart_version must be a valid semantic version (e.g. 1.9.2)."
  }
}

# ---- Vault ----
variable "vault_root_pki_path" {
  description = "Mount path for the Root CA PKI engine in Vault."
  type        = string
  default     = "connect-root"

  validation {
    condition     = var.vault_root_pki_path != ""
    error_message = "vault_root_pki_path must not be empty."
  }
}

variable "vault_intermediate_pki_path" {
  description = "Mount path for the Intermediate CA PKI engine in Vault."
  type        = string
  default     = "connect-intermediate"

  validation {
    condition     = var.vault_intermediate_pki_path != ""
    error_message = "vault_intermediate_pki_path must not be empty."
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

# ---- LLM ----
variable "llm_provider" {
  description = "LLM provider for MCP agents: anthropic or openai."
  type        = string
  default     = "anthropic"

  validation {
    condition     = contains(["anthropic", "openai"], var.llm_provider)
    error_message = "llm_provider must be 'anthropic' or 'openai'."
  }
}

variable "llm_model" {
  description = "LLM model ID."
  type        = string
  default     = "claude-sonnet-4-6"

  validation {
    condition     = var.llm_model != ""
    error_message = "llm_model must not be empty."
  }
}

variable "anthropic_api_key" {
  description = "Anthropic API key. Stored in Vault KV, never in K8s manifests."
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

# ---- MCP Agents ----
variable "mcp_replicas" {
  description = "Number of MCP agent pod replicas (= concurrent user capacity)."
  type        = number
  default     = 2

  validation {
    condition     = var.mcp_replicas >= 1 && var.mcp_replicas <= 50
    error_message = "mcp_replicas must be between 1 and 50."
  }
}

variable "mcp_image_tag" {
  description = "Docker image tag for the vault-mcp-agents application."
  type        = string
  default     = "latest"

  validation {
    condition     = var.mcp_image_tag != ""
    error_message = "mcp_image_tag must not be empty."
  }
}

variable "mcp_ttyd_credential" {
  description = "Basic auth credential for the ttyd web terminal (user:password). Must be set explicitly."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^:]+:.+$", var.mcp_ttyd_credential))
    error_message = "mcp_ttyd_credential must be in user:password format and must not be empty."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the MCP agents LoadBalancer. Must be set explicitly — 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
    error_message = "allowed_ingress_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "vault_users" {
  description = "Vault userpass users to create. Key = username. Must be set explicitly — no default credentials."
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
