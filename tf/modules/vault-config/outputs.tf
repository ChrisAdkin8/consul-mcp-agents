# =============================================================================
# Vault Config Module — outputs.tf
# =============================================================================

output "kv_mount_path" {
  description = "Mount path of the KV v2 secrets engine."
  value       = vault_mount.secret.path
}

output "gcp_secrets_mount_path" {
  description = "Mount path of the GCP secrets engine."
  value       = vault_gcp_secret_backend.main.path
}

output "vault_impersonator_sa_email" {
  description = "Email of the GCP service account used by Vault for impersonation."
  value       = google_service_account.vault_impersonator.email
}

output "data_agent_sa_email" {
  description = "Email of the GCP service account impersonated for data agent operations."
  value       = google_service_account.data_agent.email
}

output "data_agent_sa_name" {
  description = "Full resource name of the data-agent GCP SA (projects/PROJECT/serviceAccounts/EMAIL)."
  value       = google_service_account.data_agent.name
}

output "compute_agent_sa_email" {
  description = "Email of the GCP service account impersonated for compute agent operations."
  value       = google_service_account.compute_agent.email
}

output "compute_agent_sa_name" {
  description = "Full resource name of the compute-agent GCP SA (projects/PROJECT/serviceAccounts/EMAIL)."
  value       = google_service_account.compute_agent.name
}

output "kubernetes_auth_path" {
  description = "Mount path of the Kubernetes auth backend."
  value       = vault_auth_backend.kubernetes.path
}

output "mcp_server_k8s_role" {
  description = "Name of the Kubernetes auth role for MCP server pods."
  value       = vault_kubernetes_auth_backend_role.mcp_server.role_name
}

output "mcp_agent_k8s_role" {
  description = "Name of the Kubernetes auth role for MCP agent pods."
  value       = vault_kubernetes_auth_backend_role.mcp_agent.role_name
}

output "userpass_auth_path" {
  description = "Mount path of the userpass auth backend."
  value       = vault_auth_backend.userpass.path
}

output "operator_policy_name" {
  description = "Name of the Vault policy for operator-role users."
  value       = vault_policy.operator.name
}

output "mcp_server_policy_name" {
  description = "Name of the Vault policy for MCP server pods."
  value       = vault_policy.mcp_server.name
}

output "data_agent_impersonated_account_name" {
  description = "Vault GCP impersonated account name for the data agent (used in hvac calls)."
  value       = vault_gcp_secret_impersonated_account.data_agent.impersonated_account
}

output "compute_agent_impersonated_account_name" {
  description = "Vault GCP impersonated account name for the compute agent."
  value       = vault_gcp_secret_impersonated_account.compute_agent.impersonated_account
}
