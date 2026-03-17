# =============================================================================
# GKE Consul Dataplane Module — outputs.tf
# =============================================================================

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.main.name
}

output "cluster_endpoint" {
  description = "GKE cluster API server endpoint. Used for kubectl and Vault K8s auth config."
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-decoded GKE CA certificate PEM. Used for Vault Kubernetes auth backend config."
  value       = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  sensitive   = false
}

output "cluster_ca_certificate_b64" {
  description = "Base64-encoded GKE CA certificate. Needed for kubeconfig generation."
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = false
}

output "gke_node_sa_email" {
  description = "Email of the GKE node pool service account."
  value       = google_service_account.gke_nodes.email
}

output "consul_namespace" {
  description = "Kubernetes namespace where Consul is deployed (empty before endpoint is configured)."
  value       = length(kubernetes_namespace.consul) > 0 ? kubernetes_namespace.consul[0].metadata[0].name : ""
}

output "consul_ingress_gateway_ip" {
  description = "External IP of the Consul ingress gateway LoadBalancer (populated after Helm deploy)."
  value = try(
    helm_release.consul[0].status,
    "pending"
  )
}

output "kubeconfig_command" {
  description = "gcloud command to update local kubeconfig for this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${var.region} --project ${var.project_id}"
}
