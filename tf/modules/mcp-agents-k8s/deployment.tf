# =============================================================================
# MCP Agents K8s Module — deployment.tf
#
# Deployments for Consul service mesh integration:
#   1. mcp-agent           — CLI + ttyd web terminal (user-facing, unique)
#   2. mcp-data-server     — MCP server for GCS + BigQuery (SSE transport)
#   3. mcp-compute-server  — MCP server for GCE (SSE transport)
#
# MCP servers (2 + 3) share the same pod spec via for_each over local.mcp_servers.
# Each deployment gets a Consul Envoy sidecar via connect-inject.
# The agent pod defines explicit upstreams to MCP servers on localhost ports.
# Consul intentions control which services can communicate.
# =============================================================================

locals {
  mcp_servers = {
    "mcp-data-server" = {
      module          = "vault_mcp_agents.mcp.data_server"
      gcp_secret_path = "gcp/impersonated-account/data-agent-gcp/token"
      description     = "data (GCS + BigQuery)"
    }
    "mcp-compute-server" = {
      module          = "vault_mcp_agents.mcp.compute_server"
      gcp_secret_path = "gcp/impersonated-account/compute-agent-gcp/token"
      description     = "compute (GCE)"
    }
  }
}

# -----------------------------------------------------------------------------
# MCP Agent Deployment (CLI + ttyd) — unique, not part of for_each
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "mcp_agent" {
  metadata {
    name      = "mcp-agent"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "mcp-agent"
      "app.kubernetes.io/version"   = var.app_image_tag
      "app.kubernetes.io/component" = "agent"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "mcp-agent"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "mcp-agent"
          "app.kubernetes.io/component" = "agent"
        }
        annotations = {
          # Consul service mesh — inject Envoy sidecar
          "consul.hashicorp.com/connect-inject"            = "true"
          "consul.hashicorp.com/service-name"              = "mcp-agent"
          "consul.hashicorp.com/transparent-proxy"         = "false"
          "consul.hashicorp.com/connect-service-upstreams" = "mcp-data-server:20000,mcp-compute-server:20001"

          # Force pod restart when vault-agent config changes
          "checksum/vault-agent-config" = sha256(kubernetes_config_map.vault_agent_agent.data["vault-agent.hcl"])
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.mcp_agent.metadata[0].name
        automount_service_account_token = true

        # vault-agent init container
        init_container {
          name              = "vault-agent-init"
          image             = "hashicorp/vault:${var.vault_agent_version}"
          image_pull_policy = "IfNotPresent"

          command = [
            "vault", "agent",
            "-config=/etc/vault-agent/vault-agent.hcl",
            "-exit-after-auth=true",
          ]

          env {
            name  = "VAULT_NAMESPACE"
            value = "admin"
          }

          volume_mount {
            name       = "vault-sa-token"
            mount_path = "/var/run/secrets/vault"
            read_only  = true
          }
          volume_mount {
            name       = "vault-agent-config"
            mount_path = "/etc/vault-agent"
          }
          volume_mount {
            name       = "vault-secrets"
            mount_path = "/vault/secrets"
          }
          volume_mount {
            name       = "vault-token"
            mount_path = "/home/vault"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          security_context {
            run_as_user                = 100
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # Main container: mcp-app (Python CLI + ttyd)
        container {
          name              = "mcp-app"
          image             = "${var.app_image_repository}:${var.app_image_tag}"
          image_pull_policy = "Always"

          command = ["/app/docker/entrypoint.sh"]

          env {
            name  = "VAULT_ADDR"
            value = var.vault_address
          }
          env {
            name  = "VAULT_NAMESPACE"
            value = "admin"
          }
          env {
            name  = "MCP_CONFIG_PATH"
            value = "/vault/secrets/settings.yaml"
          }
          env {
            name  = "MCP_POLICIES_PATH"
            value = "/vault/secrets/capabilities.yaml"
          }
          env {
            name  = "GCP_PROJECT_ID"
            value = var.gcp_project_id
          }
          env {
            name  = "VAULT_AGENT_READY_FILE"
            value = "/tmp/vault-agent-ready"
          }
          env {
            name  = "TTYD_CREDENTIAL"
            value = var.ttyd_credential
          }

          port {
            name           = "web-terminal"
            container_port = 7681
            protocol       = "TCP"
          }

          volume_mount {
            name       = "vault-secrets"
            mount_path = "/vault/secrets"
            read_only  = true
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }

          security_context {
            run_as_user                = 1000
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
            capabilities {
              drop = ["ALL"]
            }
          }

          liveness_probe {
            tcp_socket {
              port = 7681
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = ["test", "-f", "/tmp/vault-agent-ready"]
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            failure_threshold     = 6
          }
        }

        # Volumes
        volume {
          name = "vault-sa-token"
          projected {
            sources {
              service_account_token {
                audience           = "vault"
                expiration_seconds = 7200
                path               = "token"
              }
            }
          }
        }

        volume {
          name = "vault-agent-config"
          config_map {
            name = kubernetes_config_map.vault_agent_agent.metadata[0].name
          }
        }

        volume {
          name = "vault-secrets"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "vault-token"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }

        termination_grace_period_seconds = 60

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              "app.kubernetes.io/name" = "mcp-agent"
            }
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# MCP Server Deployments (for_each) — SSE transport, GCP credentials from Vault
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "mcp_server" {
  for_each = local.mcp_servers

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = each.key
      "app.kubernetes.io/version"   = var.app_image_tag
      "app.kubernetes.io/component" = "mcp-server"
      "app.kubernetes.io/part-of"   = "vault-mcp-agents"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = each.key
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = each.key
          "app.kubernetes.io/component" = "mcp-server"
        }
        annotations = {
          "consul.hashicorp.com/connect-inject"    = "true"
          "consul.hashicorp.com/service-name"      = each.key
          "consul.hashicorp.com/transparent-proxy" = "false"
          "consul.hashicorp.com/service-port"      = "8080"

          "checksum/vault-agent-config" = sha256(kubernetes_config_map.vault_agent_server[each.key].data["vault-agent.hcl"])
        }
      }

      spec {
        service_account_name            = kubernetes_service_account.mcp_server[each.key].metadata[0].name
        automount_service_account_token = true

        # vault-agent init — renders GCP credentials
        init_container {
          name              = "vault-agent-init"
          image             = "hashicorp/vault:${var.vault_agent_version}"
          image_pull_policy = "IfNotPresent"

          command = [
            "vault", "agent",
            "-config=/etc/vault-agent/vault-agent.hcl",
            "-exit-after-auth=true",
          ]

          env {
            name  = "VAULT_NAMESPACE"
            value = "admin"
          }

          volume_mount {
            name       = "vault-sa-token"
            mount_path = "/var/run/secrets/vault"
            read_only  = true
          }
          volume_mount {
            name       = "vault-agent-config"
            mount_path = "/etc/vault-agent"
          }
          volume_mount {
            name       = "vault-secrets"
            mount_path = "/vault/secrets"
          }
          volume_mount {
            name       = "vault-token"
            mount_path = "/home/vault"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          security_context {
            run_as_user                = 100
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # Main container: MCP server (SSE)
        container {
          name              = "mcp-server"
          image             = "${var.app_image_repository}:${var.app_image_tag}"
          image_pull_policy = "Always"

          # GCP token is read from file by TokenRefresher (not env var).
          # vault-agent sidecar re-renders the file when the lease expires.
          command = ["python", "-m", each.value.module]

          env {
            name  = "MCP_TRANSPORT"
            value = "sse"
          }
          env {
            name  = "MCP_PORT"
            value = "8080"
          }
          env {
            name  = "GCP_PROJECT_ID"
            value = var.gcp_project_id
          }
          env {
            name  = "GCP_TOKEN_FILE"
            value = "/vault/secrets/gcp-token"
          }

          port {
            name           = "mcp-sse"
            container_port = 8080
            protocol       = "TCP"
          }

          volume_mount {
            name       = "vault-secrets"
            mount_path = "/vault/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          security_context {
            run_as_user                = 1000
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
            capabilities {
              drop = ["ALL"]
            }
          }

          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }

          readiness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 3
          }
        }

        # vault-agent sidecar — keeps running to re-render GCP token on lease expiry
        container {
          name              = "vault-agent-sidecar"
          image             = "hashicorp/vault:${var.vault_agent_version}"
          image_pull_policy = "IfNotPresent"

          command = [
            "vault", "agent",
            "-config=/etc/vault-agent/vault-agent.hcl",
          ]

          env {
            name  = "VAULT_NAMESPACE"
            value = "admin"
          }

          volume_mount {
            name       = "vault-sa-token"
            mount_path = "/var/run/secrets/vault"
            read_only  = true
          }
          volume_mount {
            name       = "vault-agent-config"
            mount_path = "/etc/vault-agent"
          }
          volume_mount {
            name       = "vault-secrets"
            mount_path = "/vault/secrets"
          }
          volume_mount {
            name       = "vault-token"
            mount_path = "/home/vault"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }

          security_context {
            run_as_user                = 100
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        # Volumes
        volume {
          name = "vault-sa-token"
          projected {
            sources {
              service_account_token {
                audience           = "vault"
                expiration_seconds = 7200
                path               = "token"
              }
            }
          }
        }

        volume {
          name = "vault-agent-config"
          config_map {
            name = kubernetes_config_map.vault_agent_server[each.key].metadata[0].name
          }
        }

        volume {
          name = "vault-secrets"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "vault-token"
          empty_dir {
            medium = "Memory"
          }
        }
      }
    }
  }
}
