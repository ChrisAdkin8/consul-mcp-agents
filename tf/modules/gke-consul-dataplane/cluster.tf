# =============================================================================
# GKE Consul Dataplane Module — cluster.tf
#
# Provisions a private GKE cluster configured for Consul dataplane mode:
#   • No Consul servers inside GKE (server.enabled = false in Helm)
#   • Consul dataplane sidecar proxies injected by the connect-inject webhook
#   • Workload Identity enabled (pods assume GCP SAs without SA key files)
#   • Private cluster: nodes have no public IPs
#
# TLS is ENABLED here (differs from the base terraform-gcp-nomad scenario).
# The CA cert from HCP Vault PKI is supplied to the Helm chart.
# =============================================================================

# ---------------------------------------------------------------------------
# GKE Cluster
# ---------------------------------------------------------------------------
resource "google_container_cluster" "main" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.region

  # Remove the default node pool and manage it separately for lifecycle control
  remove_default_node_pool = true
  initial_node_count       = 1

  # Version managed by release channel (STABLE); do not set min_master_version
  # as it can conflict with channel-available versions.

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  # VPC-native mode (alias IPs) — required for Pod-level firewall rules and
  # for Consul service mesh to function correctly with pod IPs
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Private cluster: nodes get internal IPs only, master is private
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # False allows kubectl from operator workstations
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.subnet_cidr
      display_name = "Internal subnet"
    }
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.name
      }
    }
  }

  # Workload Identity: pods authenticate to GCP as their own SA, not the node SA
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Enable Network Policy (Calico) — required for Consul service mesh intentions
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Auto-upgrade control plane and nodes via release channel
  release_channel {
    channel = var.release_channel
  }

  # Logging and monitoring (block form supersedes deprecated string args)
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Application-layer Secrets Encryption (CIS 8.5.5).
  # Enabled when var.database_encryption_key is set; otherwise default Google encryption applies.
  dynamic "database_encryption" {
    for_each = var.database_encryption_key != "" ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = var.database_encryption_key
    }
  }

  deletion_protection = var.deletion_protection

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  lifecycle {
    ignore_changes = [
      # Ignore node_version changes to prevent re-creation on minor upgrades
      node_version,
      # Ignore initial_node_count (managed by node pool)
      initial_node_count,
      # Version managed by release channel
      min_master_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# Node pool — general workloads
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "main" {
  project    = var.project_id
  name       = "${var.cluster_name}-nodes"
  cluster    = google_container_cluster.main.name
  location   = var.region
  node_count = var.node_count

  # Limit pod IPs per node to /26 (64 IPs) rather than the default /24 (256),
  # allowing 6+ nodes to fit in the /22 pods secondary range (1022 IPs).
  max_pods_per_node = 32

  node_config {
    machine_type = var.machine_type
    image_type   = "UBUNTU_CONTAINERD"
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    # Node SA — minimal permissions; workload identity handles pod-level auth
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Workload Identity on nodes
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded nodes
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      "node-pool" = "main"
      "cluster"   = var.cluster_name
    }

    tags = ["gke-node", "${var.cluster_name}-node"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

# ---------------------------------------------------------------------------
# GKE node pool service account — minimal permissions
# Pods use Workload Identity, not this SA. The SA only needs:
#   • GCR access (pull images from Artifact Registry)
#   • Logging/monitoring (write metrics and logs)
# ---------------------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE Node Pool SA"
  description  = "Service account for GKE node VMs — minimal permissions (Workload Identity for pods)"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Allow Workload Identity: GKE SA in mcp-agents namespace can impersonate data-agent GCP SA
# depends_on ensures the GKE cluster (and its Workload Identity Pool) exists first
resource "google_service_account_iam_member" "workload_identity_data" {
  service_account_id = var.data_agent_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.mcp_namespace}/mcp-data-server]"
  depends_on         = [google_container_cluster.main]
}

resource "google_service_account_iam_member" "workload_identity_compute" {
  service_account_id = var.compute_agent_sa_name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.mcp_namespace}/mcp-compute-server]"
  depends_on         = [google_container_cluster.main]
}
