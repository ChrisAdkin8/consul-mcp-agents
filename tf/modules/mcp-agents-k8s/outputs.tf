# =============================================================================
# MCP Agents K8s Module — outputs.tf
# =============================================================================

output "namespace" {
  description = "Kubernetes namespace where MCP agents are deployed."
  value       = kubernetes_namespace.mcp_agents.metadata[0].name
}

output "agent_deployment_name" {
  description = "Name of the MCP agent Kubernetes Deployment."
  value       = kubernetes_deployment.mcp_agent.metadata[0].name
}

output "server_deployment_names" {
  description = "Names of the MCP server Kubernetes Deployments."
  value       = { for k, v in kubernetes_deployment.mcp_server : k => v.metadata[0].name }
}

output "server_sa_names" {
  description = "Names of the MCP server Kubernetes ServiceAccounts."
  value       = { for k, v in kubernetes_service_account.mcp_server : k => v.metadata[0].name }
}

output "mcp_agent_sa_name" {
  description = "Name of the mcp-agent Kubernetes ServiceAccount."
  value       = kubernetes_service_account.mcp_agent.metadata[0].name
}

output "lb_service_name" {
  description = "Name of the external LoadBalancer service."
  value       = kubernetes_service.mcp_agent.metadata[0].name
}

output "access_instructions" {
  description = "Instructions for accessing the MCP agent web terminal."
  value       = <<-EOT
    MCP Agent Web Terminal
    ======================
    Service:  kubectl get svc mcp-agent -n ${kubernetes_namespace.mcp_agents.metadata[0].name}
    Access:   http://<EXTERNAL-IP>/
    Auth:     Basic auth (configured via var.ttyd_credential)

    Consul Mesh Services:
      - mcp-agent         → CLI + web terminal
      - mcp-data-server   → GCS + BigQuery MCP server
      - mcp-compute-server → GCE MCP server

    Intentions enforce: mcp-agent → mcp-data-server, mcp-agent → mcp-compute-server
  EOT
}
