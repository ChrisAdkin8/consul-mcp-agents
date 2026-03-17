# =============================================================================
# TFLint Configuration
#
# Provider-aware linting for the consul-mcp-agents Terraform codebase.
# Used by both the GitHub Actions pipeline and local development.
#
# Run locally:
#   tflint --init --config .tflint.hcl
#   tflint --config .tflint.hcl --chdir tf/scenarios/consul-mcp-gke
# =============================================================================

plugin "google" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}

# Terraform-native rules
rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}
