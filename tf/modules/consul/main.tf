# =============================================================================
# Consul Module — main.tf
#
# Provisions the external Consul control plane: GCE VM instances running
# the Consul server process, bootstrapped from a Packer-built image.
#
# The Consul servers act as the control plane for the GKE Consul dataplane.
# GKE pods connect to these servers via the Consul dataplane Helm chart
# (server.enabled = false in the chart — no Consul servers run inside GKE).
#
# Vault integration (new vs original terraform-gcp-nomad):
#   • Each VM has a dedicated GCP service account bound to a Vault GCP auth role
#   • vault-agent runs as a systemd service on each VM
#   • vault-agent authenticates via GCP IAM auth (no credentials in image)
#   • vault-agent renders the Vault Connect CA config into /etc/consul.d/
#   • Consul reads the rendered config and uses Vault PKI as its CA
# =============================================================================

data "google_compute_image" "consul_server" {
  family  = var.consul_image_family
  project = var.project_id
}


# ---------------------------------------------------------------------------
# Consul server instances
# ---------------------------------------------------------------------------
resource "google_compute_instance" "consul_server" {
  count        = var.instance_count
  project      = var.project_id
  name         = "${var.name_prefix}-consul-server-${count.index + 1}"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["consul-server", "vault-client"]
  description  = "Consul server ${count.index + 1} — external control plane for GKE dataplane"

  boot_disk {
    initialize_params {
      image = data.google_compute_image.consul_server.self_link
      size  = 30
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link
    # No access_config → no public IP. Egress via Cloud NAT.
  }

  service_account {
    email  = var.consul_server_sa_email
    scopes = ["cloud-platform"] # Broad scope; IAM controls actual permissions
  }

  # Metadata passed to the VM startup script and vault-agent config
  metadata = {
    # Consul config
    consul-datacenter       = var.datacenter
    consul-bootstrap-expect = tostring(var.instance_count)
    consul-retry-join-addrs = join(",", [
      for i in range(var.instance_count) :
      "${var.name_prefix}-consul-server-${i + 1}.${var.zone}.c.${var.project_id}.internal"
    ])

    # Vault config for vault-agent
    vault-address        = var.vault_private_endpoint_url
    vault-gcp-auth-role  = "consul-server"
    vault-root-pki-path  = var.vault_root_pki_path
    vault-inter-pki-path = var.vault_intermediate_pki_path

    # Startup script reads these and renders final Consul config
    startup-script = templatefile("${path.module}/templates/consul-server-startup.sh.tpl", {
      datacenter       = var.datacenter
      bootstrap_expect = var.instance_count
      node_name_suffix = count.index + 1
      name_prefix      = var.name_prefix
      project_id       = var.project_id
      zone             = var.zone
      region           = var.region
      gcs_bucket       = var.gcs_bucket
    })
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      # Ignore boot disk image changes to prevent re-creation on image rebuild
      boot_disk[0].initialize_params[0].image,
    ]
  }
}
