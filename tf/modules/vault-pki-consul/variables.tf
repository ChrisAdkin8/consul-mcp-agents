# =============================================================================
# Vault PKI for Consul Module — variables.tf
# =============================================================================

variable "vault_addr" {
  description = <<-EOT
    Base URL of the Vault cluster, used to construct CRL distribution point
    and OCSP URLs embedded in issued certificates. Use the private endpoint
    URL from the hcp-vault module output.
    Example: "https://vault-cluster.private.vault.hashicorp.cloud:8200"
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://", var.vault_addr))
    error_message = "vault_addr must start with https:// (e.g. https://vault-cluster.private.vault.hashicorp.cloud:8200)."
  }
}

variable "root_pki_path" {
  description = "Mount path for the Root CA PKI secrets engine."
  type        = string
  default     = "connect-root"

  validation {
    condition     = var.root_pki_path != ""
    error_message = "root_pki_path must not be empty."
  }
}

variable "intermediate_pki_path" {
  description = "Mount path for the Intermediate CA PKI secrets engine."
  type        = string
  default     = "connect-intermediate"

  validation {
    condition     = var.intermediate_pki_path != ""
    error_message = "intermediate_pki_path must not be empty."
  }
}

variable "datacenter" {
  description = "Consul datacenter name. Embedded in certificate common names for clarity."
  type        = string
  default     = "dc1"

  validation {
    condition     = var.datacenter != ""
    error_message = "datacenter must not be empty."
  }
}

variable "org_name" {
  description = "Organisation name embedded in the Root CA X.509 Subject."
  type        = string
  default     = "HashiCorp Demo"

  validation {
    condition     = var.org_name != ""
    error_message = "org_name must not be empty."
  }
}

variable "country" {
  description = "Two-letter ISO country code for the Root CA Subject."
  type        = string
  default     = "US"

  validation {
    condition     = can(regex("^[A-Z]{2}$", var.country))
    error_message = "country must be a two-letter ISO 3166-1 alpha-2 country code (e.g. US, GB)."
  }
}

variable "locality" {
  description = "City/locality for the Root CA Subject."
  type        = string
  default     = "San Francisco"

  validation {
    condition     = var.locality != ""
    error_message = "locality must not be empty."
  }
}

variable "province" {
  description = "State/province for the Root CA Subject."
  type        = string
  default     = "CA"

  validation {
    condition     = var.province != ""
    error_message = "province must not be empty."
  }
}

variable "consul_server_sa_email" {
  description = <<-EOT
    Email of the GCP service account attached to Consul server VMs. This
    account is bound to the consul-server Vault GCP auth role, allowing
    vault-agent to authenticate without any baked-in credentials.
    Example: "consul-server@my-project.iam.gserviceaccount.com"
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.consul_server_sa_email))
    error_message = "consul_server_sa_email must be a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}

variable "gke_node_sa_email" {
  description = <<-EOT
    Email of the GKE node pool service account. Leave empty ("") if GKE
    pods should authenticate via Kubernetes auth only (recommended).
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.gke_node_sa_email == "" || can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.gke_node_sa_email))
    error_message = "gke_node_sa_email must be empty or a valid GCP service account email (e.g. sa-name@project-id.iam.gserviceaccount.com)."
  }
}

variable "vault_gcp_auth_credentials_json" {
  description = <<-EOT
    GCP service account JSON key (raw JSON string, not base64) for the Vault
    GCP auth backend configuration. HCP Vault has no GCP Application Default
    Credentials, so an explicit key is required to verify GCP IAM JWTs.
    The SA needs roles/iam.serviceAccountKeyViewer in the GCP project.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = var.vault_gcp_auth_credentials_json != ""
    error_message = "vault_gcp_auth_credentials_json must not be empty."
  }
}
