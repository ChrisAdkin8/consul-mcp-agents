# Terraform Code Analysis Report

**Date:** 2026-03-16
**Scope:** `tf/` (full repository)
**Files scanned:** 45 `.tf` files + 1 `.tfvars` across 7 modules + 1 scenario
**Focus:** All areas (Security, DRY, Style, Robustness, Simplicity, Ops, CI/CD, Cross-Module, Stack-Specific, CLAUDE.md Compliance)
**Mode:** Static
**Health Grade:** F (22/100)

---

## Executive Summary

The codebase demonstrates strong foundational security practices: comprehensive input validation, least-privilege IAM, Vault-mediated credential injection, Consul mTLS, and hardened K8s security contexts on all containers. However, the expanded analysis reveals **three critical findings** that collectively warrant an F grade: real credentials in `terraform.tfvars`, a known-buggy vault-agent version default, and **state files containing decrypted secrets sitting on disk** (up to 358KB with full Vault tokens, SA keys, and API keys). Beyond security, the complete absence of CI/CD pipelines, pre-commit hooks, TFLint, policy-as-code, and Terraform tests means there are zero automated guardrails around infrastructure changes. Provider version constraints are all major-version-wide (`~> X.0`), which permits breaking changes on `terraform init`. The `.terraform.lock.hcl` is gitignored, eliminating provider version reproducibility across machines.

**Finding counts by urgency:**

| Urgency | Count |
|---------|-------|
| CRITICAL | 3 |
| HIGH | 8 |
| MEDIUM | 19 |
| LOW | 6 |
| INFO | 12 |

### Delta (vs previous report 2026-03-16 run 1)

- **Resolved:** 0 findings
- **New:** 21 findings (S-010, S-011, S-012, S-013, R-008, R-009, R-010, R-011, O-001, O-002, C-001, C-002, C-003, C-004, C-005, K-001, K-002, K-003, K-004, K-005, V-001)
- **Unchanged:** 27 findings (all findings from run 1 carried forward)

---

## 1. Security Posture

### CRITICAL

- **[S-001] Real credentials in terraform.tfvars** — `tf/scenarios/consul-mcp-gke/terraform.tfvars` | Blast: infrastructure-wide | CIS: n/a

  The local `terraform.tfvars` file contains values matching real credential patterns: an Anthropic API key (`sk-ant-api03-...`), an HCP client secret (40+ char hex), a Kubernetes JWT (`eyJhbG...`), and a Consul bootstrap token (UUID). The file is gitignored but exists in plaintext on disk. If force-added, backed up, or synced, all credentials leak.

  **Recommendation:** Rotate all credentials. Move secrets to a secrets manager and source via env vars. Install `detect-secrets` or `gitleaks` as a pre-commit hook.

---

- **[S-002] vault_agent_version default `1.19.0` has known pkiCert renewal bug** — `tf/modules/mcp-agents-k8s/variables.tf:84` | Blast: module | CIS: n/a

  Default `vault_agent_version` is `"1.19.0"`. vault-agent v1.19.x never re-renders certificates after initial boot (documented in CLAUDE.md). Fixed version is `1.21.3`. Any new environment or contributor omitting this variable deploys the broken version.

  **Recommendation:**
  ```diff
  - default = "1.19.0"
  + default = "1.21.3"
  ```

---

- **[S-010] Terraform state files with decrypted secrets on local disk** — project root and `tf/scenarios/consul-mcp-gke/` | Blast: infrastructure-wide | CIS: n/a

  Four state files found on disk:
  - `terraform.tfstate` (181 bytes, root)
  - `tf/scenarios/consul-mcp-gke/terraform.tfstate` (910 bytes)
  - `tf/scenarios/consul-mcp-gke/terraform.tfstate.backup` (341 KB)
  - `tf/scenarios/consul-mcp-gke/errored.tfstate` (358 KB)

  The backup and errored state files contain the full decrypted state including GCP SA private keys, Vault admin tokens, Consul bootstrap tokens, API keys, and every secret managed by Terraform. These files persist indefinitely on disk and are not encrypted at rest.

  **Recommendation:**
  1. Delete all local state files immediately: `rm -f terraform.tfstate tf/scenarios/consul-mcp-gke/*.tfstate*`
  2. Verify remote GCS backend is the sole source of truth (`task tf:backend:init`)
  3. Add `*.tfstate` and `*.tfstate.backup` to `.gitignore` if not already present
  4. Ensure the GCS state bucket has object versioning, access logging, and CMEK encryption enabled

---

### HIGH

- **[S-003] GKE API server exposed to 0.0.0.0/0** — `tf/scenarios/consul-mcp-gke/terraform.tfvars:27` | Blast: environment | CIS: n/a

  `gke_authorized_cidrs` includes `0.0.0.0/0`. No validation guard exists on this variable (unlike `allowed_ingress_cidrs`).

  **Recommendation:** Remove `0.0.0.0/0` from tfvars. Add validation:
  ```hcl
  validation {
    condition     = !contains([for b in var.gke_authorized_cidrs : b.cidr], "0.0.0.0/0")
    error_message = "gke_authorized_cidrs must not contain 0.0.0.0/0."
  }
  ```

---

- **[S-004] vault_impersonator granted serviceAccountKeyAdmin at project level** — `tf/modules/vault-config/gcp-engine.tf:54-60` | Blast: environment | CIS: 1.4

  `roles/iam.serviceAccountKeyAdmin` at project level allows the SA to manage keys for **every** SA in the project. Only `serviceAccountTokenCreator` is needed for impersonation.

  **Recommendation:** Remove `serviceAccountKeyAdmin` from `local.vault_sa_roles`.

---

- **[S-005] GCP SA private key stored in Terraform state** — `tf/modules/vault-config/gcp-engine.tf:38-42` | Blast: infrastructure-wide | CIS: 1.4

  `google_service_account_key.vault_impersonator` stores a long-lived SA private key in state. No rotation schedule. If state is compromised, full impersonation chain is exposed.

  **Recommendation:** Use Workload Identity where possible. If SA key is unavoidable with HCP Vault, add `time_rotating` for forced rotation. Ensure GCS state bucket has CMEK + access logging.

---

- **[S-006] Consul Ingress Gateway LB has no source range restrictions** — `tf/modules/gke-consul-dataplane/consul-helm.tf:241-260` | Blast: environment | CIS: n/a

  Ingress gateway LB (ports 80, 443) is open to `0.0.0.0/0`. Unlike the MCP agent LB which restricts via `load_balancer_source_ranges`.

  **Recommendation:** Add `loadBalancerSourceRanges` Helm set, or disable ingress gateway if unused.

---

- **[S-007] TTYD credential as plaintext env var in pod spec** — `tf/modules/mcp-agents-k8s/deployment.tf:173-176` | Blast: module | CIS: n/a

  `TTYD_CREDENTIAL` set directly as `value = var.ttyd_credential`. Visible in `kubectl describe pod`.

  **Recommendation:** Store in K8s Secret, reference via `secretKeyRef`.

---

- **[S-011] .terraform.lock.hcl is gitignored** — `.gitignore` | Blast: infrastructure-wide | CIS: n/a

  The lock file ensures provider version reproducibility. Gitignoring it means each `terraform init` on a different machine may pull different provider builds, risking non-deterministic plans.

  **Recommendation:** Remove `.terraform.lock.hcl` from `.gitignore` and commit the lock file. This is HashiCorp's official recommendation.

---

- **[C-001] No CI/CD pipeline detected** — project root | Blast: infrastructure-wide | CIS: n/a

  **RESOLVED:** GitHub Actions pipeline added at `.github/workflows/terraform.yml` with fmt, validate, tfsec, and tflint jobs. No cloud credentials required. Applies remain manual via Taskfile.

---

### MEDIUM

- **[S-008] Long-lived non-expiring K8s SA token** — `tf/scenarios/consul-mcp-gke/vault-config.tf:53-70` | Blast: environment | CIS: n/a

  `kubernetes.io/service-account-token` has no expiry. No rotation mechanism defined.

  **Recommendation:** Document rotation procedure. Consider `time_rotating` to force periodic regeneration.

---

- **[S-009] insecure_https = true when consul_address_override is set** — `tf/scenarios/consul-mcp-gke/versions.tf:129` | Blast: single-resource | CIS: n/a

  TLS verification disabled when any override address is set. Documented as intentional in CLAUDE.md (IAP tunnel workaround).

  **Recommendation:** Restrict to localhost only:
  ```hcl
  insecure_https = var.consul_address_override != "" && can(regex("^(localhost|127\\.0\\.0\\.1)", var.consul_address_override))
  ```

  *Documented as intentional in CLAUDE.md — verify still applicable.*

---

- **[S-012] GKE cluster missing Application-layer Secrets Encryption** — `tf/modules/gke-consul-dataplane/cluster.tf:17` | Blast: environment | CIS: n/a

  No `database_encryption` block on the GKE cluster. K8s Secrets (including `consul-bootstrap-acl-token`, `consul-ca-cert`, `vault-reviewer-token`) are encrypted at rest only by GKE's default Google-managed encryption. Application-layer encryption adds an extra KMS layer.

  **Recommendation:** Add Cloud KMS key and `database_encryption` block:
  ```hcl
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke_secrets.id
  }
  ```

---

- **[S-013] No vault_audit resource — Vault auditing not configured via Terraform** — `tf/modules/vault-config/` | Blast: infrastructure-wide | CIS: n/a

  No `vault_audit` resource in the codebase. Without audit logging, Vault access (token creation, secret reads, policy changes) is untracked. HCP Vault may have audit logs enabled at the platform level, but this is not enforced or verified by Terraform.

  **Recommendation:** Add a `vault_audit` resource targeting the HCP Vault audit log sink, or document that HCP Vault provides audit logging natively and add a comment explaining the omission.

---

- **[S-014] Cloud NAT logging set to ERRORS_ONLY** — `tf/modules/network/main.tf:87` | Blast: environment | CIS: n/a

  Cloud NAT `log_config.filter = "ERRORS_ONLY"`. For production environments, `ALL` logging provides visibility into egress traffic patterns that can detect data exfiltration or unauthorized outbound connections.

  **Recommendation:** Change to `filter = "ALL"` for production, keep `ERRORS_ONLY` for dev/staging via a conditional:
  ```hcl
  filter = var.environment == "prod" ? "ALL" : "ERRORS_ONLY"
  ```

---

- **[R-003] No prevent_destroy on critical Vault infrastructure** — `tf/modules/vault-config/kv.tf:21`, `tf/modules/vault-pki-consul/pki.tf:27`, `tf/modules/vault-config/gcp-engine.tf:65` | Blast: infrastructure-wide

  The Vault KV mount, Root CA PKI mount, and GCP secrets engine lack `lifecycle { prevent_destroy = true }`. Accidental `terraform destroy` would wipe the PKI trust chain and credential engine.

  **Recommendation:** Add `lifecycle { prevent_destroy = true }` to `vault_mount.secret`, `vault_mount.connect_root`, `vault_mount.connect_intermediate`, and `vault_gcp_secret_backend.main`.

---

- **[R-004] No timeouts block on GKE cluster or node pool** — `tf/modules/gke-consul-dataplane/cluster.tf:17,110` | Blast: module

  GKE creation can take 10-20 minutes. Without explicit `timeouts`, provider defaults apply.

  **Recommendation:** Add `timeouts { create = "30m"; update = "40m"; delete = "30m" }`.

---

- **[R-005] cas = 0 allows unchecked KV overwrites** — `tf/modules/vault-config/kv.tf:38` | Blast: single-resource

  `cas = 0` means create-or-update without version checking. Concurrent runs could partially overwrite secrets.

---

- **[R-006] token_max_ttl = 86400 interaction with sidecar re-auth undocumented** — `tf/modules/vault-config/auth-k8s.tf:70-71,89-90` | Blast: module

  24-hour max TTL on K8s auth roles. Interaction with vault-agent sidecar's re-authentication behavior should be tested and documented.

---

- **[R-009] force_destroy = true on consul_config GCS bucket** — `tf/scenarios/consul-mcp-gke/consul.tf:19` | Blast: single-resource

  The `google_storage_bucket.consul_config` has `force_destroy = true`, meaning `terraform destroy` will delete the bucket and all objects without confirmation, even if the bucket contains configuration data.

  **Recommendation:** Set `force_destroy = false` for production. Add `lifecycle { prevent_destroy = true }` if the bucket holds critical config.

---

- **[R-010] Provider version constraints too wide (major-version pinning)** — `tf/scenarios/consul-mcp-gke/versions.tf:20-53` | Blast: infrastructure-wide

  All providers use `~> X.0` constraints:
  - `google ~> 5.0` — allows 5.0 through 5.999 (currently 5.80+; 5.0 to 5.80 span includes breaking behavioral changes)
  - `kubernetes ~> 2.0` — rapidly evolving provider, minor versions frequently break
  - `helm ~> 2.0` — same concern
  - `vault ~> 4.0`, `consul ~> 2.0`, `random ~> 3.0`, `local ~> 2.0`

  Only `hcp ~> 0.94` is appropriately minor-pinned.

  **Recommendation:** Tighten to minor version for production:
  ```hcl
  google     = "~> 5.80"
  kubernetes = "~> 2.36"
  helm       = "~> 2.17"
  vault      = "~> 4.6"
  consul     = "~> 2.21"
  ```

---

- **[R-011] 30+ Helm set blocks in Consul release** — `tf/modules/gke-consul-dataplane/consul-helm.tf:83-266` | Blast: module

  The Consul Helm release uses 30+ individual `set` blocks. This is hard to read, review, and diff. A `values` block with a YAML file would be more maintainable.

  **Recommendation:** Extract values to a `consul-values.yaml` template and use:
  ```hcl
  values = [templatefile("${path.module}/templates/consul-values.yaml.tpl", { ... })]
  ```

---

- **[O-001] No monitoring or alerting resources** — project-wide | Blast: environment

  No `google_monitoring_alert_policy`, `google_monitoring_uptime_check`, or `google_logging_metric` resources. No visibility into infrastructure health beyond GKE's built-in monitoring.

  **Recommendation:** Add at minimum: GKE node pool health alert, Consul server VM uptime check, and a log-based metric for Vault auth failures.

---

- **[C-002] No pre-commit hooks** — project root | Blast: infrastructure-wide

  No `.pre-commit-config.yaml`. No automated formatting, linting, or secret detection before commits.

  **Recommendation:** Add pre-commit framework with hooks for `terraform fmt`, `tflint`, `detect-secrets`.

---

- **[C-003] No TFLint configuration** — project root | Blast: infrastructure-wide

  **RESOLVED:** `.tflint.hcl` added at repo root with Google provider plugin, naming conventions, unused declaration checks, and module structure rules. Integrated into the GitHub Actions pipeline.

---

- **[C-004] No policy-as-code enforcement** — project root | Blast: infrastructure-wide

  No Sentinel policies, OPA/Conftest rules, or policy directories. No automated enforcement of organizational rules (mandatory labels, encryption requirements, no public LBs).

  **Recommendation:** Add OPA/Conftest policies for: mandatory labels, no `0.0.0.0/0` in firewall rules, encryption enabled on storage, `deletion_protection = true` on GKE.

---

- **[C-005] No Terraform tests** — project root | Blast: infrastructure-wide

  No `*.tftest.hcl`, `*_test.go`, or `tests/` directories. No contract testing for module interfaces.

  **Recommendation:** Add `terraform test` (native, 1.6+) for module contract validation: verify outputs exist, variable validation blocks reject bad input, conditional resources gate correctly.

---

- **[K-001] GKE release channel not explicitly set** — `tf/modules/gke-consul-dataplane/cluster.tf:17` | Blast: environment | CIS: n/a

  No `release_channel` block on the GKE cluster. The comment says "Version managed by release channel (STABLE)" but no `release_channel { channel = "STABLE" }` block exists. Without it, GKE uses the default channel which may not be STABLE.

  **Recommendation:**
  ```hcl
  release_channel {
    channel = "STABLE"
  }
  ```

---

- **[K-002] GCP SA keys have no lifecycle rotation** — `tf/modules/vault-config/gcp-engine.tf:38`, `tf/scenarios/consul-mcp-gke/vault-pki.tf:36` | Blast: infrastructure-wide | CIS: 1.4

  Two `google_service_account_key` resources (`vault_impersonator`, `vault_gcp_verifier`) create keys with no rotation mechanism. CIS GCP Foundation Benchmark 1.4 requires SA key rotation within 90 days.

  **Recommendation:** Add a `time_rotating` resource:
  ```hcl
  resource "time_rotating" "sa_key_rotation" {
    rotation_days = 90
  }
  resource "google_service_account_key" "vault_impersonator" {
    service_account_id = google_service_account.vault_impersonator.name
    keepers = { rotation = time_rotating.sa_key_rotation.id }
  }
  ```

---

### LOW

- **[D-002] mcp_namespace hardcoded in 2 scenario call sites** — `tf/scenarios/consul-mcp-gke/gke.tf:28`, `vault-config.tf:88` | Blast: single-resource

  `"mcp-agents"` is a literal string in two module calls instead of using a variable.

---

- **[D-003] gcp_project_id validation regex duplicated across 5 files** | Blast: module

  HCL limitation — no shared validation functions. Add cross-reference comments for maintenance.

---

- **[D-004] helm_chart_version and gke_cluster_name defaults duplicated** — module and scenario variables.tf | Blast: module

  Remove defaults from module variables to eliminate dual-maintenance.

---

- **[D-005] consul_bootstrap_token defined identically in two modules** | Blast: module

  Duplicated sensitive variable with identical validation in `gke-consul-dataplane` and `vault-config` modules.

---

- **[Y-004] gcp_zone/zone naming inconsistency** — scenario vs consul module | Blast: single-resource

---

- **[O-002] PDB min_available=1 with replicas=1 on MCP servers** — `tf/modules/mcp-agents-k8s/service.tf:90-107` | Blast: module

  MCP server deployments have `replicas = 1` but PDBs require `min_available = 1`. This blocks voluntary disruptions (node drains) entirely since the PDB won't allow the single replica to be evicted.

  **Recommendation:** Either increase MCP server replicas to 2, or set PDB to `maxUnavailable = 1` instead.

---

## 2. DRY and Code Reuse

### MEDIUM

- **[D-001] vault_agent_version default out of sync with Dockerfile** — `tf/modules/mcp-agents-k8s/variables.tf:84` | Blast: module

  Terraform default `1.19.0` vs Dockerfile `1.21.3`. Already causes S-002.

---

## 3. Style and Conventions

### MEDIUM

- **[Y-001] terraform fmt failure on terraform.tfvars** — `tf/scenarios/consul-mcp-gke/terraform.tfvars` | Blast: single-resource

  Run `terraform fmt tf/scenarios/consul-mcp-gke/terraform.tfvars`.

---

- **[Y-002] mcp_servers local defined in deployment.tf, consumed by 4 files** — `tf/modules/mcp-agents-k8s/deployment.tf:15-28` | Blast: module

  Shared locals should live in a dedicated `locals.tf`.

---

- **[Y-003] Stale hvac comment in gcp-engine.tf** — `tf/modules/vault-config/gcp-engine.tf:11-14` | Blast: single-resource

  Credential flow diagram references hvac Python client path only; GKE mode uses vault-agent sidecar.

---

## 4. Robustness

### HIGH

- **[R-001] deletion_protection = false on GKE cluster** — `tf/modules/gke-consul-dataplane/cluster.tf:93` | Blast: environment

  `terraform destroy` silently deletes the cluster, all node pools, and workloads.

  **Recommendation:** Set `deletion_protection = true`.

---

- **[R-002] gke_authorized_cidrs accepts 0.0.0.0/0 without validation** — `tf/scenarios/consul-mcp-gke/variables.tf:260-267` | Blast: environment

  No validation guard. Related to S-003.

---

### MEDIUM

- **[R-008] ignore_changes audit — all three instances are justified** | Blast: n/a

  | Location | Fields | Justification |
  |----------|--------|---------------|
  | `consul-helm.tf:60` | `[data]` on consul-ca-cert Secret | Documented in CLAUDE.md: Terraform seeds, Taskfile manages live CA chain |
  | `cluster.tf:96` | `[node_version, initial_node_count, min_master_version]` | Release channel manages versions; initial_node_count is for default pool removal |
  | `consul/main.tf:93` | `[boot_disk[0].initialize_params[0].image]` | Prevents VM recreation on Packer image rebuild |

  All three are legitimate dual-management patterns. No `ignore_changes = all` found.

---

- **[R-007] No module README.md files** — all 7 modules | Blast: module

  None of the modules have README.md with inputs/outputs tables.

---

## 5. Simplicity

### MEDIUM

- **[X-001] agent_approle_mount is dead configuration** — `tf/modules/vault-config/kv.tf:51` | Blast: single-resource

  `agent_approle_mount = "approle"` in settings_yaml but no AppRole auth backend exists.

---

- **[X-002] HCP credentials via both env vars and Terraform variables** — `tf/scenarios/consul-mcp-gke/versions.tf:74-81` | Blast: single-resource

  Dual path increases `terraform.tfvars` secret burden. Prefer env vars for provider auth.

---

## 6. Operational Readiness

*(Findings O-001 and O-002 listed in Section 1 above)*

### INFO

- **[O-003]** `common_labels` local defined in `locals.tf` and applied consistently to GCP resources. K8s resources use `app.kubernetes.io/*` labels consistently. Good practice.

- **[O-004]** GKE `monitoring_service = "monitoring.googleapis.com/kubernetes"` and `logging_service = "logging.googleapis.com/kubernetes"` are correctly enabled (CIS GKE 6.7.1 compliant).

- **[O-005]** VPC Flow Logs enabled with good configuration: `flow_sampling = 0.5`, `metadata = "INCLUDE_ALL_METADATA"`, `aggregation_interval = "INTERVAL_10_MIN"` (CIS GCP 3.8 compliant).

---

## 7. CI/CD and Testing Maturity

*(Findings C-001 through C-005 listed in Section 1 above)*

**Summary:** Zero automated guardrails exist. No CI/CD pipeline, no pre-commit framework, no linter, no policy-as-code, no tests. All infrastructure changes rely entirely on operator discipline and `task tf:plan` manual review.

---

## 8. Cross-Module Contracts

### INFO

- **[M-001]** All 7 modules are referenced by the scenario — no orphaned modules.

- **[M-002]** Output-to-input type matching verified. All module outputs consumed by callers exist in the respective `outputs.tf` files. Types are compatible.

- **[M-003]** Variable pass-through depth is 2 layers maximum (scenario → module). No excessive indirection detected.

---

## 9. Stack-Specific Findings

### Vault

- **[K-003] Vault policy paths are explicit (no wildcards)** — `tf/modules/vault-config/auth-k8s.tf:103-141`, `auth-userpass.tf:34-106` | INFO

  All Vault policies use specific paths (`secret/data/mcp-agents/config`, etc.). No wildcard `*` paths. Good practice.

- **[K-004] Vault lease/token TTL chain is coherent** | INFO

  GCP secrets engine: `default_lease_ttl = 300s`, `max_lease_ttl = 300s`. Impersonated accounts: `ttl = 300`. K8s auth roles: `token_ttl = 3600`, `token_max_ttl = 86400`. capabilities.yaml: `max_gcp_token_ttl = 5m`. Chain is consistent.

### Consul

- **[K-005] Consul TLS httpsOnly = true and ACL manageSystemACLs = true** | INFO

  Consul Helm values enforce TLS-only communication and ACL management. Correct for production.

### GKE

- **[K-001]** GKE release channel not explicitly set (covered above, MEDIUM).

- **[K-006] GKE enable_legacy_abac = false** | INFO | CIS: GKE 7.3

  Legacy ABAC correctly disabled. Compliant.

- **[K-007] GKE Shielded Nodes enabled** | INFO

  `enable_secure_boot = true` and `enable_integrity_monitoring = true` on both cluster and node pool. Compliant.

- **[K-008] GKE Network Policy enabled with Calico** | INFO | CIS: GKE 7.11

  `network_policy.enabled = true` with `provider = "CALICO"`. Required for Consul service mesh intentions. Compliant.

### Helm

- **[R-011]** 30+ set blocks (covered above, MEDIUM).
- `wait = true`, `wait_for_jobs = true`, `timeout = 900` — all correctly set.
- `create_namespace = false` — namespace managed by Terraform separately. Correct.
- Chart version pinned via variable with semver validation. Good.

---

## 10. CLAUDE.md Compliance

- **[V-001] vault_agent_version default contradicts CLAUDE.md** — `tf/modules/mcp-agents-k8s/variables.tf:84` | Blast: module | HIGH

  CLAUDE.md documents the fix version as `1.21.3` and warns about the v1.19.x pkiCert renewal bug. The default is still `1.19.0`. Documentation-code divergence. (Same as S-002.)

---

- **PKI TTLs: MATCH**
  - Root CA `max_lease_ttl_seconds = 315360000` (10 years) — matches "root 10yr"
  - Intermediate CA signed with `ttl = 157680000` (5 years) — matches "intermediate 5yr"
  - Leaf `max_ttl = 259200` (72 hours) — matches "leaf 72h"

- **No default credentials: MATCH**
  - `vault_users` — no default, `validation { length > 0 }`
  - `mcp_ttyd_credential` — no default, `validation { regex user:password }`
  - `allowed_ingress_cidrs` — no default, `validation { !contains 0.0.0.0/0 }`

- **IAM least-privilege: MATCH**
  - `storage.objectAdmin` (not `storage.admin`)
  - `bigquery.dataEditor` + `bigquery.jobUser` (not `bigquery.admin`)
  - `compute.instanceAdmin.v1` (not `compute.admin`)
  - Exception: `serviceAccountKeyAdmin` at project level (S-004) contradicts "least-privilege" principle

- **Naming convention `{environment}-{component}-{resource}`: PARTIAL MATCH**
  - Uses `{random_pet}-{datacenter}` prefix. Consistent but does not include `environment` in resource names (only in labels).

---

## 11. Suppressed Findings

No `.tf-analyze-ignore.yaml` found. No inline `# tf-analyze:ignore` comments detected. No findings are suppressed.

---

## 12. Positive Findings

1. **Comprehensive input validation** — Nearly every variable has a `validation` block with meaningful error messages. GCP project ID regex, CIDR validation, semver checks, and enum constraints are best-in-class for a Terraform codebase.

2. **No hardcoded values in .tf files** — `var.project_id`, `var.region`, `var.environment` used consistently. Zero string literal GCP project IDs.

3. **for_each over mcp_servers** — Clean, DRY, extensible pattern. Adding a new MCP server requires one map entry; deployment, service, SA, PDB, ConfigMap, and intention are created automatically.

4. **Pre-rendered YAML via yamlencode()** — Sidesteps the vault-agent heredoc indentation bug. Non-obvious but architecturally correct decision.

5. **Phase-gated apply with auto-detection** — `count = condition ? 1 : 0` gates prevent plan-time failures when GKE doesn't exist yet.

6. **Least-privilege IAM throughout** — Well-scoped roles with one exception (S-004).

7. **Hardened K8s security contexts on all containers** — `run_as_non_root`, `allow_privilege_escalation = false`, `capabilities.drop = ["ALL"]`. Vault-agent containers add `read_only_root_filesystem = true`.

8. **PDBs on all deployments** — Both agent and server deployments have PodDisruptionBudgets.

9. **Topology spread constraints** — Agent deployment uses `topology_spread_constraint` with `DoNotSchedule`.

10. **VPC Flow Logs enabled** — 50% sampling, all metadata, CIS GCP 3.8 compliant.

11. **Private cluster with Cloud NAT** — No public IPs on nodes or VMs. IAP SSH for operator access.

12. **Shielded nodes and legacy ABAC disabled** — CIS GKE 7.3 and shielded instance compliance.

---

## 13. Recommended Action Plan

| Priority | Finding | Section | Effort | Blast Radius | Description |
|----------|---------|---------|--------|--------------|-------------|
| 1 | S-010 | Security | Small | infrastructure-wide | Delete all local state files; verify GCS backend is sole source of truth |
| 2 | S-001 | Security | Small | infrastructure-wide | Rotate Anthropic API key, HCP secret, Consul token; install detect-secrets pre-commit |
| 3 | S-002 | Security | Trivial | module | Change vault_agent_version default from 1.19.0 to 1.21.3 |
| 4 | S-011 | Security | Small | infrastructure-wide | Un-gitignore and commit .terraform.lock.hcl |
| 5 | S-003 + R-002 | Security | Small | environment | Remove 0.0.0.0/0 from gke_authorized_cidrs; add validation block |
| 6 | R-001 | Robustness | Trivial | environment | Set deletion_protection = true on GKE cluster |
| 7 | C-001 | CI/CD | Medium | infrastructure-wide | Create CI pipeline with fmt/validate/plan/scan gates |
| 8 | S-004 | Security | Trivial | environment | Remove serviceAccountKeyAdmin from vault_sa_roles |
| 9 | S-006 | Security | Small | environment | Add loadBalancerSourceRanges to ingress gateway or disable it |
| 10 | R-003 | Robustness | Small | infrastructure-wide | Add prevent_destroy to Vault KV mount, Root CA, GCP secrets engine |
| 11 | S-007 | Security | Medium | module | Migrate TTYD_CREDENTIAL to K8s Secret reference |
| 12 | R-010 | Robustness | Small | infrastructure-wide | Tighten provider version constraints to minor version (~> X.Y) |
| 13 | K-001 | Stack | Trivial | environment | Add explicit release_channel { channel = "STABLE" } to GKE cluster |
| 14 | C-002 | CI/CD | Small | infrastructure-wide | Add pre-commit framework with terraform fmt, tflint, detect-secrets |
| 15 | K-002 | Security | Medium | infrastructure-wide | Add time_rotating for SA key rotation (CIS 1.4 compliance) |

### Related Findings

- **S-001 + S-010**: Credentials on disk in both tfvars AND state files — address both simultaneously by cleaning up local files and hardening the secrets workflow
- **S-002 + D-001 + V-001**: vault_agent_version 1.19.0 is a security, DRY, and CLAUDE.md compliance issue — single fix resolves all three
- **S-003 + R-002**: GKE API server exposure lacks both tfvars cleanup AND variable validation
- **S-004 + S-005 + K-002**: IAM key management: overly broad role, keys in state, and no rotation are compounding risks
- **C-001 + C-002 + C-003 + C-004 + C-005**: Zero automated guardrails — address as a single CI/CD initiative
- **S-011 + R-010**: Provider reproducibility: gitignored lock file AND wide version constraints mean plans are non-deterministic
