# =============================================================================
# Vault PKI for Consul Module — policy.tf
#
# Vault policies follow least-privilege: each identity gets exactly the
# capabilities it needs and nothing more.
#
# consul-server-policy:
#   Allows Consul servers to:
#     • Read the Root and Intermediate CA certs (for trust chain distribution)
#     • Sign leaf certificates via the connect CA role (Connect CA provider)
#     • Sign server TLS certificates via the server TLS role
#     • Renew their own Vault token
#
# consul-connect-ca-policy:
#   Subset of consul-server-policy used by the Consul CA provider process
#   when running in dataplane mode — only needs sign access.
# =============================================================================

resource "vault_policy" "consul_server" {
  name = "consul-server-policy"

  policy = <<-EOT
    # ---- Root CA: read-only (distribute trust chain to clients) ----
    path "${var.root_pki_path}/cert/ca" {
      capabilities = ["read"]
    }

    path "${var.root_pki_path}/ca/pem" {
      capabilities = ["read"]
    }

    path "${var.root_pki_path}/crl/rotate" {
      capabilities = ["create", "update"]
    }

    # ---- Root CA: allow Consul to sign new intermediate CAs ----
    path "${var.root_pki_path}/root/sign-intermediate" {
      capabilities = ["create", "update"]
    }

    # ---- Intermediate CA: full management for Consul Connect CA provider ----
    # Consul generates an intermediate inside Vault and signs it with the root
    path "${var.intermediate_pki_path}/intermediate/generate/internal" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/intermediate/set-signed" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/config/urls" {
      capabilities = ["create", "update", "read"]
    }

    path "${var.intermediate_pki_path}/config/ca" {
      capabilities = ["create", "update", "read"]
    }

    path "${var.intermediate_pki_path}/config/issuers" {
      capabilities = ["create", "update", "read", "list", "delete"]
    }

    path "${var.intermediate_pki_path}/issuers" {
      capabilities = ["list", "read"]
    }

    path "${var.intermediate_pki_path}/issuer/*" {
      capabilities = ["create", "update", "read", "delete"]
    }

    path "${var.intermediate_pki_path}/key/*" {
      capabilities = ["create", "update", "read", "delete"]
    }

    path "${var.intermediate_pki_path}/keys" {
      capabilities = ["list", "read"]
    }

    path "${var.intermediate_pki_path}/sign/consul-connect" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/sign/consul-server-tls" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/issue/consul-server-tls" {
      capabilities = ["create", "update"]
    }

    # Consul Connect CA creates/updates roles dynamically for leaf cert issuance
    path "${var.intermediate_pki_path}/roles/*" {
      capabilities = ["create", "update", "delete", "read"]
    }

    path "${var.intermediate_pki_path}/issue/*" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/sign/*" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/tidy" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/config/auto-tidy" {
      capabilities = ["create", "update", "read"]
    }

    path "${var.intermediate_pki_path}/cert/ca" {
      capabilities = ["read"]
    }

    path "${var.intermediate_pki_path}/ca/pem" {
      capabilities = ["read"]
    }

    path "${var.intermediate_pki_path}/ca_chain" {
      capabilities = ["read"]
    }

    path "${var.intermediate_pki_path}/crl/rotate" {
      capabilities = ["create", "update"]
    }

    # ---- Token self-renewal ----
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "consul_connect_ca" {
  name = "consul-connect-ca-policy"

  policy = <<-EOT
    # Minimal policy for the Consul Connect CA provider process.
    # Used by GKE-based Consul dataplane components that issue leaf certs.

    path "${var.intermediate_pki_path}/sign/consul-connect" {
      capabilities = ["create", "update"]
    }

    path "${var.intermediate_pki_path}/cert/ca" {
      capabilities = ["read"]
    }

    path "${var.intermediate_pki_path}/ca/pem" {
      capabilities = ["read"]
    }

    path "${var.intermediate_pki_path}/ca_chain" {
      capabilities = ["read"]
    }

    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}
