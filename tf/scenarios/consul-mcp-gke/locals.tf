# =============================================================================
# Scenario: consul-mcp-gke — locals.tf
# =============================================================================

resource "random_pet" "prefix" {
  length    = 2
  separator = "-"
}

locals {
  # Consistent name prefix for all resources: "<random-pet>-<datacenter>"
  # e.g. "happy-panda-dc1"
  name_prefix = "${random_pet.prefix.id}-${var.datacenter}"

  # Short prefix for resources with stricter name length limits (e.g. GCS buckets)
  short_prefix = random_pet.prefix.id

  # Prefix for GCP service account IDs (max 30 chars including suffix).
  # Longest suffix is "-vault-verifier" (15 chars), so cap at 14 chars.
  # trimsuffix removes a trailing hyphen if substr cuts mid-word.
  sa_prefix = trimsuffix(substr(local.short_prefix, 0, min(length(local.short_prefix), 14)), "-")

  # Standard labels applied to all GCP resources
  common_labels = {
    project     = var.gcp_project_id
    environment = var.environment
    managed_by  = "terraform"
    scenario    = "consul-mcp-gke"
    datacenter  = var.datacenter
  }

  # Image repository base path in Artifact Registry
  image_repo_base = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_registry_repo}"

  # Kubernetes namespace for MCP agent workloads — referenced by gke and vault-config modules
  mcp_namespace = "mcp-agents"
}
