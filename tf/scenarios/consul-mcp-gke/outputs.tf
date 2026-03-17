# =============================================================================
# Scenario: consul-mcp-gke — outputs.tf
# =============================================================================

output "vault_public_url" {
  description = "HCP Vault public endpoint URL — for operators and initial bootstrap."
  value       = module.hcp_vault.vault_public_endpoint_url
}

output "vault_private_url" {
  description = "HCP Vault private endpoint URL — used by all in-cluster workloads."
  value       = module.hcp_vault.vault_private_endpoint_url
}

output "gke_cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "gke_kubeconfig_command" {
  description = "Run this command to update your local kubeconfig."
  value       = module.gke.kubeconfig_command
}

output "consul_internal_ips" {
  description = "Internal IPs of Consul server VMs."
  value       = module.consul.internal_server_ips
}

output "mcp_agent_access" {
  description = "Instructions for accessing the MCP agent web terminals."
  value       = var.gke_cluster_ready ? module.mcp_agents[0].access_instructions : "MCP agents not deployed (gke_cluster_ready = false)"
}

output "root_ca_pem" {
  description = "Vault PKI Root CA certificate in PEM format. Trust this on external clients."
  value       = module.vault_pki.root_ca_pem
}

output "artifact_registry_url" {
  description = "Artifact Registry repository URL for Docker images."
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.mcp.repository_id}"
}

output "name_prefix" {
  description = "Name prefix used for all resources in this deployment."
  value       = local.name_prefix
}

output "deployment_summary" {
  description = "Human-readable deployment summary."
  value       = <<-EOT
    ============================================================
    consul-mcp-gke Deployment Summary
    ============================================================
    Vault Public URL:   ${module.hcp_vault.vault_public_endpoint_url}
    GKE Cluster:        ${module.gke.cluster_name} (${var.gcp_region})
    Consul Datacenter:  ${var.datacenter}
    Consul Servers:     ${var.consul_instance_count} VM(s) in ${var.gcp_zone}
    MCP Agent Replicas: ${var.mcp_replicas}

    Next steps:
      1. task vault:configure-k8s-auth  (after GKE is ready)
      2. task mcp:docker:push           (build and push agent image)
      3. task phase3:apply              (deploy MCP agents to GKE)
      4. kubectl get svc mcp-agent -n mcp-agents  (get web terminal URL)
    ============================================================
  EOT
}
