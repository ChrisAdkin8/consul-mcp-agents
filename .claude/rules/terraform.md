---
paths:
  - "tf/**/*.tf"
  - "tf/**/*.tf.tpl"
---

# Terraform Development Rules

## Variables and outputs
- Always include `description` on variables and outputs
- Add `type` constraints — prefer specific types (`string`, `number`, `list(string)`) over `any`
- Add `validation {}` blocks for variables with format requirements (CIDRs, SA emails, zones)
- Mark outputs containing secrets with `sensitive = true`

## Resource patterns
- Prefer `for_each` over `count` for named resources — enables targeted operations and readable state addresses
- Use `depends_on` only for implicit dependencies that Terraform cannot infer from references
- Use `locals {}` to define maps that drive `for_each` — keep resource definitions DRY

## Naming
- Resources: `{component}_{purpose}` (e.g. `kubernetes_deployment.mcp_server`)
- Variables: snake_case, descriptive (e.g. `vault_k8s_agent_role`, not `role`)
- Outputs: match the resource attribute they expose (e.g. `server_deployment_names`)

## Module conventions
- Standard inputs: `project_id`, `region`, `environment` where applicable
- Resource naming pattern: `{environment}-{component}-{resource}`
- Outputs should expose stable identifiers that downstream modules can reference
- Use `templatefile()` for multi-line configs — keep templates in `templates/` subdirectory

## Safety
- Never hardcode GCP project IDs — use `var.project_id`
- Never set defaults for credential variables (`sensitive = true` vars should have no default)
- Validate CIDR inputs — reject `0.0.0.0/0` for ingress rules
- Use `lifecycle { prevent_destroy = true }` on stateful resources (databases, buckets with data)

## Style
- Run `terraform fmt -recursive` before committing (automated by PostToolUse hook)
- Group related resources in the same file by function (e.g. `rbac.tf`, `service.tf`)
- Keep `locals {}` at the top of the file that uses them
- Use comments to explain "why", not "what" — the HCL is the "what"
