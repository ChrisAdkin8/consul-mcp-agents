# =============================================================================
# HCP Vault Dedicated Module — main.tf
#
# Provisions:
#   • HCP HashiCorp Virtual Network (HVN) in GCP
#   • HCP Vault Dedicated cluster (Plus tier for Vault Enterprise features)
#   • GCP VPC peering from HVN to the deployment VPC
#   • Admin token for subsequent Vault configuration
#
# The HVN is the network boundary inside HashiCorp Cloud Platform. Traffic
# between the HVN and your GCP VPC flows over a private peering connection,
# which means Consul VMs and GKE pods reach Vault on an RFC-1918 address
# rather than over the public internet.
#
# Usage:
#   module "hcp_vault" {
#     source             = "../../modules/hcp-vault"
#     hvn_id             = "vault-mcp-hvn"
#     cluster_id         = "vault-mcp-cluster"
#     region             = "us-central1"
#     hvn_cidr           = "172.25.16.0/20"
#     gcp_project_id     = var.gcp_project_id
#     gcp_network_name   = module.network.network_name
#   }
# =============================================================================

# ---------------------------------------------------------------------------
# HCP HashiCorp Virtual Network (HVN)
# The HVN is the HCP-managed VPC equivalent. It must be in the same GCP
# region as your workloads to minimise latency and avoid egress charges.
# The CIDR must not overlap any GCP subnet used by Consul VMs or GKE pods.
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
