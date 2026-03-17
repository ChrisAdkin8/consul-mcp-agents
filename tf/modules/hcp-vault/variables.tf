# =============================================================================
# HCP Vault Module — variables.tf
# =============================================================================

variable "hvn_id" {
  description = "Unique identifier for the HCP HashiCorp Virtual Network."
  type        = string
  default     = "vault-mcp-hvn"

  validation {
    condition     = var.hvn_id != ""
    error_message = "hvn_id must not be empty."
  }
}

variable "cluster_id" {
  description = "Unique identifier for the HCP Vault cluster."
  type        = string
  default     = "vault-mcp-cluster"

  validation {
    condition     = var.cluster_id != ""
    error_message = "cluster_id must not be empty."
  }
}

variable "region" {
  description = "GCP region. Kept for caller compatibility but not used in resources."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
}

variable "hvn_region" {
  description = "AWS region for the HCP HVN. HCP Vault runs on AWS; choose the region closest to your GCP workloads."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.hvn_region))
    error_message = "hvn_region must be a valid AWS region (e.g. us-east-1, eu-west-2)."
  }
}

variable "hvn_cidr" {
  description = <<-EOT
    CIDR block for the HCP HVN. Must not overlap any GCP subnet CIDRs used
    by Consul VMs (var.subnet_cidr) or GKE nodes. A /20 gives 4094 addresses,
    sufficient for HCP's internal allocation.
  EOT
  type        = string
  default     = "172.25.16.0/20"

  validation {
    condition     = can(cidrhost(var.hvn_cidr, 0))
    error_message = "hvn_cidr must be a valid CIDR block (e.g. 172.25.16.0/20)."
  }
}

variable "tier" {
  description = <<-EOT
    HCP Vault cluster tier.
    • "plus_small"   — Dedicated, Enterprise features, ~$1.58/hr
    • "plus_medium"  — Dedicated, Enterprise features, ~$3.17/hr
    • "starter_small" — Dev/test, no SLA, no Enterprise features
  EOT
  type        = string
  default     = "plus_small"

  validation {
    condition     = contains(["plus_small", "plus_medium", "plus_large", "starter_small"], var.tier)
    error_message = "tier must be one of: plus_small, plus_medium, plus_large, starter_small."
  }
}

variable "gcp_project_id" {
  description = "GCP project ID that hosts your VPC. Required for VPC peering."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "gcp_network_name" {
  description = "Name of the GCP VPC network to peer with the HVN."
  type        = string

  validation {
    condition     = var.gcp_network_name != ""
    error_message = "gcp_network_name must not be empty."
  }
}

variable "gcp_subnet_cidrs" {
  description = <<-EOT
    List of GCP subnet CIDRs to add as HVN routes after peering. Include
    all subnets that contain Consul VMs or GKE nodes so that Vault can
    reach back into your VPC (e.g. for GCP IAM auth verification).
  EOT
  type        = list(string)
  default     = ["10.128.64.0/24", "10.128.72.0/22"]

  validation {
    condition     = length(var.gcp_subnet_cidrs) > 0 && alltrue([for cidr in var.gcp_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "gcp_subnet_cidrs must be a non-empty list of valid CIDR blocks."
  }
}
