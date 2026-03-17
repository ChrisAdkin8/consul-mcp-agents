# =============================================================================
# Network Module — main.tf
#
# Creates a production-ready VPC for the consul-mcp-gke scenario:
#   • A single GCP VPC (global, auto-mode disabled for explicit control)
#   • Primary subnet for Consul VMs and GKE primary nodes
#   • GKE secondary subnet ranges for pods and services (required by GKE)
#   • Cloud Router + Cloud NAT for egress from private instances
#   • Firewall rules: internal-only Consul traffic + IAP SSH for operators
#
# Design rationale:
#   Private subnets (no external IPs on VMs) + Cloud NAT means Consul VMs
#   can reach GCP APIs and HCP Vault without public IPs, reducing attack surface.
#   IAP SSH allows operator access without a bastion host or VPN.
# =============================================================================

# ---------------------------------------------------------------------------
# VPC — global, custom-mode (auto-mode = false)
# ---------------------------------------------------------------------------
resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  description             = "Primary VPC for consul-mcp-gke: Consul VMs, GKE cluster, Cloud NAT egress"
}

# ---------------------------------------------------------------------------
# Primary subnet (Consul VMs + GKE nodes)
# Secondary ranges are required by GKE for pods and services (VPC-native).
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "primary" {
  project       = var.project_id
  name          = "${var.name_prefix}-snet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id
  description   = "Primary subnet: Consul VMs and GKE node primary IPs"

  # Required for GKE VPC-native (alias IP) mode
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Enable Private Google Access: instances without public IPs can reach
  # Google APIs (GCS, BigQuery, etc.) and HCP Vault via the private endpoint.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Cloud Router — required by Cloud NAT
# ---------------------------------------------------------------------------
resource "google_compute_router" "main" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.main.id
}

# ---------------------------------------------------------------------------
# Cloud NAT — egress for private VMs (Consul, GKE nodes)
# Consul VMs have no public IPs but need outbound connectivity for:
#   • Installing packages during first boot (via Packer image, minimised)
#   • Reaching HCP Vault public endpoint during bootstrap (before peering)
#   • GCP metadata server (available without NAT, but NAT is needed for others)
# ---------------------------------------------------------------------------
resource "google_compute_router_nat" "main" {
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Firewall — allow internal Consul traffic
# Consul ports: 8300 (RPC), 8301 (Serf LAN), 8302 (Serf WAN), 8500 (HTTP),
#               8501 (HTTPS), 8502 (gRPC), 8503 (gRPC TLS)
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "consul_internal" {
  project     = var.project_id
  name        = "${var.name_prefix}-consul-internal"
  network     = google_compute_network.main.id
  description = "Allow all Consul protocols between Consul servers and GKE nodes"
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["8300", "8301", "8302", "8500", "8501", "8502", "8503"]
  }
  allow {
    protocol = "udp"
    ports    = ["8301", "8302"]
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr]
  target_tags   = ["consul-server", "consul-client"]
}

# ---------------------------------------------------------------------------
# Firewall — IAP SSH for operator access to Consul VMs
# Cloud IAP proxies SSH through Google's infrastructure; no public IP needed.
# The IAP source range 35.235.240.0/20 is Google-owned and used exclusively
# by the IAP TCP forwarding service.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "iap_ssh" {
  project     = var.project_id
  name        = "${var.name_prefix}-iap-ssh"
  network     = google_compute_network.main.id
  description = "Allow SSH and Consul HTTPS API from Cloud IAP to Consul server VMs (operator access + IAP tunnel for terraform apply)"
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22", "8501"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["consul-server"]
}

# ---------------------------------------------------------------------------
# Firewall — allow GKE control plane to reach nodes
# Required for GKE master-to-node communication (webhooks, metrics, etc.)
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "gke_master_to_nodes" {
  project     = var.project_id
  name        = "${var.name_prefix}-gke-master"
  network     = google_compute_network.main.id
  description = "Allow GKE master nodes to reach worker nodes on required ports"
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "10250"]
  }

  source_ranges = [var.gke_master_cidr]
  target_tags   = ["gke-node"]
}
