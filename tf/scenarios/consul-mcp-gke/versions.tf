# =============================================================================
# Scenario: consul-mcp-gke — versions.tf
#
# Provider version constraints and Terraform backend configuration.
#
# Provider initialisation order matters:
#   1. google     — GCP resources (VPC, SAs, GKE) — no Vault dependency
#   2. hcp        — HCP Vault cluster — no Google dependency
#   3. vault      — configured AFTER hcp_vault_cluster exists (uses admin token)
#   4. kubernetes — configured AFTER GKE cluster exists (uses cluster endpoint)
#   5. helm       — same as kubernetes
#   6. consul     — configured AFTER Consul VMs are running
#
# The Taskfile handles phased apply to satisfy these dependencies.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.44"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.94"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # GCS backend — remote state with locking.
  # Bucket is supplied at init time via -backend-config; no manual config needed.
  # Run: task tf:backend:init   (creates bucket if absent, then runs terraform init)
  backend "gcs" {
    prefix = "terraform/consul-mcp-gke"
  }
}

# ---------------------------------------------------------------------------
# Provider configurations
# Sensitive values (tokens, credentials) are passed via environment variables
# or Terraform variables — never hardcoded.
# ---------------------------------------------------------------------------

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "hcp" {
  # Credentials via environment variables:
  #   HCP_CLIENT_ID     — HCP service principal client ID
  #   HCP_CLIENT_SECRET — HCP service principal client secret
  # Or via var.hcp_client_id / var.hcp_client_secret
  client_id     = var.hcp_client_id
  client_secret = var.hcp_client_secret
}

# Vault provider — uses admin token from HCP Vault module.
# During initial apply (-target=module.hcp_vault), this provider uses the
# public endpoint. After peering is established, switch to private endpoint.
provider "vault" {
  address = var.vault_address_override != "" ? var.vault_address_override : module.hcp_vault.vault_public_endpoint_url
  token   = module.hcp_vault.admin_token
}

# Auto-discover cluster endpoint once gke_cluster_ready = true.
# count = 0 during phase 1 (cluster creation), so providers fall back to
# kubernetes.default.svc and no kubernetes/helm resources are attempted.
data "google_container_cluster" "main" {
  count    = var.gke_cluster_ready ? 1 : 0
  name     = var.gke_cluster_name
  location = var.gcp_region
  project  = var.gcp_project_id
}

locals {
  _gke             = one(data.google_container_cluster.main)
  cluster_endpoint = local._gke != null ? local._gke.endpoint : ""
  cluster_ca_cert  = local._gke != null ? local._gke.master_auth[0].cluster_ca_certificate : ""
}

provider "kubernetes" {
  host                   = local.cluster_endpoint != "" ? "https://${local.cluster_endpoint}" : "https://kubernetes.default.svc"
  cluster_ca_certificate = local.cluster_ca_cert != "" ? base64decode(local.cluster_ca_cert) : null
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint != "" ? "https://${local.cluster_endpoint}" : "https://kubernetes.default.svc"
    cluster_ca_certificate = local.cluster_ca_cert != "" ? base64decode(local.cluster_ca_cert) : null
    token                  = data.google_client_config.default.access_token
  }
}

# Consul provider — points at the first Consul server's internal IP.
# Used for post-bootstrap ACL configuration if needed.
provider "consul" {
  address        = var.consul_address_override != "" ? var.consul_address_override : "${module.consul.internal_server_ips[0]}:8501"
  scheme         = "https"
  token          = var.consul_bootstrap_token
  ca_pem         = module.vault_pki.ca_chain_pem
  datacenter     = var.datacenter
  insecure_https = var.consul_address_override != "" ? true : false
}

# GCP access token for Kubernetes/Helm providers
data "google_client_config" "default" {}
