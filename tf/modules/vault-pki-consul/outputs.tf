# =============================================================================
# Vault PKI for Consul Module — outputs.tf
# =============================================================================

output "root_pki_path" {
  description = "Mount path of the Root CA PKI engine."
  value       = vault_mount.connect_root.path
}

output "intermediate_pki_path" {
  description = "Mount path of the Intermediate CA PKI engine."
  value       = vault_mount.connect_intermediate.path
}

output "root_ca_pem" {
  description = <<-EOT
    PEM-encoded Root CA certificate. Distribute this to any system that needs
    to trust Consul Connect leaf certs (e.g. external services, monitoring).
  EOT
  value       = vault_pki_secret_backend_root_cert.connect_root.certificate
  sensitive   = false
}

output "intermediate_ca_pem" {
  description = "PEM-encoded Intermediate CA certificate (signed by Root CA)."
  value       = vault_pki_secret_backend_root_sign_intermediate.connect.certificate
  sensitive   = false
}

output "ca_chain_pem" {
  description = "Full PEM certificate chain (Intermediate + Root). Written into K8s secrets for GKE TLS."
  value       = vault_pki_secret_backend_root_sign_intermediate.connect.certificate_bundle
  sensitive   = false
}

output "connect_role_name" {
  description = "Name of the PKI role used by Consul Connect CA provider."
  value       = vault_pki_secret_backend_role.consul_connect.name
}

output "server_tls_role_name" {
  description = "Name of the PKI role for Consul server TLS certificates."
  value       = vault_pki_secret_backend_role.consul_server_tls.name
}

output "consul_server_policy_name" {
  description = "Name of the Vault policy granted to Consul server VMs."
  value       = vault_policy.consul_server.name
}

output "gcp_auth_path" {
  description = "Mount path of the Vault GCP auth backend."
  value       = vault_gcp_auth_backend.gcp.path
}

output "consul_server_gcp_role" {
  description = "Name of the GCP auth role for Consul server VMs."
  value       = vault_gcp_auth_backend_role.consul_server.role
}
