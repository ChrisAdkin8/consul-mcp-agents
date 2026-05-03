# =============================================================================
# Vault PKI for Consul Module — pki.tf
#
# Configures HCP Vault as the Certificate Authority for Consul Connect.
#
# Certificate hierarchy:
#
#   Root CA  (connect-root)
#     └── Intermediate CA  (connect-intermediate)
#           └── Consul Connect leaf certs  (issued at runtime by Consul)
#
# The Root CA is kept offline-equivalent: Vault holds the private key and it
# is never exported. The Intermediate CA signs new leaf certs on demand.
# Consul is configured with ca_provider = "vault" pointing at the
# Intermediate CA mount — Consul calls vault_pki_secret_backend_role to
# issue short-lived mTLS leaf certs for each service proxy.
#
# TTL design:
#   Root CA           10 years  — long-lived, rarely rotated
#   Intermediate CA    5 years  — rotated annually in practice
#   Leaf certs        72 hours  — Consul auto-rotates before expiry
# =============================================================================

# ---------------------------------------------------------------------------
# Root CA PKI mount
# ---------------------------------------------------------------------------
resource "vault_mount" "connect_root" {
  path                      = var.root_pki_path
  type                      = "pki"
  description               = "Root Certificate Authority for Consul Connect service mesh"
  default_lease_ttl_seconds = 3153600   # 36.5 days
  max_lease_ttl_seconds     = 315360000 # 10 years

  # Destroying the root CA invalidates every Consul mTLS cert in the mesh.
  lifecycle {
    prevent_destroy = true
  }
}

# Self-signed Root CA certificate — private key stays in Vault (type=internal)
# EC P-384 is used instead of RSA 4096: equivalent security, far faster to generate
# on shared HCP Vault (avoids context deadline exceeded on key gen).
resource "vault_pki_secret_backend_root_cert" "connect_root" {
  backend     = vault_mount.connect_root.path
  type        = "internal"
  common_name = "Consul Connect Root CA — ${var.datacenter}"
  ttl         = "315360000" # 10 years
  key_type    = "ec"
  key_bits    = 384
  issuer_name = "consul-connect-root"

  # Subject fields for X.509 clarity
  organization = var.org_name
  country      = var.country
  locality     = var.locality
  province     = var.province
}

# Enable the Root CA issuer URL and CRL distribution points.
# Consul validates CRLs when checking certificate revocation.
resource "vault_pki_secret_backend_config_urls" "connect_root" {
  backend                 = vault_mount.connect_root.path
  issuing_certificates    = ["${var.vault_addr}/v1/${var.root_pki_path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${var.root_pki_path}/crl"]
}

# ---------------------------------------------------------------------------
# Intermediate CA PKI mount
# ---------------------------------------------------------------------------
resource "vault_mount" "connect_intermediate" {
  path                      = var.intermediate_pki_path
  type                      = "pki"
  description               = "Intermediate CA for Consul Connect — issues leaf mTLS certs"
  max_lease_ttl_seconds     = 3153600 # 36.5 days max for intermediate CA / leaf certs
  default_lease_ttl_seconds = 259200  # 72 hours default for leaf certs

  lifecycle {
    prevent_destroy = true
  }
}

# Generate intermediate CSR (private key stays in Vault)
# EC P-256: fast, well-supported, standard for intermediate CAs.
resource "vault_pki_secret_backend_intermediate_cert_request" "connect" {
  backend     = vault_mount.connect_intermediate.path
  type        = "internal"
  common_name = "Consul Connect Intermediate CA — ${var.datacenter}"
  key_type    = "ec"
  key_bits    = 256
}

# Root CA signs the intermediate CSR
resource "vault_pki_secret_backend_root_sign_intermediate" "connect" {
  backend     = vault_mount.connect_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.connect.csr
  common_name = "Consul Connect Intermediate CA — ${var.datacenter}"
  ttl         = "157680000" # 5 years
  format      = "pem_bundle"
  issuer_ref  = vault_pki_secret_backend_root_cert.connect_root.issuer_id
}

# Import the signed intermediate certificate back into the intermediate mount
resource "vault_pki_secret_backend_intermediate_set_signed" "connect" {
  backend     = vault_mount.connect_intermediate.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.connect.certificate_bundle
}

# Configure issuer URLs on the intermediate mount
resource "vault_pki_secret_backend_config_urls" "connect_intermediate" {
  backend                 = vault_mount.connect_intermediate.path
  issuing_certificates    = ["${var.vault_addr}/v1/${var.intermediate_pki_path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${var.intermediate_pki_path}/crl"]
}

# ---------------------------------------------------------------------------
# PKI role — Consul Connect CA
#
# Consul's Vault CA provider calls this role to sign leaf certs. The role
# allows any common_name because Consul generates names in the form:
#   <service-name>.svc.<datacenter>.consul
# and also uses SPIFFE URIs, so enforce_hostnames must be false.
# ---------------------------------------------------------------------------
resource "vault_pki_secret_backend_role" "consul_connect" {
  backend           = vault_mount.connect_intermediate.path
  name              = "consul-connect"
  ttl               = 86400  # 24 hours default leaf TTL
  max_ttl           = 259200 # 72 hours maximum leaf TTL
  allow_any_name    = true
  enforce_hostnames = false
  generate_lease    = true
  key_type          = "ec"
  key_bits          = 256

  # Allow SPIFFE URIs (spiffe://datacenter/ns/default/dc/dc1/svc/...)
  allowed_uri_sans = ["spiffe://*"]
  key_usage        = ["DigitalSignature", "KeyEncipherment"]
  ext_key_usage    = ["ServerAuth", "ClientAuth"]
}

# ---------------------------------------------------------------------------
# PKI role — Consul server TLS
#
# Consul server-to-server gossip and RPC use TLS certificates issued by
# this role. Common names are scoped to the datacenter domain.
# ---------------------------------------------------------------------------
resource "vault_pki_secret_backend_role" "consul_server_tls" {
  backend            = vault_mount.connect_intermediate.path
  name               = "consul-server-tls"
  ttl                = 86400
  max_ttl            = 259200
  allowed_domains    = ["server.${var.datacenter}.consul", "localhost"]
  allow_subdomains   = false
  allow_bare_domains = true
  generate_lease     = true
  key_type           = "ec"
  key_bits           = 256
}
