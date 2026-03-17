# =============================================================================
# HCP Vault Module — outputs.tf
# =============================================================================

output "vault_public_endpoint_url" {
  description = <<-EOT
    Public HTTPS URL for the Vault cluster. Used by:
    • Terraform Vault provider during apply (before peering is active)
    • Operators accessing the Vault UI from their workstations
    • vault-mcp-agents prompt/cli.py when run from a developer laptop
  EOT
  value       = hcp_vault_cluster.main.vault_public_endpoint_url
}

output "vault_private_endpoint_url" {
  description = <<-EOT
    Returns the public endpoint URL. HCP Vault does not support direct GCP VPC
    peering, so all in-cluster workloads (Consul VMs, GKE pods) connect via
    the public endpoint.
  EOT
  value       = hcp_vault_cluster.main.vault_public_endpoint_url
}

output "admin_token" {
  description = <<-EOT
    Short-lived admin token. Used exclusively during terraform apply to
    bootstrap the Vault provider in the scenario root. Do not store this
    token or use it operationally — it expires after 6 hours.
  EOT
  value       = hcp_vault_cluster_admin_token.main.token
  sensitive   = true
}

output "cluster_id" {
  description = "HCP Vault cluster identifier."
  value       = hcp_vault_cluster.main.cluster_id
}

output "hvn_id" {
  description = "HCP HVN identifier."
  value       = hcp_hvn.main.hvn_id
}

output "hvn_self_link" {
  description = "Self-link of the HVN, used for additional route and peering resources."
  value       = hcp_hvn.main.self_link
}


output "cluster_state" {
  description = "Current state of the HCP Vault cluster (e.g. RUNNING)."
  value       = hcp_vault_cluster.main.state
}
