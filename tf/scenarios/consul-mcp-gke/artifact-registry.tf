# =============================================================================
# Scenario: consul-mcp-gke — artifact-registry.tf
# Layer 0: Artifact Registry repository for MCP agent Docker images
# No dependencies — created in Phase 1 alongside VPC and GKE.
# =============================================================================

resource "google_artifact_registry_repository" "mcp" {
  repository_id = var.artifact_registry_repo
  location      = var.gcp_region
  format        = "DOCKER"
  description   = "Docker images for vault-mcp-agents"

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}
