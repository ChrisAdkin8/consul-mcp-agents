# =============================================================================
# Scenario: consul-mcp-gke — vault-pki.tf
# Layer 3: Vault PKI (Root + Intermediate CA for Consul Connect)
# Depends on: module.hcp_vault (Vault must exist to configure PKI)
#
# The Consul server SA is created here (before module.consul) so vault-pki
# can bind it to the Vault GCP auth role. module.consul then receives the SA
# email as an input and attaches it to the VMs — no duplicate SA creation.
# =============================================================================

# Consul server SA (created here so vault-pki can bind it before VMs boot)
resource "google_service_account" "consul_server" {
  account_id   = "${local.sa_prefix}-consul-server"
  display_name = "Consul Server VM SA"
  description  = "Service account for Consul server VMs — used for Vault GCP IAM auth"
  project      = var.gcp_project_id
}

# ---------------------------------------------------------------------------
# Vault GCP auth verifier SA
#
# HCP Vault runs outside GCP and has no Application Default Credentials.
# The Vault GCP auth plugin needs a GCP service account key to call the
# IAM API and verify service account JWT signatures.
#
# This SA has the minimum permissions required:
#   • roles/iam.serviceAccountKeyViewer — to read SA public keys for JWT verification
# ---------------------------------------------------------------------------
resource "google_service_account" "vault_gcp_verifier" {
  account_id   = "${local.sa_prefix}-vault-verifier"
  display_name = "Vault GCP Auth Verifier"
  description  = "Service account key used by HCP Vault to verify GCP IAM auth tokens"
  project      = var.gcp_project_id
}

resource "google_service_account_key" "vault_gcp_verifier" {
  service_account_id = google_service_account.vault_gcp_verifier.name
}

# Grant verifier SA iam.serviceAccountKeyAdmin at the project level.
# This gives Vault the ability to call the IAM API to read service account
# public keys, which is required to verify GCP IAM JWT signatures.
resource "google_project_iam_member" "vault_gcp_verifier_key_admin" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = "serviceAccount:${google_service_account.vault_gcp_verifier.email}"
}

# IAM bindings for the Consul server SA — previously in modules/consul/main.tf,
# moved here so they are managed alongside the SA creation.

# Allow the SA to generate its own identity tokens (needed for IAM-type GCP auth)
resource "google_service_account_iam_member" "consul_server_self" {
  service_account_id = google_service_account.consul_server.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.consul_server.email}"
}

# Read-only compute metadata access (for vault-agent GCP auth JWT generation)
resource "google_project_iam_member" "consul_server_metadata" {
  project = var.gcp_project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.consul_server.email}"
}

module "vault_pki" {
  source = "../../modules/vault-pki-consul"

  vault_addr                      = module.hcp_vault.vault_private_endpoint_url
  root_pki_path                   = var.vault_root_pki_path
  intermediate_pki_path           = var.vault_intermediate_pki_path
  datacenter                      = var.datacenter
  consul_server_sa_email          = google_service_account.consul_server.email
  vault_gcp_auth_credentials_json = base64decode(google_service_account_key.vault_gcp_verifier.private_key)

  depends_on = [module.hcp_vault, google_service_account_key.vault_gcp_verifier]
}
