# =============================================================================
# MCP Agents K8s Module — consul.tf
#
# Consul service intentions controlling which services can communicate.
# Uses consul_config_entry_service_intentions (Consul API) instead of
# kubernetes_manifest (K8s CRD) to avoid plan-time CRD validation failures
# when the Consul Helm chart hasn't been installed yet.
#
# Topology:
#   mcp-agent → mcp-data-server    (allow)
#   mcp-agent → mcp-compute-server (allow)
#   * → mcp-data-server            (deny, implicit)
#   * → mcp-compute-server         (deny, implicit)
# =============================================================================

resource "consul_config_entry_service_intentions" "mcp_server" {
  for_each = local.mcp_servers

  name = each.key

  sources {
    name   = "mcp-agent"
    action = "allow"
  }

  # Consul computes `precedence` server-side from source/destination wildcard
  # specificity and reads it back; the provider would otherwise show recurring
  # `precedence: 9 -> null` drift on every plan.
  lifecycle {
    ignore_changes = [sources[0].precedence]
  }
}
