# Terraform Code Analysis Report

**Date:** 2026-05-01
**Scope:** tf/ (all modules and scenarios)
**Files scanned:** 44 .tf files across 7 modules and 1 scenario (~4,825 lines)
**Focus:** all
**Mode:** static
**Health Grade:** F (24/100)

---

## Executive Summary

The codebase demonstrates strong security-first engineering — comprehensive variable validation, least-privilege Vault policies, hardened K8s security contexts (non-root, capability drops, projected SA tokens), Consul mTLS mesh with deny-by-default intentions, and a 4-job CI pipeline. However, one critical network exposure (GKE API server open to `0.0.0.0/0`), three high-severity gaps (project-level IAM overbinding, ingress gateway without source ranges, SA keys in state), and accumulated medium-severity findings in lifecycle protection and CI maturity keep the score below passing.

**Strengths:** All local module sources (zero supply-chain risk); near-100% variable validation with meaningful error messages; K8s security contexts with `run_as_non_root`, `drop: ALL`, projected SA tokens (2h expiry); Consul TLS+ACL enforcement with explicit service intentions; VPC flow logs with metadata; GitHub Actions CI with fmt/validate/tfsec/tflint.

**Finding counts by urgency:**

| Urgency | Count |
|---------|-------|
| CRITICAL | 1 |
| HIGH | 3 |
| MEDIUM | 10 |
| LOW | 10 |
| INFO | 12 |

### Delta (vs previous report 2026-03-16)

- **Resolved:** 8 findings
  - ~~S-002~~ (CRITICAL): `vault_agent_version` updated from 1.19.0 to 1.21.3
  - ~~S-010~~ (CRITICAL): Local state files removed — GCS backend is sole source of truth
  - ~~S-001~~ (CRITICAL): Reclassified — `terraform.tfvars` was never committed (gitignored); previous report's claim was false
  - ~~S-011~~ (HIGH): `.terraform.lock.hcl` now committed to git
  - ~~C-001~~ (HIGH): GitHub Actions pipeline added (`.github/workflows/terraform.yml`)
  - ~~V-001~~ (HIGH): `vault_agent_version` CLAUDE.md mismatch resolved
  - ~~D-001~~ (MEDIUM): `vault_agent_version` sync issue resolved
  - ~~C-003~~ (MEDIUM): `.tflint.hcl` added with Google provider plugin

- **New:** 3 findings (SEC-K8S-001#1, OPS-LABELS-001#1, SEC-IMAGE-001#1)

- **Reclassified:** 5 findings changed urgency based on deeper analysis
  - S-003 → SEC-NET-002#1: HIGH → CRITICAL (0.0.0.0/0 with public endpoint = effectively no protection)
  - S-012 → SEC-GKE-002#1: MEDIUM → HIGH (CIS 8.5.5 gap)
  - S-013 → SEC-AUDIT-001#1: MEDIUM → HIGH (Vault audit is a compliance baseline)
  - Multiple MEDIUM → LOW (findings that were style/maintenance items, not robustness gaps)

- **Unchanged:** 21 findings carried forward

### Finding density by file

| File | Lines | CRIT | HIGH | MED | LOW | Total | Density |
|------|-------|------|------|-----|-----|-------|---------|
| `tf/modules/gke-consul-dataplane/cluster.tf` | 201 | 0 | 2 | 2 | 2 | 6 | 3.0 |
| `tf/modules/vault-config/gcp-engine.tf` | 146 | 0 | 1 | 1 | 0 | 2 | 1.4 |
| `tf/modules/gke-consul-dataplane/consul-helm.tf` | 266 | 0 | 1 | 0 | 0 | 1 | 0.4 |
| `tf/modules/mcp-agents-k8s/deployment.tf` | 566 | 0 | 0 | 2 | 0 | 2 | 0.4 |
| `tf/scenarios/consul-mcp-gke/versions.tf` | 133 | 0 | 0 | 1 | 0 | 1 | 0.8 |
| `tf/scenarios/consul-mcp-gke/terraform.tfvars` | — | 1 | 0 | 0 | 1 | 2 | — |

---

## 1. Security Posture

### CRITICAL

- **[SEC-NET-002#1] GKE API server authorized networks includes 0.0.0.0/0** — `terraform.tfvars` (local) | Blast: infrastructure-wide | CIS: 8.5.4 | Effort: Small | Status: NEEDS-REVIEW
  Description: `gke_authorized_cidrs` contains `{ cidr = "0.0.0.0/0", name = "hcp-vault-and-external" }`. Combined with `enable_private_endpoint = false` in `cluster.tf:42`, the GKE API server is reachable from the entire internet. This nullifies the private cluster protections.
  Recommendation: Replace with specific HCP Vault public IPs and operator workstation CIDRs. Add a `validation` block on `gke_authorized_cidrs` rejecting `0.0.0.0/0` (matching the pattern already used on `allowed_ingress_cidrs`).
  Verification: `gcloud container clusters describe <CLUSTER> --format='value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)' | grep -c '0.0.0.0/0'` returns 0.

### HIGH

- **[SEC-IAM-001#1] Project-level serviceAccountKeyAdmin + serviceAccountTokenCreator** — `tf/modules/vault-config/gcp-engine.tf:54` | Blast: infrastructure-wide | CIS: 1.5 | Effort: Medium | Status: VERIFIED
  Description: The Vault impersonator SA receives `roles/iam.serviceAccountKeyAdmin` and `roles/iam.serviceAccountTokenCreator` at the project level via `google_project_iam_member`. This allows key creation and token minting for ANY service account in the project. Resource-level bindings on the specific target SAs already exist at lines 98-122, making the project-level grants redundant and overly broad.
  Recommendation: Remove the project-level `google_project_iam_member.vault_impersonator` for `serviceAccountTokenCreator`. For `serviceAccountKeyAdmin`, assess whether it's needed at all — the Vault GCP secrets engine only requires `serviceAccountTokenCreator` for impersonation mode. If key management IS needed, scope it with an IAM Condition to the specific SA.
  Verification: `gcloud projects get-iam-policy <PROJECT> --flatten='bindings[].members' --filter='bindings.members:vault-impersonator' --format='table(bindings.role)'` shows only scoped roles.

- **[SEC-NET-001#1] Consul ingress gateway LoadBalancer has no source range restriction** — `tf/modules/gke-consul-dataplane/consul-helm.tf:247-260` | Blast: environment | CIS: n/a | Effort: Small | Status: NEEDS-REVIEW
  Description: The ingress gateway LoadBalancer exposes ports 80 and 443 without `loadBalancerSourceRanges`. Unlike the mcp-agent LB (which correctly uses `allowed_ingress_cidrs`), the ingress gateway accepts traffic from any IP.
  Recommendation: Add a `set` block for `ingressGateways.defaults.service.loadBalancerSourceRanges[0]` referencing the same `allowed_ingress_cidrs` variable, or disable the ingress gateway if not actively used (`enable_ingress_gateway = false`).
  Verification: `kubectl get svc -n consul -l component=ingress-gateway -o jsonpath='{.items[0].spec.loadBalancerSourceRanges}'` returns the restricted CIDR list.

- **[SEC-STATE-001#1] SA private keys stored in Terraform state** — `tf/modules/vault-config/gcp-engine.tf:38`, `tf/scenarios/consul-mcp-gke/vault-pki.tf:36` | Blast: infrastructure-wide | CIS: 1.4 | Effort: Large | Status: NEEDS-REVIEW
  Description: `google_service_account_key.vault_impersonator` and `google_service_account_key.vault_gcp_verifier` generate SA keys whose `private_key` is stored in Terraform state. Anyone with state read access can impersonate Vault's GCP secrets engine or the GCP auth verifier.
  Recommendation: Ensure GCS state bucket has restricted IAM (CI/CD SA only), enable CMEK encryption, and enable object versioning. Long-term: migrate to Workload Identity Federation for Vault-to-GCP authentication to eliminate static keys entirely.
  Verification: `gcloud storage buckets get-iam-policy gs://<state-bucket> --format='table(bindings.role,bindings.members)'` shows minimal access.

### MEDIUM

- **[SEC-GKE-001#1] No release channel on GKE cluster** — `tf/modules/gke-consul-dataplane/cluster.tf:26` | Blast: environment | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: The comment on line 26 says "Version managed by release channel (STABLE)" but no `release_channel` block exists. Without it, GKE does not auto-upgrade the control plane.
  Recommendation: Add `release_channel { channel = "STABLE" }` to the cluster resource.
  Verification: `gcloud container clusters describe <CLUSTER> --format='value(releaseChannel.channel)'` returns `STABLE`.

- **[SEC-GKE-002#1] No Application-layer Secrets Encryption** — `tf/modules/gke-consul-dataplane/cluster.tf:17` | Blast: environment | CIS: 8.5.5 | Effort: Medium | Status: NEEDS-REVIEW
  Description: The cluster has no `database_encryption` block. Kubernetes secrets (Consul bootstrap token, CA cert, vault-reviewer token) are stored in etcd without application-layer encryption. Google-managed encryption at rest still applies, but secrets are decryptable by anyone with etcd access.
  Recommendation: Add `database_encryption { state = "ENCRYPTED" key_name = "<KMS-key>" }`. Requires a Cloud KMS key.
  Verification: `gcloud container clusters describe <CLUSTER> --format='value(databaseEncryption.state)'` returns `ENCRYPTED`.

- **[SEC-AUDIT-001#1] No vault_audit resource configured** — all Vault modules | Blast: infrastructure-wide | CIS: n/a | Effort: Small | Status: NEEDS-REVIEW
  Description: No `vault_audit` resource is defined. While HCP Vault Dedicated may provide managed audit logging, it should be explicitly configured and verifiable via Terraform.
  Recommendation: Enable audit logging via `vault_audit` resource, or uncomment the `audit_log_config` block in `hcp-vault/main.tf`.
  Verification: `vault audit list` returns at least one enabled backend.

- **[SEC-SENSITIVE-001#1] TTYD credential exposed as plaintext env var** — `tf/modules/mcp-agents-k8s/deployment.tf:173` | Blast: module | CIS: n/a | Effort: Medium | Status: NEEDS-REVIEW
  Description: `TTYD_CREDENTIAL` is set as a plain `env` value in the pod spec. Anyone with `kubectl describe pod` access can read the credential.
  Recommendation: Store the credential in a Kubernetes Secret (via Vault Secrets Operator or a `kubernetes_secret` resource) and reference it via `env.value_from.secret_key_ref`.
  Verification: `kubectl get deployment mcp-agent -n mcp-agents -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="TTYD_CREDENTIAL")].valueFrom}'` returns a secret reference.

- **[SEC-K8S-001#1] Main app containers have writable root filesystem** — `tf/modules/mcp-agents-k8s/deployment.tf:209,448` | Blast: module | CIS: n/a | Effort: Medium | Status: NEEDS-REVIEW
  Description: The `mcp-app` and `mcp-server` containers have `read_only_root_filesystem = false`. Init containers correctly use `true`. Writable root increases the attack surface if a container is compromised.
  Recommendation: Set `read_only_root_filesystem = true` and mount `emptyDir` volumes for paths needing writes (`/tmp`, `/app/.cache`, etc.).
  Verification: `kubectl get deployment -n mcp-agents -o jsonpath='{..securityContext.readOnlyRootFilesystem}'` returns `true` for all containers.

---

## 2. DRY and Code Reuse

_No findings at MEDIUM or above._

### LOW

- **[DRY-HARDCODE-001#1] mcp_namespace hardcoded in scenario files** — `tf/scenarios/consul-mcp-gke/gke.tf:28`, `vault-config.tf:88` | Blast: module | Effort: Small | Status: VERIFIED
  Description: The string `"mcp-agents"` is hardcoded in two scenario call sites rather than using a shared variable or local.
  Recommendation: Define `local.mcp_namespace = "mcp-agents"` in `locals.tf` and reference it.

---

## 3. Style and Conventions

### LOW

- **[STYLE-FMT-001#1] terraform fmt failure** — `tf/scenarios/consul-mcp-gke/terraform.tfvars` | Blast: CI | Effort: Small | Status: VERIFIED
  Description: `terraform fmt -check` reports formatting errors (missing space before `=`).
  Recommendation: Run `terraform fmt -recursive tf/`.

- **[STK-DEPRECATION-001#1] Deprecated `enable_legacy_abac` argument** — `tf/modules/gke-consul-dataplane/cluster.tf:87` | Blast: module | Effort: Small | Status: VERIFIED
  Description: `enable_legacy_abac` is deprecated in the Google provider. Setting it to `false` is safe but will emit warnings.
  Recommendation: Remove the line. ABAC is disabled by default.

- **[STK-DEPRECATION-001#2] Deprecated `logging_service`/`monitoring_service` string args** — `tf/modules/gke-consul-dataplane/cluster.tf:90-91` | Blast: module | Effort: Small | Status: VERIFIED
  Description: String-based `logging_service` and `monitoring_service` are deprecated in favour of `logging_config {}` and `monitoring_config {}` blocks.
  Recommendation: Migrate to block-based configuration.

---

## 4. Robustness

### MEDIUM

- **[ROB-LIFECYCLE-001#1] No prevent_destroy on critical Vault infrastructure** — `tf/modules/vault-pki-consul/pki.tf:1` (root CA), `tf/modules/vault-config/kv.tf:21` (KV), `tf/modules/vault-config/gcp-engine.tf:65` (GCP secrets) | Blast: infrastructure-wide | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: The Vault PKI root CA mount (`connect_root`, 10-year key), KV v2 mount, and GCP secrets engine have no `lifecycle { prevent_destroy = true }`. Accidentally destroying the root CA invalidates all Consul mTLS certificates.
  Recommendation: Add `lifecycle { prevent_destroy = true }` to `vault_mount.connect_root`, `vault_mount.connect_intermediate`, `vault_mount.secret`, and `vault_gcp_secret_backend.main`.

- **[SEC-PROVIDER-001#1] Provider version constraints pinned to major only** — `tf/scenarios/consul-mcp-gke/versions.tf:20-53` | Blast: infrastructure-wide | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: All providers use `~> X.0` constraints: `kubernetes ~> 2.0`, `helm ~> 2.0`, `consul ~> 2.0`, `vault ~> 4.0`, `google ~> 5.0`. These allow any minor version bump, which on rapidly-evolving providers (kubernetes, helm) can introduce breaking changes.
  Recommendation: Tighten to `~> X.Y` based on current lock file versions (e.g., `~> 5.44` for google, `~> 2.36` for kubernetes).

- **[ROB-DELPROT-001#1] deletion_protection disabled on GKE cluster** — `tf/modules/gke-consul-dataplane/cluster.tf:93` | Blast: environment | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: `deletion_protection = false` allows `terraform destroy` to delete the cluster without confirmation.
  Recommendation: Make it a variable defaulting to `true`, overridden to `false` only for dev.

- **[ROB-TIMEOUT-001#1] No timeouts on GKE cluster or node pool** — `tf/modules/gke-consul-dataplane/cluster.tf:17,110` | Blast: environment | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: GKE cluster creation can take 15-30 minutes. Without explicit `timeouts`, Terraform uses its default (which may cause spurious failures on slow operations).
  Recommendation: Add `timeouts { create = "45m" update = "30m" delete = "30m" }` to both the cluster and node pool resources.

- **[DEAD-CODE-001#1] Dead agent_approle_mount configuration** — `tf/modules/vault-config/kv.tf:51` | Blast: module | CIS: n/a | Effort: Small | Status: VERIFIED
  Description: `agent_approle_mount` is referenced in KV config but no AppRole auth backend exists anywhere in the codebase.
  Recommendation: Remove the dead reference.

### LOW

- **[ROB-UNUSED-002#1] Many module outputs never consumed** — multiple modules | Blast: modules | Effort: Medium | Status: NEEDS-REVIEW
  Description: Significant unused outputs across modules: vault-config (9/15), vault-pki-consul (8/10), gke-consul-dataplane (5/7), hcp-vault (4/7), network (3/8), mcp-agents-k8s (6/7). Some may be consumed by Taskfile scripts or `terraform output` commands.
  Recommendation: Audit outputs against Taskfile usage and remove confirmed dead outputs. Keep outputs consumed by operators or external tooling.

- **[ROB-LIFECYCLE-002#1] force_destroy on GCS bucket** — `tf/scenarios/consul-mcp-gke/consul.tf:18` | Blast: single-resource | Effort: Small | Status: VERIFIED
  Description: `force_destroy = true` on the consul config bucket allows data loss on `terraform destroy`.
  Recommendation: Acceptable for dev. Set to `false` for production environments.

- **[SEC-IMAGE-001#1] Default "latest" image tag** — `tf/modules/mcp-agents-k8s/variables.tf:41` | Blast: module | Effort: Small | Status: VERIFIED
  Description: Default image tag is `"latest"` with `image_pull_policy = "Always"`. Pod restarts may pull different images without any config change.
  Recommendation: Use immutable tags (git SHA or semver) for reproducible deployments.

---

## 5. Simplicity

_No findings — section omitted._

---

## 6. Operational Readiness

### MEDIUM

- **[OPS-LABELS-001#1] GCP resource labeling is incomplete** — `tf/scenarios/consul-mcp-gke/locals.tf:24` | Blast: infrastructure-wide | CIS: n/a | Effort: Medium | Status: NEEDS-REVIEW
  Description: `local.common_labels` is defined with `project`, `environment`, `managed_by`, `scenario`, `datacenter` but applied to only 1 of 15+ GCP resources (the GCS bucket). Consul VMs, GKE cluster, node pool, service accounts, and VPC resources have no environment or managed_by labels.
  Recommendation: Pass `common_labels` into all modules and apply to every GCP resource supporting `labels`.

- **[OPS-MONITOR-001#1] No monitoring or alerting Terraform resources** — project-wide | Blast: infrastructure-wide | CIS: n/a | Effort: Large | Status: NEEDS-REVIEW
  Description: No `google_monitoring_*` resources, alert policies, uptime checks, or log-based metrics are defined. The infrastructure may have monitoring configured outside Terraform.
  Recommendation: Define at minimum: uptime checks for the ttyd endpoint, alert policies for GKE node pool utilization, and log-based metrics for Vault auth failures.

### LOW

- **[OPS-PDB-001#1] PDB min_available=1 with replicas=1 blocks voluntary disruptions** — `tf/modules/mcp-agents-k8s/service.tf:90` | Blast: module | Effort: Small | Status: VERIFIED
  Description: With `replicas = 1` and `min_available = 1`, PDB blocks all voluntary disruptions including node drains and cluster upgrades.
  Recommendation: Use `max_unavailable = 1` instead of `min_available = 1` for single-replica deployments, or increase replicas to 2.

- **[SEC-CONSUL-001#1] Single Consul server (no quorum)** — `terraform.tfvars:27` | Blast: environment | Effort: Medium | Status: NEEDS-REVIEW
  Description: `consul_instance_count = 1` provides no quorum redundancy. Acceptable for dev but a single point of failure.
  Recommendation: Set to 3 for staging/production.

---

## 7. CI/CD and Testing Maturity

### MEDIUM

- **[CI-TEST-001#1] No Terraform tests** — project-wide | Blast: infrastructure-wide | CIS: n/a | Effort: Large | Status: NEEDS-REVIEW
  Description: No `.tftest.hcl`, `*_test.go`, or `tests/` directories exist. Module contracts are unverified by automated tests.
  Recommendation: Add `terraform test` (native, 1.6+) for at least the `network` and `vault-config` modules — these have the most complex validation logic.

- **[CI-POLICY-001#1] No policy-as-code enforcement** — project root | Blast: infrastructure-wide | CIS: n/a | Effort: Medium | Status: NEEDS-REVIEW
  Description: No Sentinel, OPA/Conftest, or policy directories exist. Organizational policies (mandatory labels, encryption, no public-facing LBs) are not machine-enforced.
  Recommendation: Add OPA/Conftest with policies for: mandatory labels, no `0.0.0.0/0` in authorized networks, `deletion_protection = true` on stateful resources.

### LOW

- **[CI-SOFTFAIL-001#1] tfsec and tflint run in soft-fail mode** — `.github/workflows/terraform.yml:91,115` | Blast: CI | Effort: Small | Status: VERIFIED
  Description: tfsec uses `soft_fail: true` and tflint errors are swallowed with `|| true`. Security and lint findings don't block PRs.
  Recommendation: Tighten to hard-fail after addressing baseline findings.

---

## 8. Cross-Module Contracts

_No findings — section omitted. All 7 modules are referenced by the scenario (no orphans). Output-to-input type matching verified. Variable pass-through depth is 2 layers max._

---

## 9. Stack-Specific Findings

_Vault, Consul, and GKE findings are covered in Sections 1 and 4 above._

---

## 10. CLAUDE.md Compliance

| Rule | Code | Match? |
|------|------|--------|
| PKI TTLs: root 10yr, intermediate 5yr, leaf 72h | `pki.tf`: root `max_lease_ttl_seconds = 315360000` (10yr), intermediate `157680000` (5yr), leaf role `ttl = "72h"` | **Yes** |
| No default credentials: vault_users, mcp_ttyd_credential, allowed_ingress_cidrs | All three have `sensitive = true` and no `default` | **Yes** |
| vault_agent_version = 1.21.3 | `variables.tf:84`: `default = "1.21.3"` | **Yes** |
| Naming: {environment}-{component}-{resource} | Resources use `"${var.environment}-..."` pattern consistently | **Yes** |
| IAM least-privilege | Data agent: `storage.objectAdmin + bigquery.dataEditor + bigquery.jobUser`. Compute: `compute.instanceAdmin.v1` | **Yes** (matches CLAUDE.md exactly) |
| No `0.0.0.0/0` for ingress | `allowed_ingress_cidrs` validation rejects it | **Yes** |
| Consul Connect mTLS always on | `global.tls.enabled = true`, `global.tls.httpsOnly = true` | **Yes** |
| Never use `<<-TMPL` heredocs in vault-agent | Templates use `templatefile()` with `.hcl.tpl` files | **Yes** |
| Phase-gated apply | `gke_cluster_ready` controls phase 2/3 module instantiation | **Yes** |

**All CLAUDE.md rules verified as implemented.** No documentation-code divergence detected.

---

## 11. Suppressed Findings

_No suppression file (`.tf-analyze-ignore.yaml`) found. No inline `# tf-analyze:ignore` comments. No findings suppressed._

---

## 12. Positive Findings

1. **Comprehensive variable validation**: Nearly every variable has a `validation {}` block with meaningful regex and error messages — significantly above average.
2. **K8s security hardening**: All containers run as non-root, drop ALL capabilities, use `allow_privilege_escalation = false`. Projected SA tokens with 2h expiry and explicit audience.
3. **Vault secrets in tmpfs**: The `vault-secrets` volume uses `empty_dir { medium = "Memory" }` — secrets never touch node disks.
4. **Zero supply-chain risk**: All modules sourced from local `./` paths. No external registry or git dependencies.
5. **No provisioner blocks**: 100% declarative — no `local-exec` or `remote-exec` anywhere.
6. **Consul deny-by-default**: Service intentions explicitly allow only `mcp-agent → mcp-data-server` and `mcp-agent → mcp-compute-server`. All other traffic denied.
7. **Private cluster with IAP**: Consul VMs have no public IPs (IAP tunnel for SSH). GKE nodes are private. Network uses IAP source range `35.235.240.0/20`.
8. **VPC flow logs enabled**: Subnet logging at 50% sampling with `INCLUDE_ALL_METADATA` and 10-minute intervals (CIS 3.8).
9. **Shielded instances everywhere**: Both Consul VMs and GKE nodes have Secure Boot, vTPM, and integrity monitoring.
10. **Workload Identity enabled**: GKE uses `GKE_METADATA` mode with per-SA GCP bindings. No static SA keys in pods.
11. **PDBs and health probes**: All deployments have PodDisruptionBudgets and both liveness + readiness probes.
12. **CI pipeline**: GitHub Actions runs 4 parallel jobs (fmt, validate, tfsec, tflint) on every PR touching `tf/`, no cloud credentials required.

---

## 13. Recommended Action Plan

| Priority | Finding | Section | Effort | Blast Radius | Description |
|----------|---------|---------|--------|--------------|-------------|
| 1 | SEC-NET-002#1 | Security | Small | infrastructure-wide | Remove `0.0.0.0/0` from `gke_authorized_cidrs`; add validation block rejecting it |
| 2 | SEC-IAM-001#1 | Security | Medium | infrastructure-wide | Remove project-level `serviceAccountKeyAdmin`/`serviceAccountTokenCreator`; resource-level bindings already exist |
| 3 | SEC-NET-001#1 | Security | Small | environment | Add `loadBalancerSourceRanges` to ingress gateway, or disable it |
| 4 | ROB-LIFECYCLE-001#1 | Robustness | Small | infrastructure-wide | Add `prevent_destroy = true` to Vault root CA, intermediate CA, KV mount, GCP secrets engine |
| 5 | ROB-DELPROT-001#1 | Robustness | Small | environment | Set `deletion_protection = true` on GKE cluster (variable with env-specific override) |
| 6 | SEC-SENSITIVE-001#1 | Security | Medium | module | Migrate TTYD_CREDENTIAL from env var to K8s Secret reference |
| 7 | SEC-GKE-001#1 | Security | Small | environment | Add `release_channel { channel = "STABLE" }` to GKE cluster |
| 8 | SEC-PROVIDER-001#1 | Robustness | Small | infrastructure-wide | Tighten provider versions to `~> X.Y` based on lock file |
| 9 | OPS-LABELS-001#1 | Ops | Medium | infrastructure-wide | Propagate `common_labels` to all modules and GCP resources |
| 10 | CI-TEST-001#1 | CI/CD | Large | infrastructure-wide | Add `terraform test` for network + vault-config modules |

### Related Findings

- **SEC-NET-002#1 + SEC-NET-001#1**: Both involve network exposure — address together as a network hardening pass
- **ROB-LIFECYCLE-001#1 + ROB-DELPROT-001#1 + ROB-LIFECYCLE-002#1**: All lifecycle protection gaps — single commit to add `prevent_destroy` and tighten `deletion_protection`
- **SEC-PROVIDER-001#1 + lock file**: Provider reproducibility — tighten constraints AND ensure lock file stays committed
- **CI-TEST-001#1 + CI-POLICY-001#1 + CI-SOFTFAIL-001#1**: CI maturity — address as a single CI hardening initiative

---

## Cost Snapshot

`infracost` not installed — using relative size classes.

| Resource | Sizing | Class | ~$/month |
|----------|--------|-------|----------|
| `google_container_cluster.main` + node pool | Regional, n2-standard-4 ×1 | M | $100–500 |
| `google_compute_instance.consul_server` ×1 | e2-medium | S | $25–100 |
| `hcp_vault_cluster.main` | HCP Vault Dedicated (Plus) | M | $100–500 |
| `google_storage_bucket.consul_config` | Small config bucket | XS | <$5 |
| `google_artifact_registry_repository.mcp` | Docker images | XS | <$5 |
| VPC / NAT / firewall | Supporting infra | S | $25–100 |

_Estimates are directional. Install `infracost` for line-item accuracy, or use the official cloud pricing calculator before procurement decisions._
