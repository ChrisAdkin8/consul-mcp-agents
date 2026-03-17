# =============================================================================
# Scenario: consul-mcp-gke — gke.tf
# Layer 5: GKE cluster + Consul dataplane Helm deployment
# Depends on: module.consul (Consul IP needed for externalServers config)
#             module.vault_config (GCP SA resources must exist for Workload Identity)
#             module.vault_pki (CA cert needed for Consul TLS)
# =============================================================================

module "gke" {
  source = "../../modules/gke-consul-dataplane"

  project_id              = var.gcp_project_id
  region                  = var.gcp_region
  cluster_name            = var.gke_cluster_name
  machine_type            = var.gke_machine_type
  node_count              = var.gke_node_count
  network_self_link       = module.network.network_self_link
  subnet_self_link        = module.network.subnet_self_link
  subnet_cidr             = var.subnet_cidr
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  master_cidr             = var.gke_master_cidr
  datacenter              = var.datacenter
  consul_internal_address = module.consul.internal_server_ips[0]
  consul_bootstrap_token  = var.consul_bootstrap_token
  vault_ca_chain_pem      = module.vault_pki.ca_chain_pem
  helm_chart_version      = var.helm_chart_version
  mcp_namespace           = "mcp-agents"
  gke_endpoint            = local.cluster_endpoint
  gke_private_endpoint    = var.gke_cluster_private_endpoint
  authorized_networks     = var.gke_authorized_cidrs

  # Workload Identity bindings — service_account_id requires full resource name
  data_agent_sa_name    = module.vault_config.data_agent_sa_name
  compute_agent_sa_name = module.vault_config.compute_agent_sa_name

  depends_on = [
    module.consul,
    module.vault_pki,
    module.vault_config,
  ]
}
