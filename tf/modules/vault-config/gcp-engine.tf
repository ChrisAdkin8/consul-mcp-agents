# =============================================================================
# Vault Config Module — gcp-engine.tf
#
# Configures the Vault GCP secrets engine that issues 5-minute OAuth2 access
# tokens via service account impersonation. This is the core credential
# brokering mechanism from the vault-mcp-agents repo, now managed as a
# production Terraform module.
#
# Credential flow:
#   MCP server pod
#     → hvac.secrets.gcp.generate_impersonated_account_oauth2_access_token()
#     → Vault GCP secrets engine
#     → GCP generateAccessToken API (impersonated SA)
#     → OAuth2 token (5-minute TTL)
#     → GCS / BigQuery / Compute API call
#
# Dual TTL enforcement:
#   Layer 1 (server-side):  vault_gcp_secret_impersonated_account.ttl = "300"
#   Layer 2 (client-side):  capabilities.yaml max_gcp_token_ttl: "5m"
#   Effective TTL = min(vault_ttl, policy_ttl) — both must agree
# =============================================================================

# ---------------------------------------------------------------------------
# GCP service account for Vault's impersonation chain
#
# This SA is the "impersonator" — it calls generateAccessToken on behalf of
# the agent SAs. IAM permissions (least-privilege):
#   roles/iam.serviceAccountKeyAdmin    — manage SA keys (Vault backend credentials)
#   roles/iam.serviceAccountTokenCreator — call generateAccessToken
# ---------------------------------------------------------------------------
resource "google_service_account" "vault_impersonator" {
  account_id   = var.vault_sa_id
  display_name = "Vault GCP Secrets Engine Impersonator"
  description  = "Used by Vault to impersonate agent service accounts and issue 5-minute OAuth2 tokens"
  project      = var.gcp_project_id
}

resource "google_service_account_key" "vault_impersonator" {
  service_account_id = google_service_account.vault_impersonator.name
  # Key is stored in Terraform state (sensitive). Rotate via:
  #   task vault:rotate-gcp-sa-key
}

# IAM grants for the Vault impersonator SA are scoped to specific target SAs at
# the resource level (see google_service_account_iam_member.vault_impersonates_*
# below). Project-level grants of serviceAccountTokenCreator/KeyAdmin are not
# needed in impersonation mode and would broaden blast radius to every SA in
# the project.

# ---------------------------------------------------------------------------
# Vault GCP secrets engine
# ---------------------------------------------------------------------------
resource "vault_gcp_secret_backend" "main" {
  path        = var.gcp_secrets_mount_path
  description = "GCP secrets engine — issues 5-minute OAuth2 tokens via impersonation"

  credentials = base64decode(google_service_account_key.vault_impersonator.private_key)

  default_lease_ttl_seconds = 300 # 5 minutes — cannot exceed max
  max_lease_ttl_seconds     = 300 # Hard ceiling; Vault refuses TTL > this

  depends_on = [
    google_service_account_iam_member.vault_impersonates_data,
    google_service_account_iam_member.vault_impersonates_compute,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Agent service accounts — impersonated targets
# ---------------------------------------------------------------------------

# Data agent SA — GCS + BigQuery operations
resource "google_service_account" "data_agent" {
  account_id   = "data-agent-gcp"
  display_name = "MCP Data Agent"
  description  = "Impersonated by Vault to issue 5-min tokens for GCS and BigQuery operations"
  project      = var.gcp_project_id
}

resource "google_project_iam_member" "data_agent" {
  for_each = toset(["roles/storage.objectAdmin", "roles/bigquery.dataEditor", "roles/bigquery.jobUser"])

  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.data_agent.email}"
}

# Allow Vault impersonator SA to impersonate data-agent SA
resource "google_service_account_iam_member" "vault_impersonates_data" {
  service_account_id = google_service_account.data_agent.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vault_impersonator.email}"
}

# Compute agent SA — GCE operations
resource "google_service_account" "compute_agent" {
  account_id   = "compute-agent-gcp"
  display_name = "MCP Compute Agent"
  description  = "Impersonated by Vault to issue 5-min tokens for GCE operations"
  project      = var.gcp_project_id
}

resource "google_project_iam_member" "compute_agent" {
  project = var.gcp_project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.compute_agent.email}"
}

resource "google_service_account_iam_member" "vault_impersonates_compute" {
  service_account_id = google_service_account.compute_agent.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vault_impersonator.email}"
}

# ---------------------------------------------------------------------------
# Vault impersonated account definitions
# TTL = 300 seconds (5 minutes) — enforced at the GCP generateAccessToken level
# ---------------------------------------------------------------------------
resource "vault_gcp_secret_impersonated_account" "data_agent" {
  backend               = vault_gcp_secret_backend.main.path
  impersonated_account  = "data-agent-gcp"
  service_account_email = google_service_account.data_agent.email
  token_scopes          = ["https://www.googleapis.com/auth/cloud-platform"]
  ttl                   = "300" # 5 minutes — Layer 1 TTL enforcement

  depends_on = [google_service_account_iam_member.vault_impersonates_data]
}

resource "vault_gcp_secret_impersonated_account" "compute_agent" {
  backend               = vault_gcp_secret_backend.main.path
  impersonated_account  = "compute-agent-gcp"
  service_account_email = google_service_account.compute_agent.email
  token_scopes          = ["https://www.googleapis.com/auth/compute"]
  ttl                   = "300" # 5 minutes — Layer 1 TTL enforcement

  depends_on = [google_service_account_iam_member.vault_impersonates_compute]
}
