#!/usr/bin/env bash
# =============================================================================
# consul-server-startup.sh
#
# GCE startup script for Consul server VMs.
# Rendered by Terraform templatefile() — instance-specific values are
# substituted at plan time.
#
# Responsibilities:
#   1. Write /etc/consul.d/runtime-config.hcl (node_name, bootstrap_expect,
#      datacenter, retry_join) — these are instance-specific and cannot be
#      baked into the Packer image.
#   2. Download consul.hclic and consul-server.hcl from GCS if present
#      (allows license/config updates without rebuilding the image).
#
# The vault-agent config rendering, vault-agent.service, and consul.service
# startup sequencing are all handled by the systemd units baked into the
# Packer image — this script only sets the Consul runtime config.
# =============================================================================

set -euo pipefail

CONSUL_CONFIG_DIR="/etc/consul.d"
CONSUL_USER="consul"
GCS_BUCKET="${gcs_bucket}"

echo "=== Consul startup: ${name_prefix}-consul-server-${node_name_suffix} ==="

# ---------------------------------------------------------------------------
# 1. Write instance-specific Consul runtime config
# ---------------------------------------------------------------------------
# The base consul-server.hcl (baked into the image) sets server = true,
# TLS, ports, ACL, and connect. This file provides the per-instance values
# that can only be known at deploy time.
cat > "$${CONSUL_CONFIG_DIR}/runtime-config.hcl" << 'RUNTIME_HCL'
# Rendered by Terraform startup script — do not edit manually
node_name        = "${name_prefix}-consul-server-${node_name_suffix}"
bootstrap_expect = ${bootstrap_expect}
datacenter       = "${datacenter}"

retry_join = [
%{~ for i in range(bootstrap_expect) }
  "${name_prefix}-consul-server-${i + 1}.${zone}.c.${project_id}.internal",
%{~ endfor }
]
RUNTIME_HCL

chown "$${CONSUL_USER}:$${CONSUL_USER}" "$${CONSUL_CONFIG_DIR}/runtime-config.hcl"
chmod 0640 "$${CONSUL_CONFIG_DIR}/runtime-config.hcl"
echo "Runtime config written."

# ---------------------------------------------------------------------------
# 2. Download Consul license from GCS (Enterprise)
# ---------------------------------------------------------------------------
# Downloading from GCS allows license renewals without rebuilding the image.
# Falls back silently to the image-baked license (or CE with no license).
if gsutil cp "gs://$${GCS_BUCKET}/consul.hclic" /tmp/consul-gcs.hclic 2>/dev/null; then
  mv /tmp/consul-gcs.hclic "$${CONSUL_CONFIG_DIR}/consul.hclic"
  chown "$${CONSUL_USER}:$${CONSUL_USER}" "$${CONSUL_CONFIG_DIR}/consul.hclic"
  chmod 0640 "$${CONSUL_CONFIG_DIR}/consul.hclic"
  echo "Consul Enterprise license downloaded from GCS."
else
  echo "No consul.hclic found in GCS — using image-baked license or CE."
fi

# ---------------------------------------------------------------------------
# 3. Download base Consul config from GCS (optional override)
# ---------------------------------------------------------------------------
# If consul-server.hcl exists in GCS it overrides the image-baked version,
# allowing config changes without a Packer rebuild.
if gsutil cp "gs://$${GCS_BUCKET}/consul-server.hcl" /tmp/consul-gcs.hcl 2>/dev/null; then
  mv /tmp/consul-gcs.hcl "$${CONSUL_CONFIG_DIR}/consul.hcl"
  chown "$${CONSUL_USER}:$${CONSUL_USER}" "$${CONSUL_CONFIG_DIR}/consul.hcl"
  chmod 0640 "$${CONSUL_CONFIG_DIR}/consul.hcl"
  echo "Consul base config downloaded from GCS (overrides image-baked version)."
fi

echo "=== Consul startup script complete ==="
