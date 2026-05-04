# =============================================================================
# HCP Vault Dedicated Module — main.tf
#
# Provisions:
#   • HCP HashiCorp Virtual Network (HVN) on AWS
#   • HCP Vault Dedicated cluster (Plus tier for Vault Enterprise features)
#   • Admin token for subsequent Vault configuration
#
# Networking model: HCP Vault Dedicated does not support direct VPC peering
# to GCP, so the HVN is provisioned on AWS and GCP workloads (Consul VMs,
# GKE pods) reach Vault over its public endpoint (with `allowed_ingress_cidrs`
# enforcing source-IP restrictions on the public LB at the GCP side).
# The HVN's `cidr_block` therefore only needs to avoid colliding with other
# AWS HVNs in the org; it does not need to be coordinated with GCP CIDRs.
# =============================================================================

# ---------------------------------------------------------------------------
# HCP HashiCorp Virtual Network (HVN)
# Hosted on AWS — see module-level comment above for why this isn't GCP.
# ---------------------------------------------------------------------------
resource "hcp_hvn" "main" {
  hvn_id         = var.hvn_id
  cloud_provider = "aws"
  region         = var.hvn_region
  cidr_block     = var.hvn_cidr
}

# ---------------------------------------------------------------------------
# HCP Vault Dedicated Cluster
# "plus_small" is the smallest Dedicated (Enterprise) tier, which includes:
#   • Vault namespaces
#   • Vault Sentinel (policy-as-code)
#   • Performance Replication
#   • Audit logging
#
# public_endpoint = true  is required so that:
#   (a) Terraform can configure Vault before VPC peering is established
#   (b) Operators can reach the Vault UI from their workstations
#   (c) The MCP agent prompt/cli.py can reach Vault from a laptop
#
# After peering is active the private_endpoint_url is used by all
# in-cluster workloads (Consul VMs, GKE pods).
# ---------------------------------------------------------------------------
resource "hcp_vault_cluster" "main" {
  hvn_id          = hcp_hvn.main.hvn_id
  cluster_id      = var.cluster_id
  tier            = var.tier
  public_endpoint = true

  # Route Vault audit logs to a GCS bucket via HCP observability (optional)
  # Uncomment when var.audit_log_bucket is set.
  # audit_log_config {
  #   gcs_bucket = var.audit_log_bucket
  # }
}

# ---------------------------------------------------------------------------
# Admin token — short-lived, used only during terraform apply to configure
# Vault secrets engines, auth methods, and policies. The Vault provider is
# initialised with this token in the scenario root.
# ---------------------------------------------------------------------------
resource "hcp_vault_cluster_admin_token" "main" {
  cluster_id = hcp_vault_cluster.main.cluster_id
}

# ---------------------------------------------------------------------------
# Note: HCP Vault does not support direct VPC peering to GCP. All connectivity
# from GCP workloads (Consul VMs, GKE pods) uses the public endpoint URL.
# ---------------------------------------------------------------------------
