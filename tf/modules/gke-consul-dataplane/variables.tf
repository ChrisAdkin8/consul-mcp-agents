# =============================================================================
# GKE Consul Dataplane Module — variables.tf
# =============================================================================

variable "project_id" {
  description = "GCP project ID."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "region" {
  description = "GCP region for the GKE cluster."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
}

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "vault-mcp-cluster"

  validation {
    condition     = var.cluster_name != ""
    error_message = "cluster_name must not be empty."
  }
}

variable "machine_type" {
  description = "GCE machine type for GKE worker nodes."
  type        = string
  default     = "e2-standard-4"

  validation {
    condition     = var.machine_type != ""
    error_message = "machine_type must not be empty."
  }
}

variable "node_count" {
  description = "Number of worker nodes per region (regional cluster = 3× this value)."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 100
    error_message = "node_count must be between 1 and 100."
  }
}

variable "network_self_link" {
  description = "Self-link of the VPC network."
  type        = string

  validation {
    condition     = var.network_self_link != ""
    error_message = "network_self_link must not be empty."
  }
}

variable "subnet_self_link" {
  description = "Self-link of the primary subnet for GKE nodes."
  type        = string

  validation {
    condition     = var.subnet_self_link != ""
    error_message = "subnet_self_link must not be empty."
  }
}

variable "subnet_cidr" {
  description = "Primary subnet CIDR — added to master authorized networks."
  type        = string

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid CIDR block (e.g. 10.128.64.0/24)."
  }
}

variable "pods_range_name" {
  description = "Name of the secondary IP range for pods."
  type        = string

  validation {
    condition     = var.pods_range_name != ""
    error_message = "pods_range_name must not be empty."
  }
}

variable "services_range_name" {
  description = "Name of the secondary IP range for services."
  type        = string

  validation {
    condition     = var.services_range_name != ""
    error_message = "services_range_name must not be empty."
  }
}

variable "master_cidr" {
  description = "CIDR block for the GKE master (private) endpoint."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.master_cidr, 0))
    error_message = "master_cidr must be a valid CIDR block (e.g. 172.16.0.0/28)."
  }
}

variable "authorized_networks" {
  description = "Additional CIDR blocks allowed to reach the GKE API server."
  type = list(object({
    cidr = string
    name = string
  }))
  default = []
}

variable "datacenter" {
  description = "Consul datacenter name."
  type        = string
  default     = "dc1"

  validation {
    condition     = var.datacenter != ""
    error_message = "datacenter must not be empty."
  }
}

variable "consul_internal_address" {
  description = "Internal IP of the external Consul server (reachable from GKE pods)."
  type        = string

  validation {
    condition     = var.consul_internal_address != ""
    error_message = "consul_internal_address must not be empty."
  }
}

variable "gke_endpoint" {
  description = "GKE API server public endpoint — used for kubeconfig."
  type        = string
  default     = ""
}

variable "gke_private_endpoint" {
  description = "GKE API server private endpoint — used for Consul k8sAuthMethodHost (reachable from VMs in the same VPC)."
  type        = string
  default     = ""
}

variable "consul_bootstrap_token" {
  description = "Consul ACL bootstrap token. Stored as a K8s secret for the Helm chart."
  type        = string
  sensitive   = true

  validation {
    condition     = var.consul_bootstrap_token != ""
    error_message = "consul_bootstrap_token must not be empty."
  }
}

variable "vault_ca_chain_pem" {
  description = "PEM certificate chain (Intermediate + Root CA) from Vault PKI. Used by Consul for TLS."
  type        = string

  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----", var.vault_ca_chain_pem))
    error_message = "vault_ca_chain_pem must be a valid PEM certificate chain containing at least one BEGIN CERTIFICATE block."
  }
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

variable "enable_service_mesh" {
  description = "Enable Consul Connect sidecar injection."
  type        = bool
  default     = true
}

variable "enable_ingress_gateway" {
  description = "Deploy a Consul ingress gateway LoadBalancer."
  type        = bool
  default     = true
}

variable "mcp_namespace" {
  description = "Kubernetes namespace for MCP agent pods (for Workload Identity binding)."
  type        = string
  default     = "mcp-agents"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.mcp_namespace))
    error_message = "mcp_namespace must be a valid Kubernetes namespace name (lowercase alphanumeric and hyphens, starting with alphanumeric)."
  }
}

variable "data_agent_sa_name" {
  description = "Full resource name of the data-agent GCP SA (for Workload Identity binding)."
  type        = string

  validation {
    condition     = var.data_agent_sa_name != ""
    error_message = "data_agent_sa_name must not be empty."
  }
}

variable "compute_agent_sa_name" {
  description = "Full resource name of the compute-agent GCP SA (for Workload Identity binding)."
  type        = string

  validation {
    condition     = var.compute_agent_sa_name != ""
    error_message = "compute_agent_sa_name must not be empty."
  }
}

variable "deletion_protection" {
  description = "Block terraform destroy on the GKE cluster. Set to false only for dev."
  type        = bool
  default     = true
}

variable "release_channel" {
  description = "GKE release channel for control plane and node auto-upgrades."
  type        = string
  default     = "STABLE"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "UNSPECIFIED"], var.release_channel)
    error_message = "release_channel must be one of: RAPID, REGULAR, STABLE, UNSPECIFIED."
  }
}

variable "database_encryption_key" {
  description = "Cloud KMS key resource name for Application-layer Secrets Encryption. Empty string disables."
  type        = string
  default     = ""
}

variable "enable_master_authorized_networks" {
  description = <<-EOT
    Restrict GKE master endpoint access to specific CIDRs. When true, only
    `subnet_cidr` (internal) plus `authorized_networks` can reach the API
    server. When false (default), the master is reachable from any source.

    Default false because HCP Vault Public Tier has no stable egress IPs to
    allowlist, and no HVN→VPC peering with route to the GKE master CIDR is
    configured by this scenario. Vault's K8s auth (TokenReview API call) would
    fail under restricted master_authorized_networks. Set true once you have
    either added HCP egress CIDRs to `authorized_networks` or stood up
    HVN→VPC peering and switched `kubernetes_host` to the private endpoint.
  EOT
  type        = bool
  default     = false
}

variable "ingress_gateway_source_ranges" {
  description = "CIDR ranges allowed to reach the Consul ingress gateway LoadBalancer. Must be set when enable_ingress_gateway=true."
  type        = list(string)
  default     = []
}
