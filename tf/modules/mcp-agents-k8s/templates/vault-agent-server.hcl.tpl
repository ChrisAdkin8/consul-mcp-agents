# exit_after_auth = false keeps the sidecar running to renew tokens.
# The init container overrides this via CLI flag -exit-after-auth=true.
exit_after_auth = false

vault {
  address   = "${vault_address}"
  namespace = "admin"
}

auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role = "${vault_k8s_role}"
      jwt  = "/var/run/secrets/vault/token"
    }
  }

  sink "file" {
    config = {
      path = "/home/vault/.vault-token"
    }
  }
}

# GCP access token for ${server_type} operations
template {
  contents    = "{{ with secret \"${gcp_secret_path}\" }}{{ .Data.token }}{{ end }}"
  destination = "/vault/secrets/gcp-token"
  perms       = "0640"
}

# Signal file
template {
  contents    = "ready"
  destination = "/vault/secrets/.ready"
  perms       = "0640"
}
