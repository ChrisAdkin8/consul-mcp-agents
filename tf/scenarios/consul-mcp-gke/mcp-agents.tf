# =============================================================================
# Scenario: consul-mcp-gke — mcp-agents.tf
# Layer 6: MCP agent pods on GKE
# Depends on: module.gke (cluster must exist)
#             module.vault_config (K8s auth roles + KV secrets must exist)
#
# IMPORTANT: Before applying this layer, run:
#   task vault:configure-k8s-auth
# This configures the Vault Kubernetes auth backend with the GKE endpoint
# and CA certificate (available only after GKE apply completes).
# =============================================================================

module "mcp_agents" {
  count  = var.gke_cluster_ready ? 1 : 0
  source = "../../modules/mcp-agents-k8s"

  namespace              = "mcp-agents"
  replicas               = var.mcp_replicas
  app_image_repository   = "${local.image_repo_base}/vault-mcp-agents"
  app_image_tag          = var.mcp_image_tag
  vault_address          = module.hcp_vault.vault_private_endpoint_url
  vault_k8s_role         = module.vault_config.mcp_server_k8s_role
  vault_k8s_agent_role   = module.vault_config.mcp_agent_k8s_role
  gcp_project_id         = var.gcp_project_id
  data_agent_sa_email    = module.vault_config.data_agent_sa_email
  compute_agent_sa_email = module.vault_config.compute_agent_sa_email
  ttyd_credential        = var.mcp_ttyd_credential
  allowed_ingress_cidrs  = var.allowed_ingress_cidrs
  depends_on = [
    module.gke,
    module.vault_config,
    google_artifact_registry_repository.mcp,
  ]
}
