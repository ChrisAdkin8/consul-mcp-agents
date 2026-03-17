# =============================================================================
# Scenario: consul-mcp-gke — consul.tf
# Layer 4b: Consul external control plane (VMs)
# Depends on: module.vault_pki (PKI roles must exist before VMs boot)
#             module.vault_config (GCP auth must exist so vault-agent can authenticate)
#             google_service_account.consul_server (created in vault-pki.tf)
# =============================================================================

# ---------------------------------------------------------------------------
# GCS bucket: holds consul.hclic and consul-server.hcl for VM startup
# Uses short_prefix because GCS bucket names have stricter length limits.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "consul_config" {
  name                        = "${local.short_prefix}-consul-config"
  project                     = var.gcp_project_id
  location                    = var.gcp_region
  uniform_bucket_level_access = true
  force_destroy               = true

  labels = local.common_labels
}

# Grant the Consul server SA read access to the config bucket.
# The SA is created inside the consul module, so this binding is declared
# after the module block and references its output.
resource "google_storage_bucket_iam_member" "consul_server_config_reader" {
  bucket = google_storage_bucket.consul_config.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.consul.consul_server_sa_email}"
}

module "consul" {
  source = "../../modules/consul"

  project_id                  = var.gcp_project_id
  name_prefix                 = local.name_prefix
  zone                        = var.gcp_zone
  region                      = var.gcp_region
  datacenter                  = var.datacenter
  instance_count              = var.consul_instance_count
  subnet_self_link            = module.network.subnet_self_link
  vault_private_endpoint_url  = module.hcp_vault.vault_private_endpoint_url
  vault_root_pki_path         = var.vault_root_pki_path
  vault_intermediate_pki_path = var.vault_intermediate_pki_path
  gcs_bucket                  = google_storage_bucket.consul_config.name
  consul_server_sa_email      = google_service_account.consul_server.email

  depends_on = [
    module.vault_pki,
    module.vault_config,
  ]
}
