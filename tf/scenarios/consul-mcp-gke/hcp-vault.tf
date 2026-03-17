# =============================================================================
# Scenario: consul-mcp-gke — hcp-vault.tf
# Layer 2: HCP Vault Dedicated cluster + HVN + VPC peering
# Depends on: module.network (VPC must exist for peering)
# =============================================================================

module "hcp_vault" {
  source = "../../modules/hcp-vault"

  hvn_id           = "${local.short_prefix}-hvn"
  cluster_id       = "${local.short_prefix}-vault"
  region           = var.gcp_region
  hvn_cidr         = var.hcp_hvn_cidr
  tier             = var.hcp_vault_tier
  gcp_project_id   = var.gcp_project_id
  gcp_network_name = module.network.network_name
  gcp_subnet_cidrs = [var.subnet_cidr, var.pods_cidr, var.services_cidr]

  depends_on = [module.network]
}
