# =============================================================================
# Packer: AlmaLinux Consul Server with Vault Agent
#
# Builds a GCP custom image containing:
#   • Consul (Enterprise) binary
#   • vault-agent binary
#   • consul.service and vault-agent.service systemd units
#   • consul.hcl base configuration (server, TLS enabled)
#   • vault-agent.hcl template (rendered at runtime from GCP instance metadata)
#
# Key differences from the base terraform-gcp-nomad image:
#   1. vault-agent is installed and configured as a systemd service
#   2. vault-agent authenticates via GCP IAM auth (no baked-in credentials)
#   3. vault-agent renders the Consul Connect CA config at boot
#   4. TLS is enabled on Consul (certs fetched from Vault PKI by vault-agent)
#
# Usage:
#   cd packer
#   packer build \
#     -var "gcp_project_id=<project>" \
#     -var "consul_version=1.20.2+ent" \
#     -var "vault_version=1.19.0" \
#     gcp-almalinux-consul-server.pkr.hcl
# =============================================================================

packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "gcp_project_id" {
  type        = string
  description = "GCP project ID for the build VM."
}

variable "gcp_region" {
  type        = string
  default     = "us-central1"
  description = "GCP region for the build VM."
}

variable "gcp_zone" {
  type        = string
  default     = "us-central1-a"
  description = "GCP zone for the build VM."
}

variable "source_image_family" {
  type        = string
  default     = "almalinux-8"
  description = "Base OS image family."
}

variable "consul_version" {
  type        = string
  default     = "1.20.2"
  description = "Consul version to install (include +ent suffix for Enterprise)."
}

variable "vault_version" {
  type        = string
  default     = "1.19.0"
  description = "Vault version for the vault-agent binary."
}

variable "image_family" {
  type        = string
  default     = "almalinux-consul-server-vault"
  description = "Output image family name. The GKE module references this family."
}

# ---------------------------------------------------------------------------
# Source: Google Compute Engine
# ---------------------------------------------------------------------------
source "googlecompute" "consul-server" {
  project_id          = var.gcp_project_id
  zone                = var.gcp_zone
  source_image_family = var.source_image_family

  machine_type           = "e2-standard-2"
  disk_size              = 30
  disk_type              = "pd-ssd"
  ssh_username           = "packer"
  temporary_key_pair_type = "rsa"
  temporary_key_pair_bits = 4096

  image_family      = var.image_family
  image_name        = "${var.image_family}-{{timestamp}}"
  image_description = "AlmaLinux 8 with Consul ${var.consul_version} and vault-agent ${var.vault_version}"

  tags = ["packer-builder"]

  metadata = {
    # Disable OS Login for the packer SSH key to work
    "enable-oslogin" = "false"
  }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build {
  name    = "consul-server-vault"
  sources = ["source.googlecompute.consul-server"]

  # ---- Create destination directory for config files ----
  provisioner "shell" {
    inline = ["mkdir -p /tmp/packer-configs"]
  }

  # ---- Upload config files in a single transfer ----
  provisioner "file" {
    source      = "configs/"
    destination = "/tmp/packer-configs/"
  }

  # ---- Upload Consul Enterprise license ----
  provisioner "file" {
    source      = "../consul.hclic"
    destination = "/tmp/consul.hclic"
  }

  # ---- Move config files into expected locations ----
  provisioner "shell" {
    execute_command = "sudo -E bash '{{.Path}}'"
    inline = [
      "mv /tmp/packer-configs/consul-server.hcl /tmp/consul.hcl",
      "mv /tmp/packer-configs/vault-agent-consul.hcl.tmpl /tmp/vault-agent.hcl.tmpl",
      "rm -rf /tmp/packer-configs",
    ]
  }

  # ---- Install Vault agent (also downloads Consul binary in parallel) ----
  provisioner "shell" {
    execute_command  = "sudo -E bash '{{.Path}}'"
    environment_vars = [
      "VAULT_VERSION=${var.vault_version}",
      "CONSUL_VERSION=${var.consul_version}",
    ]
    scripts = ["scripts/provision-vault-agent.sh"]
  }

  # ---- Install Consul (binary already downloaded above) ----
  provisioner "shell" {
    execute_command  = "sudo -E bash '{{.Path}}'"
    environment_vars = [
      "CONSUL_VERSION=${var.consul_version}",
    ]
    scripts = ["scripts/provision-consul.sh"]
  }

  # ---- Validate installations ----
  provisioner "shell" {
    execute_command = "sudo -E bash '{{.Path}}'"
    inline = [
      "set -euo pipefail",
      "echo '=== Validating installations ==='",
      "/usr/local/bin/consul version",
      "/usr/local/bin/vault version",
      "systemctl is-enabled consul || echo 'WARNING: consul.service not enabled'",
      "systemctl is-enabled vault-agent || echo 'WARNING: vault-agent.service not enabled'",
      "echo '=== Validation complete ==='",
    ]
  }
}
