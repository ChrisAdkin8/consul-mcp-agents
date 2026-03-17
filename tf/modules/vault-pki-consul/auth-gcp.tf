# =============================================================================
# Vault PKI for Consul Module — auth-gcp.tf
#
# Configures the Vault GCP auth method so Consul server VMs can authenticate
# to Vault using their GCP service account identity — no credentials baked
# into images, no secrets on disk.
#
# Authentication flow:
#   1. Consul VM boots, vault-agent starts
#   2. vault-agent calls the GCP metadata server to get a signed JWT for the
#      VM's service account
#   3. vault-agent presents the JWT to Vault at auth/gcp/login
#   4. Vault verifies the JWT with GCP IAM (bound_service_accounts check)
#   5. Vault returns a token with the consul-server-policy attached
#   6. vault-agent writes the token to /tmp/vault-token
#   7. vault-agent renders Consul config templates using the token
#   8. Consul starts and uses the rendered config (Vault CA address + token)
# =============================================================================

# ---------------------------------------------------------------------------
# GCP auth backend — enable + configure in one resource
#
# vault_gcp_auth_backend manages both enabling the auth backend and setting
# GCP-specific configuration (credentials). Using vault_auth_backend alongside
# vault_gcp_auth_backend for the same path causes a 400 conflict because
# vault_gcp_auth_backend tries to enable the backend itself.
#
# HCP Vault runs outside GCP and has no Application Default Credentials.
# Without explicit credentials, the Vault GCP auth plugin cannot call the
# Google IAM API to verify service account JWT signatures → 500 error.
#
# The credentials SA needs roles/iam.serviceAccountKeyAdmin at project level.
# ---------------------------------------------------------------------------
resource "vault_gcp_auth_backend" "gcp" {
  path        = "gcp"
  description = "GCP IAM auth for Consul server VMs and GCP-native workloads"
  credentials = var.vault_gcp_auth_credentials_json
}

# ---------------------------------------------------------------------------
# Consul server GCE role
#
# type = "gce" means Vault validates the GCE instance identity token
# (from the metadata server) rather than a signed IAM JWT. This is more
# reliable on GCE VMs because:
#   • The identity token is always available via the metadata server
#   • Does not require the IAM signJWT API or serviceAccountTokenCreator role
#   • The VM's service account is encoded in the identity token
#
# bound_service_accounts: only the dedicated consul-server SA can assume
# this role — other SAs on other VMs are rejected even in the same project.
# ---------------------------------------------------------------------------
resource "vault_gcp_auth_backend_role" "consul_server" {
  role                   = "consul-server"
  type                   = "iam" # Vault verifies IAM JWT signature using configured GCP credentials
  backend                = vault_gcp_auth_backend.gcp.path
  bound_service_accounts = [var.consul_server_sa_email]
  token_policies         = [vault_policy.consul_server.name]
  token_ttl              = 3600  # vault-agent renews before this expires
  token_max_ttl          = 86400 # hard ceiling; VM must re-auth after 24h
  token_period           = 3600  # periodic token — auto-renewed by vault-agent
  max_jwt_exp            = 3600  # allow JWTs up to 1h old; vault-agent default is 30m
}

# ---------------------------------------------------------------------------
# GKE pod Kubernetes auth role (GKE nodes authenticate via K8s auth, but we
# add a GCP IAM role here for any GCE-native workloads that also need Vault)
# ---------------------------------------------------------------------------
resource "vault_gcp_auth_backend_role" "gke_node" {
  count = var.gke_node_sa_email != "" ? 1 : 0

  role                   = "gke-node"
  type                   = "gce"
  backend                = vault_gcp_auth_backend.gcp.path
  bound_service_accounts = [var.gke_node_sa_email]
  token_policies         = ["default"]
  token_ttl              = 900
  token_max_ttl          = 3600
}
