# =============================================================================
# Scenario: consul-mcp-gke — network.tf
# Layer 1: VPC, subnets, Cloud NAT (no external dependencies)
# =============================================================================

module "network" {
  source = "../../modules/network"

  project_id      = var.gcp_project_id
  name_prefix     = local.name_prefix
  region          = var.gcp_region
  subnet_cidr     = var.subnet_cidr
  pods_cidr       = var.pods_cidr
  services_cidr   = var.services_cidr
  gke_master_cidr = var.gke_master_cidr
}
