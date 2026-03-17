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

template {
  contents    = "{{ with secret \"secret/data/mcp-agents/llm-keys\" }}{{ .Data.data.anthropic_api_key }}{{ end }}"
  destination = "/vault/secrets/anthropic-key"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"secret/data/mcp-agents/llm-keys\" }}{{ .Data.data.openai_api_key }}{{ end }}"
  destination = "/vault/secrets/openai-key"
  perms       = "0640"
}

# Settings — pre-rendered YAML stored in Vault KV, written directly to file.
# Avoids vault-agent HCL heredoc indentation bug that corrupts YAML output.
template {
  destination = "/vault/secrets/settings.yaml"
  perms       = "0640"
  contents    = "{{ with secret \"secret/data/mcp-agents/config\" }}{{ .Data.data.settings_yaml }}{{ end }}"
}

# Capabilities/policies — same approach as settings above.
template {
  destination = "/vault/secrets/capabilities.yaml"
  perms       = "0640"
  contents    = "{{ with secret \"secret/data/mcp-agents/policies\" }}{{ .Data.data.policies_yaml }}{{ end }}"
}

# Signal file
template {
  contents    = "ready"
  destination = "/vault/secrets/.ready"
  perms       = "0640"
  command     = "touch /tmp/vault-agent-ready"
}
