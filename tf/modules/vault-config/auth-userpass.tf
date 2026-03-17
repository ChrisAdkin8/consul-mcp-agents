# =============================================================================
# Vault Config Module — auth-userpass.tf
#
# Configures Vault userpass authentication for human operators who log in
# via the MCP agent prompt/cli.py. This replaces the setup_vault.sh script
# from the original repo — all user management is now in Terraform.
#
# Role → Policy mapping:
#   operator  → operator-policy  (full CRUD on all tools)
#   analyst   → analyst-policy   (read-only data + limited compute)
#   viewer    → viewer-policy    (read-only data only)
#
# Password management:
#   Passwords are passed as sensitive Terraform variables. In production,
#   rotate passwords via: vault write auth/userpass/users/<name> password=<new>
#   (do not update in Terraform to avoid state containing cleartext passwords).
# =============================================================================

resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "userpass"
  description = "Username/password auth for human operators using the MCP agent CLI"
}

# ---------------------------------------------------------------------------
# Vault policies for human roles
# Each policy grants exactly the GCP secrets engine paths that the role
# needs, plus KV metadata reads (for policy/config rendering in the CLI).
# ---------------------------------------------------------------------------

resource "vault_policy" "operator" {
  name = "operator-policy"

  policy = <<-EOT
    # Operator: full access to both agent GCP token paths
    path "${var.gcp_secrets_mount_path}/impersonated-account/data-agent-gcp/token" {
      capabilities = ["read"]
    }
    path "${var.gcp_secrets_mount_path}/impersonated-account/compute-agent-gcp/token" {
      capabilities = ["read"]
    }
    # Config and policies — read-only for the CLI to load them
    path "secret/data/mcp-agents/config" {
      capabilities = ["read"]
    }
    path "secret/data/mcp-agents/policies" {
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

resource "vault_policy" "analyst" {
  name = "analyst-policy"

  policy = <<-EOT
    # Analyst: access to both agent token paths (tool filtering is done
    # by the application policy layer in capabilities.yaml)
    path "${var.gcp_secrets_mount_path}/impersonated-account/data-agent-gcp/token" {
      capabilities = ["read"]
    }
    path "${var.gcp_secrets_mount_path}/impersonated-account/compute-agent-gcp/token" {
      capabilities = ["read"]
    }
    path "secret/data/mcp-agents/config" {
      capabilities = ["read"]
    }
    path "secret/data/mcp-agents/policies" {
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

resource "vault_policy" "viewer" {
  name = "viewer-policy"

  policy = <<-EOT
    # Viewer: data agent only — compute agent path is denied (omitted = deny)
    path "${var.gcp_secrets_mount_path}/impersonated-account/data-agent-gcp/token" {
      capabilities = ["read"]
    }
    path "secret/data/mcp-agents/config" {
      capabilities = ["read"]
    }
    path "secret/data/mcp-agents/policies" {
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

# ---------------------------------------------------------------------------
# User accounts
# Defined as a map so operators can extend it without modifying this file.
# ---------------------------------------------------------------------------
resource "vault_generic_endpoint" "users" {
  # Usernames are not secret — use nonsensitive(keys()) so Terraform can use
  # them as for_each instance keys. Passwords remain sensitive via var.vault_users.
  for_each = toset(nonsensitive(keys(var.vault_users)))

  path                 = "auth/userpass/users/${each.key}"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = var.vault_users[each.key].password
    policies = var.vault_users[each.key].policies
  })

  depends_on = [vault_auth_backend.userpass]
}
