# =============================================================================
# Vault Config Module — kv.tf
#
# Stores all application configuration in Vault KV v2. Nothing lives in
# ConfigMaps, environment variables, or files on disk — vault-agent renders
# everything from Vault at pod startup.
#
# Secret tree:
#   secret/
#     mcp-agents/
#       config      — settings.yaml content (Vault addr, agent defs, LLM)
#       policies    — capabilities.yaml content (role → tool access matrix)
#       llm-keys    — Anthropic and OpenAI API keys
#     consul/
#       acl-token   — Consul bootstrap ACL token (written post-bootstrap)
# =============================================================================

# ---------------------------------------------------------------------------
# KV v2 mount
# ---------------------------------------------------------------------------
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV v2 store for MCP agent application configuration and secrets"
}

# ---------------------------------------------------------------------------
# MCP agent configuration (replaces config/settings.yaml on disk)
#
# The vault-agent sidecar renders this into /app/config/settings.yaml
# at pod startup using a template. Changing this secret and restarting
# pods is the deployment mechanism for config changes.
# ---------------------------------------------------------------------------
resource "vault_kv_secret_v2" "mcp_config" {
  mount               = vault_mount.secret.path
  name                = "mcp-agents/config"
  cas                 = 0 # Create-or-update; increment for CAS enforcement
  delete_all_versions = false

  # Pre-rendered YAML stored as a single string. vault-agent reads this value
  # and writes it directly to /vault/secrets/settings.yaml — no HCL heredoc
  # template rendering, which avoids vault-agent's heredoc indentation bug.
  data_json = jsonencode({
    settings_yaml = yamlencode({
      vault = {
        address             = var.vault_private_endpoint_url
        namespace           = "admin"
        auth_method         = "kubernetes"
        gcp_secrets_mount   = var.gcp_secrets_mount_path
        agent_approle_mount = "approle"
      }
      gcp = {
        project_id = var.gcp_project_id
        region     = var.gcp_region
      }
      llm = {
        provider    = var.llm_provider
        model       = var.llm_model
        temperature = 0
      }
      agents = {
        data_agent = {
          description              = "Handles GCS and BigQuery operations"
          mcp_server               = "data_server"
          gcp_impersonated_account = "data-agent-gcp"
        }
        compute_agent = {
          description              = "Handles GCE instance and infrastructure operations"
          mcp_server               = "compute_server"
          gcp_impersonated_account = "compute-agent-gcp"
        }
      }
      mcp_servers = {
        data_server = {
          transport = "sse"
          url       = "http://localhost:20000/sse"
        }
        compute_server = {
          transport = "sse"
          url       = "http://localhost:20001/sse"
        }
      }
    })
  })
}

# ---------------------------------------------------------------------------
# Role-based access control matrix (replaces policies/capabilities.yaml)
#
# vault-agent renders this into /app/policies/capabilities.yaml.
# Updating this secret changes what tools each user role can invoke
# without rebuilding the container image.
# ---------------------------------------------------------------------------
resource "vault_kv_secret_v2" "mcp_policies" {
  mount               = vault_mount.secret.path
  name                = "mcp-agents/policies"
  delete_all_versions = false

  # Pre-rendered YAML — same approach as settings_yaml above.
  data_json = jsonencode({
    policies_yaml = yamlencode({
      roles = {
        operator = {
          vault_policy = "operator-policy"
          agents = {
            data_agent = {
              allowed_tools     = ["list_buckets", "read_object", "write_object", "delete_object", "query_bigquery", "list_datasets", "create_dataset"]
              max_gcp_token_ttl = "5m"
            }
            compute_agent = {
              allowed_tools     = ["list_instances", "get_instance", "start_instance", "stop_instance", "create_instance", "delete_instance"]
              max_gcp_token_ttl = "5m"
            }
          }
        }
        analyst = {
          vault_policy = "analyst-policy"
          agents = {
            data_agent = {
              allowed_tools     = ["list_buckets", "read_object", "query_bigquery", "list_datasets"]
              max_gcp_token_ttl = "5m"
            }
            compute_agent = {
              allowed_tools     = ["list_instances", "get_instance"]
              max_gcp_token_ttl = "5m"
            }
          }
        }
        viewer = {
          vault_policy = "viewer-policy"
          agents = {
            data_agent = {
              allowed_tools     = ["list_buckets", "read_object", "list_datasets"]
              max_gcp_token_ttl = "5m"
            }
            compute_agent = {
              allowed_tools     = ["list_instances"]
              max_gcp_token_ttl = "5m"
            }
          }
        }
      }
    })
  })
}

# ---------------------------------------------------------------------------
# LLM API keys — never in environment variables or ConfigMaps
#
# vault-agent injects these as environment variables into the MCP agent
# container using the env template stanza. The ANTHROPIC_API_KEY and
# OPENAI_API_KEY env vars are only materialised inside the pod — they
# never appear in K8s manifests or Terraform state after initial write.
# ---------------------------------------------------------------------------
resource "vault_kv_secret_v2" "llm_keys" {
  mount               = vault_mount.secret.path
  name                = "mcp-agents/llm-keys"
  delete_all_versions = false

  data_json = jsonencode({
    anthropic_api_key = var.anthropic_api_key
    openai_api_key    = var.openai_api_key
  })
}

# ---------------------------------------------------------------------------
# Consul ACL bootstrap token — managed by Terraform via var.consul_bootstrap_token.
# The Taskfile consul:bootstrap-acl task writes the token to terraform.tfvars,
# then subsequent applies update this secret to match.
# ---------------------------------------------------------------------------
resource "vault_kv_secret_v2" "consul_acl_token" {
  mount               = vault_mount.secret.path
  name                = "consul/acl-token"
  delete_all_versions = false

  data_json = jsonencode({
    token = var.consul_bootstrap_token
  })
}
