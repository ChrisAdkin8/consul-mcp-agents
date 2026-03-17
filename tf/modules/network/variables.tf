# =============================================================================
# Network Module — variables.tf
# =============================================================================

variable "project_id" {
  description = "GCP project ID."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens, starts with a letter)."
  }
}

variable "name_prefix" {
  description = "Prefix applied to all network resource names (e.g. 'mcp-dc1')."
  type        = string

  validation {
    condition     = var.name_prefix != ""
    error_message = "name_prefix must not be empty."
  }
}

variable "region" {
  description = "GCP region for subnets, router, and NAT."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
}

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
  description = "Secondary range CIDR for GKE pod IPs (VPC-native mode)."
  type        = string
  default     = "10.128.72.0/22"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid CIDR block (e.g. 10.128.72.0/22)."
  }
}

variable "services_cidr" {
  description = "Secondary range CIDR for GKE service IPs (VPC-native mode)."
  type        = string
  default     = "10.128.69.0/24"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid CIDR block (e.g. 10.128.69.0/24)."
  }
}

variable "gke_master_cidr" {
  description = <<-EOT
    CIDR block for GKE master (control plane) nodes. Used in the firewall
    rule that allows the master to reach worker nodes. GKE assigns this CIDR
    automatically when the cluster is private — use the cluster output value.
    Default covers the most common private endpoint range.
  EOT
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.gke_master_cidr, 0))
    error_message = "gke_master_cidr must be a valid CIDR block (e.g. 172.16.0.0/28)."
  }
}
