# =============================================================================
# MCP Agents K8s Module — service.tf
#
# Services for each component:
#   1. mcp-agent (LoadBalancer) — Consul mesh + external user access via browser
#   2. MCP servers (ClusterIP, for_each) — mesh-internal, agent connects via upstreams
# =============================================================================

# Agent service — Consul mesh registration + external LoadBalancer access.
# Name MUST match the service account name ("mcp-agent") — consul-connect-inject-init
# discovers selecting K8s Services and registers them as Consul services; a name
# mismatch causes "service account doesn't match Consul service name" errors.
resource "kubernetes_service" "mcp_agent" {
  metadata {
    name      = "mcp-agent"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "mcp-agent"
      "app.kubernetes.io/component" = "service"
    }
    annotations = {
      "cloud.google.com/load-balancer-type" = "External"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "mcp-agent"
    }

    port {
      name        = "web-terminal"
      port        = 80
      target_port = 7681
      protocol    = "TCP"
    }

    type                        = "LoadBalancer"
    load_balancer_source_ranges = var.allowed_ingress_cidrs
  }
}

# MCP Server Services — mesh-internal only (agent connects via Consul upstreams)
resource "kubernetes_service" "mcp_server" {
  for_each = local.mcp_servers

  metadata {
    name      = each.key
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = each.key
      "app.kubernetes.io/component" = "service"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = each.key
    }

    port {
      name        = "mcp-sse"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# PodDisruptionBudget — ensure at least 1 agent pod is always available
resource "kubernetes_pod_disruption_budget_v1" "mcp_agent" {
  metadata {
    name      = "mcp-agent-pdb"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "mcp-agent"
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "mcp_server" {
  for_each = local.mcp_servers

  metadata {
    name      = "${each.key}-pdb"
    namespace = kubernetes_namespace.mcp_agents.metadata[0].name
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = each.key
      }
    }
  }
}
