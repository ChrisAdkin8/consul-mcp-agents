# =============================================================================
# Consul Module — variables.tf
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
  description = "Prefix for all resource names."
  type        = string

  validation {
    condition     = var.name_prefix != ""
    error_message = "name_prefix must not be empty."
  }
}

variable "zone" {
  description = "GCP zone for Consul server VMs."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "zone must be a valid GCP zone (e.g. us-central1-a, europe-west4-b)."
  }
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region (e.g. us-central1, europe-west4)."
  }
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

variable "instance_count" {
  description = "Number of Consul server VMs. Use 1 for dev/demo, 3 or 5 for production."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5], var.instance_count)
    error_message = "instance_count must be 1, 3, or 5 (Raft quorum requirements)."
  }
}

variable "machine_type" {
  description = "GCE machine type for Consul server VMs."
  type        = string
  default     = "e2-standard-4"

  validation {
    condition     = var.machine_type != ""
    error_message = "machine_type must not be empty."
  }
}

variable "consul_image_family" {
  description = "Packer-built image family for Consul server VMs."
  type        = string
  default     = "almalinux-consul-server-vault"

  validation {
    condition     = var.consul_image_family != ""
    error_message = "consul_image_family must not be empty."
  }
}

variable "subnet_self_link" {
  description = "Self-link of the subnet to attach Consul VMs to."
  type        = string

  validation {
    condition     = var.subnet_self_link != ""
    error_message = "subnet_self_link must not be empty."
  }
}

variable "vault_private_endpoint_url" {
  description = "Private endpoint URL of the HCP Vault cluster, passed to vault-agent on each VM."
  type        = string

  validation {
    condition     = can(regex("^https://", var.vault_private_endpoint_url))
    error_message = "vault_private_endpoint_url must start with https:// (e.g. https://vault-cluster.private.vault.hashicorp.cloud:8200)."
  }
}

variable "vault_root_pki_path" {
  description = "Mount path of the Root CA PKI engine in Vault."
  type        = string
  default     = "connect-root"

  validation {
    condition     = var.vault_root_pki_path != ""
    error_message = "vault_root_pki_path must not be empty."
  }
}

variable "vault_intermediate_pki_path" {
  description = "Mount path of the Intermediate CA PKI engine in Vault."
  type        = string
  default     = "connect-intermediate"

  validation {
    condition     = var.vault_intermediate_pki_path != ""
    error_message = "vault_intermediate_pki_path must not be empty."
  }
}

variable "gcs_bucket" {
  description = "GCS bucket name that holds consul.hclic and consul-server.hcl for startup."
  type        = string

  validation {
    condition     = var.gcs_bucket != ""
    error_message = "gcs_bucket must not be empty."
  }
}

variable "consul_server_sa_email" {
  description = "Email of the GCP service account to attach to Consul server VMs. Must already exist and be bound to the Vault GCP auth role."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.consul_server_sa_email))
    error_message = "consul_server_sa_email must be a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}
