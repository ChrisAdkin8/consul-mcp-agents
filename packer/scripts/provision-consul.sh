#!/usr/bin/env bash
# =============================================================================
# provision-consul.sh
#
# Installs the Consul binary and configures it as a systemd
# service. This script is run during the Packer build and produces a baked
# image — Consul starts at VM boot, after vault-agent has rendered the
# Vault PKI Connect CA configuration.
# =============================================================================

set -euo pipefail

CONSUL_VERSION="${CONSUL_VERSION:-1.20.2}"
INSTALL_DIR="/usr/local/bin"
CONSUL_USER="consul"
CONSUL_DATA_DIR="/opt/consul"
CONSUL_CONFIG_DIR="/etc/consul.d"

echo "=== Installing Consul ${CONSUL_VERSION} ==="

# Dependencies (unzip, curl, jq) already installed by provision-vault-agent.sh

# Binary already downloaded and verified by provision-vault-agent.sh (parallel download)
CONSUL_ZIP="consul_${CONSUL_VERSION}_linux_amd64.zip"

unzip -oq "/tmp/${CONSUL_ZIP}" -d "${INSTALL_DIR}"
rm "/tmp/${CONSUL_ZIP}"
chmod 0755 "${INSTALL_DIR}/consul"
setcap cap_ipc_lock=+ep "${INSTALL_DIR}/consul"

# ---- Create consul user and directories ----
id -u "${CONSUL_USER}" &>/dev/null || useradd \
  --system \
  --home "${CONSUL_DATA_DIR}" \
  --shell /sbin/nologin \
  --comment "Consul service account" \
  "${CONSUL_USER}"

mkdir -p "${CONSUL_DATA_DIR}" "${CONSUL_CONFIG_DIR}/tls"
chown -R "${CONSUL_USER}:${CONSUL_USER}" "${CONSUL_DATA_DIR}" "${CONSUL_CONFIG_DIR}"
# 0770: vault-agent (in consul group) must be able to write rendered configs here
chmod 0770 "${CONSUL_CONFIG_DIR}"

# vault-agent runs as the vault user and needs consul group membership to write
# rendered configs (connect-ca.hcl etc.) into /etc/consul.d/.
# This must run after the consul group is created above.
usermod -aG consul vault
# consul reads vault-agent-written TLS files (vault:vault 0640). Adding consul to
# the vault group lets it read those files directly. The vault-agent template also
# runs chgrp consul after each render, but this membership is a safety net.
usermod -aG vault "${CONSUL_USER}"
# tls/ is written by vault-agent (vault user). Set group ownership to vault so
# vault-agent can write certs and consul can read them (consul is in vault group).
# Use setgid so new files inherit vault group.
chown "${CONSUL_USER}:vault" "${CONSUL_CONFIG_DIR}/tls"
chmod 2770 "${CONSUL_CONFIG_DIR}/tls"  # setgid + rwx for owner+group

# ---- Install base Consul configuration ----
mv /tmp/consul.hcl "${CONSUL_CONFIG_DIR}/consul.hcl"
chown "${CONSUL_USER}:${CONSUL_USER}" "${CONSUL_CONFIG_DIR}/consul.hcl"
chmod 0640 "${CONSUL_CONFIG_DIR}/consul.hcl"

# ---- Install Enterprise license (if present) ----
if [ -f /tmp/consul.hclic ]; then
  mv /tmp/consul.hclic "${CONSUL_CONFIG_DIR}/consul.hclic"
  chown "${CONSUL_USER}:${CONSUL_USER}" "${CONSUL_CONFIG_DIR}/consul.hclic"
  chmod 0640 "${CONSUL_CONFIG_DIR}/consul.hclic"
  echo "Consul Enterprise license installed."
else
  echo "No Enterprise license found at /tmp/consul.hclic — skipping (CE build)."
fi

# ---- systemd: consul.service ----
# NOTE: vault-agent.service is listed as a dependency — Consul will not start
# until vault-agent has rendered the Connect CA config file.
cat > /etc/systemd/system/consul.service << 'CONSUL_SVC'
[Unit]
Description=HashiCorp Consul — Service Mesh Control Plane
Documentation=https://www.consul.io/docs
Requires=vault-agent.service
After=vault-agent.service network-online.target
Wants=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity
PrivateDevices=yes
NoNewPrivileges=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=consul

[Install]
WantedBy=multi-user.target
CONSUL_SVC

systemctl daemon-reload
systemctl enable consul.service

echo "=== Consul installation complete ==="
