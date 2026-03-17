# =============================================================================
# Consul Module — outputs.tf
# =============================================================================

output "consul_server_sa_email" {
  description = "Email of the GCP SA attached to Consul server VMs."
  value       = var.consul_server_sa_email
}

output "internal_server_ips" {
  description = "List of internal (private) IP addresses of Consul server VMs. Used by GKE pods to reach the control plane."
  value       = [for inst in google_compute_instance.consul_server : inst.network_interface[0].network_ip]
}

output "consul_server_instance_names" {
  description = "Names of the Consul server GCE instances."
  value       = [for inst in google_compute_instance.consul_server : inst.name]
}

output "consul_server_zones" {
  description = "Zones of the Consul server instances."
  value       = [for inst in google_compute_instance.consul_server : inst.zone]
}

