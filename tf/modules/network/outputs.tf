# =============================================================================
# Network Module — outputs.tf
# =============================================================================

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.main.name
}

output "network_self_link" {
  description = "Self-link of the VPC network (used for subnet/firewall association)."
  value       = google_compute_network.main.self_link
}

output "subnet_name" {
  description = "Name of the primary subnet."
  value       = google_compute_subnetwork.primary.name
}

output "subnet_self_link" {
  description = "Self-link of the primary subnet (passed to GKE cluster config)."
  value       = google_compute_subnetwork.primary.self_link
}

output "subnet_cidr" {
  description = "CIDR of the primary subnet."
  value       = google_compute_subnetwork.primary.ip_cidr_range
}

output "pods_range_name" {
  description = "Name of the secondary IP range for GKE pods."
  value       = google_compute_subnetwork.primary.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Name of the secondary IP range for GKE services."
  value       = google_compute_subnetwork.primary.secondary_ip_range[1].range_name
}

output "router_name" {
  description = "Name of the Cloud Router."
  value       = google_compute_router.main.name
}
