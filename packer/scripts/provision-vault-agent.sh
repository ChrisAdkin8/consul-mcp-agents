#!/usr/bin/env bash
# =============================================================================
# provision-vault-agent.sh
#
# Installs the vault-agent binary and configures it as a systemd service.
#
# The vault-agent service:
#   1. Reads the vault-agent.hcl config (rendered from template at first boot)
#   2. Authenticates to HCP Vault using the GCP IAM auth method
#      (uses the VM's service account JWT — no baked-in credentials)
#   3. Renders /etc/consul.d/connect-ca.hcl from the template in the config
#   4. Writes a ready sentinel file: /tmp/vault-agent-ready
#   5. Keeps the Vault token renewed for the lifetime of the VM
#
# The startup script (rendered by Terraform templatefile) waits for
# /tmp/vault-agent-ready before starting Consul.
# =============================================================================

set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-1.21.3}"
CONSUL_VERSION="${CONSUL_VERSION:-1.20.2}"
VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
INSTALL_DIR="/usr/local/bin"
VAULT_USER="vault"
VAULT_DATA_DIR="/opt/vault"
VAULT_CONFIG_DIR="/etc/vault-agent"
CONSUL_CONFIG_DIR="/etc/consul.d"

echo "=== Installing vault-agent ${VAULT_VERSION} ==="

# ---- Install dependencies ----
yum install -y unzip curl jq

# ---- Download and verify Vault + Consul binaries in parallel ----
VAULT_ZIP="vault_${VAULT_VERSION}_linux_amd64.zip"
VAULT_SUMS_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"

# CONSUL_VERSION is passed via environment from Packer
CONSUL_ZIP="consul_${CONSUL_VERSION}_linux_amd64.zip"
CONSUL_URL="https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip"
CONSUL_SUMS_URL="https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_SHA256SUMS"

echo "  Downloading Vault ${VAULT_VERSION} and Consul ${CONSUL_VERSION} in parallel..."
curl -fsSL "${VAULT_URL}" -o "/tmp/${VAULT_ZIP}" &
VAULT_DL_PID=$!
curl -fsSL "${CONSUL_URL}" -o "/tmp/${CONSUL_ZIP}" &
CONSUL_DL_PID=$!
curl -fsSL "${VAULT_SUMS_URL}" | grep "${VAULT_ZIP}" > /tmp/vault.sha256 &
VAULT_SUMS_PID=$!
curl -fsSL "${CONSUL_SUMS_URL}" | grep "${CONSUL_ZIP}" > /tmp/consul.sha256 &
CONSUL_SUMS_PID=$!

wait "${VAULT_DL_PID}" || { echo "ERROR: Vault binary download failed"; exit 1; }
wait "${CONSUL_DL_PID}" || { echo "ERROR: Consul binary download failed"; exit 1; }
wait "${VAULT_SUMS_PID}" || { echo "ERROR: Vault SHA256SUMS download failed"; exit 1; }
wait "${CONSUL_SUMS_PID}" || { echo "ERROR: Consul SHA256SUMS download failed"; exit 1; }
echo "  Downloads complete. Verifying checksums..."

(cd /tmp && sha256sum -c vault.sha256)
(cd /tmp && sha256sum -c consul.sha256)
rm /tmp/vault.sha256 /tmp/consul.sha256

unzip -oq "/tmp/${VAULT_ZIP}" -d "${INSTALL_DIR}"
rm "/tmp/${VAULT_ZIP}"
chmod 0755 "${INSTALL_DIR}/vault"
# Allow vault binary to use mlock (prevents token from being swapped to disk)
setcap cap_ipc_lock=+ep "${INSTALL_DIR}/vault"

# ---- Create vault user and directories ----
id -u "${VAULT_USER}" &>/dev/null || useradd \
  --system \
  --home "${VAULT_DATA_DIR}" \
  --shell /sbin/nologin \
  --comment "Vault agent service account" \
  "${VAULT_USER}"

mkdir -p "${VAULT_DATA_DIR}" "${VAULT_CONFIG_DIR}" "${CONSUL_CONFIG_DIR}"
chown -R "${VAULT_USER}:${VAULT_USER}" "${VAULT_DATA_DIR}"
chown "${VAULT_USER}:${VAULT_USER}" "${VAULT_CONFIG_DIR}"
chmod 0750 "${VAULT_CONFIG_DIR}"

# NOTE: vault-agent must be in the consul group to write rendered configs into
# /etc/consul.d/. That group is created by provision-consul.sh, which runs
# AFTER this script in the Packer build. The usermod is done there instead.

# ---- Install vault-agent config template ----
# The full config is rendered at first boot by the startup script using
# GCP instance metadata (vault address, PKI paths, auth role).
mv /tmp/vault-agent.hcl.tmpl "${VAULT_CONFIG_DIR}/vault-agent.hcl.tmpl"
chown "${VAULT_USER}:${VAULT_USER}" "${VAULT_CONFIG_DIR}/vault-agent.hcl.tmpl"

# ---- First-boot renderer script ----
# This script is run once at VM startup BEFORE vault-agent starts.
# It reads GCP instance metadata and renders the vault-agent config.
cat > /usr/local/bin/render-vault-agent-config.sh << 'RENDER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance"
CURL="curl -sf -H 'Metadata-Flavor: Google'"

# Read Vault configuration from GCP instance metadata
VAULT_ADDR=$(eval "${CURL} ${METADATA_BASE}/attributes/vault-address")
VAULT_GCP_ROLE=$(eval "${CURL} ${METADATA_BASE}/attributes/vault-gcp-auth-role")
ROOT_PKI_PATH=$(eval "${CURL} ${METADATA_BASE}/attributes/vault-root-pki-path")
INTER_PKI_PATH=$(eval "${CURL} ${METADATA_BASE}/attributes/vault-inter-pki-path")
DATACENTER=$(eval "${CURL} ${METADATA_BASE}/attributes/consul-datacenter")
# Auto-detect service account email — avoids vault-agent using "default" literally
SA_EMAIL=$(eval "${CURL} ${METADATA_BASE}/service-accounts/default/email")

# Render vault-agent.hcl from template
sed \
  -e "s|__VAULT_ADDR__|${VAULT_ADDR}|g" \
  -e "s|__GCP_ROLE__|${VAULT_GCP_ROLE}|g" \
  -e "s|__ROOT_PKI_PATH__|${ROOT_PKI_PATH}|g" \
  -e "s|__INTER_PKI_PATH__|${INTER_PKI_PATH}|g" \
  -e "s|__DATACENTER__|${DATACENTER}|g" \
  -e "s|__SA_EMAIL__|${SA_EMAIL}|g" \
  /etc/vault-agent/vault-agent.hcl.tmpl > /etc/vault-agent/vault-agent.hcl

chmod 0640 /etc/vault-agent/vault-agent.hcl
chown vault:vault /etc/vault-agent/vault-agent.hcl

echo "vault-agent config rendered successfully."
RENDER_SCRIPT

chmod 0755 /usr/local/bin/render-vault-agent-config.sh

# ---- systemd: config renderer service (runs before vault-agent) ----
cat > /etc/systemd/system/vault-agent-config.service << 'RENDER_SVC'
[Unit]
Description=Render vault-agent configuration from GCP instance metadata
Before=vault-agent.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/render-vault-agent-config.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RENDER_SVC

# ---- systemd: vault-agent service ----
cat > /etc/systemd/system/vault-agent.service << 'AGENT_SVC'
[Unit]
Description=HashiCorp Vault Agent — Consul CA cert renderer
Documentation=https://www.vaultproject.io/docs/agent
Requires=vault-agent-config.service
After=vault-agent-config.service
Before=consul.service

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/vault-agent.hcl
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
SyslogIdentifier=vault-agent

[Install]
WantedBy=multi-user.target
AGENT_SVC

# ---- sudoers: vault user can reload consul after cert re-render ----
# vault-agent runs as the vault user and calls `sudo systemctl reload consul`
# in the tls-certs.hcl post-render command. Without this, the reload fails
# silently and Consul keeps using the expired cert until manually restarted.
echo 'vault ALL=(ALL) NOPASSWD: /bin/systemctl reload consul' \
  > /etc/sudoers.d/vault-consul-reload
chmod 0440 /etc/sudoers.d/vault-consul-reload
visudo -cf /etc/sudoers.d/vault-consul-reload

# ---- cert-refresh script: issue new TLS cert directly via Vault PKI API ----
# Does NOT restart vault-agent. Restarting vault-agent would get a new Vault
# token, which re-renders connect-ca.hcl, which causes `systemctl reload consul`
# to create a new Consul Connect intermediate CA — breaking all running pods.
# Instead, this script calls Vault PKI directly using the existing auto-auth
# token, writes the cert files atomically, and sends SIGHUP to Consul.
cat > /usr/local/bin/vault-agent-cert-refresh.sh << 'CERT_REFRESH'
#!/usr/bin/env bash
set -euo pipefail

METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance"
CURL_META='curl -sf -H Metadata-Flavor: Google'

VAULT_ADDR=$(curl -sf -H 'Metadata-Flavor: Google' "${METADATA_BASE}/attributes/vault-address")
INTER_PKI_PATH=$(curl -sf -H 'Metadata-Flavor: Google' "${METADATA_BASE}/attributes/vault-inter-pki-path")
DATACENTER=$(curl -sf -H 'Metadata-Flavor: Google' "${METADATA_BASE}/attributes/consul-datacenter")
VAULT_TOKEN=$(cat /opt/vault/vault-token)
VAULT_NAMESPACE="admin"
CERT_DIR="/etc/consul.d/tls"
TTL="72h"

echo "=== vault-agent-cert-refresh: issuing new TLS cert ==="
echo "  PKI path: ${INTER_PKI_PATH}, datacenter: ${DATACENTER}"

RESPONSE=$(curl -sk \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "X-Vault-Namespace: ${VAULT_NAMESPACE}" \
  "${VAULT_ADDR}/v1/${INTER_PKI_PATH}/issue/consul-server-tls" \
  -d "{\"common_name\":\"server.${DATACENTER}.consul\",\"alt_names\":\"localhost\",\"ip_sans\":\"127.0.0.1\",\"ttl\":\"${TTL}\"}")

if echo "${RESPONSE}" | jq -e '.errors' &>/dev/null && [ "$(echo "${RESPONSE}" | jq '.errors | length')" -gt 0 ]; then
  echo "ERROR: Vault PKI issue failed:"
  echo "${RESPONSE}" | jq .
  exit 1
fi

CERT=$(echo "${RESPONSE}" | jq -r '.data.certificate')
KEY=$(echo "${RESPONSE}"  | jq -r '.data.private_key')
CA=$(echo "${RESPONSE}"   | jq -r '.data.issuing_ca')

[ -z "${CERT}" ] || [ "${CERT}" = "null" ] && echo "ERROR: empty certificate" && exit 1

# Write atomically via temp files then rename
echo "${CERT}" | install -o vault -g vault -m 0640 /dev/stdin "${CERT_DIR}/server.crt.new"
echo "${KEY}"  | install -o vault -g vault -m 0640 /dev/stdin "${CERT_DIR}/server.key.new"
echo "${CA}"   | install -o vault -g vault -m 0640 /dev/stdin "${CERT_DIR}/ca-chain.pem.new"

mv "${CERT_DIR}/server.crt.new" "${CERT_DIR}/server.crt"
mv "${CERT_DIR}/server.key.new" "${CERT_DIR}/server.key"
mv "${CERT_DIR}/ca-chain.pem.new" "${CERT_DIR}/ca-chain.pem"

chgrp consul "${CERT_DIR}/server.crt" "${CERT_DIR}/server.key" "${CERT_DIR}/ca-chain.pem"

# No systemctl reload consul — Consul's auto_reload_config = true detects the
# cert file changes and hot-reloads TLS without SIGHUP. Sending SIGHUP would
# re-initialize the Vault CA provider and create a new Connect intermediate CA.
EXPIRY=$(openssl x509 -in "${CERT_DIR}/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
echo "  Done. Cert expiry: ${EXPIRY}"
CERT_REFRESH

chmod 0755 /usr/local/bin/vault-agent-cert-refresh.sh

# ---- systemd timer: periodic TLS cert renewal (belt-and-suspenders) ----
# vault-agent's pkiCert renewal tracking silently fails in some versions.
# This timer calls the cert-refresh script every 60h — well before the 72h
# cert TTL — to ensure renewal regardless of vault-agent's internal state.
# The script uses the existing vault-agent token (no restart, no new token,
# no Consul Connect CA rotation).
cat > /etc/systemd/system/vault-agent-cert-refresh.service << 'REFRESH_SVC'
[Unit]
Description=Renew Consul server TLS cert via direct Vault PKI call
After=vault-agent.service
Requires=vault-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-agent-cert-refresh.sh
StandardOutput=journal
StandardError=journal
REFRESH_SVC

cat > /etc/systemd/system/vault-agent-cert-refresh.timer << 'REFRESH_TIMER'
[Unit]
Description=Refresh Consul TLS cert every 60h (cert TTL is 72h)

[Timer]
OnBootSec=60h
OnUnitActiveSec=60h

[Install]
WantedBy=timers.target
REFRESH_TIMER

# ---- Enable services ----
systemctl daemon-reload
systemctl enable vault-agent-config.service vault-agent.service vault-agent-cert-refresh.timer

echo "=== vault-agent installation complete ==="
