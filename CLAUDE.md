# CLAUDE.md — consul-mcp-agents

GKE + Consul Dataplane + HCP Vault Dedicated + MCP AI Agents.
Vault PKI CA + dynamic GCP credentials, Consul mTLS mesh, LangChain agents on GKE.

## Commands

```sh
# Required env var (replaces hcp_client_secret in tfvars)
export TF_VAR_hcp_client_secret='...'    # HCP service-principal secret

task --list              # show all tasks
task tf:plan             # plan with var file
task tf:apply            # docker rebuild + full apply
task smoke               # end-to-end functional smoke test, PASS/FAIL/SKIP report
task hcp:list-orphans    # find leaked random_pet HVNs from prior runs
task consul:bootstrap-acl       # bootstrap Consul ACLs (idempotent); always syncs K8s secret
task consul:verify-auth-method  # confirm consul-k8s-component-auth-method exists on server
task consul:helm-clean          # uninstall Consul Helm + delete namespace (clean retry)
task consul:refresh-tls         # re-issue Consul server TLS cert; sync consul-ca-cert K8s secret
tflint --init --config .tflint.hcl  # install tflint plugins (first run)
tflint --config .tflint.hcl --chdir tf/scenarios/consul-mcp-gke  # local lint
```

## Terraform conventions

- **Module inputs**: all modules expose `project_id`, `region`, `environment`
- **Naming**: `{environment}-{component}-{resource}`
- **No default credentials**: `vault_users`, `mcp_ttyd_credential`, `allowed_ingress_cidrs` must be set in tfvars. Validation rejects `0.0.0.0/0`.
- **`hcp_client_secret` lives in env, not tfvars**: Terraform reads `TF_VAR_hcp_client_secret`; tasks that hit the HCP REST API directly (`smoke`, `hcp:list-orphans`) read the same var via `scripts/hcp-token.sh`. The shell `export` is the only ergonomic way; do not re-introduce the secret to `terraform.tfvars`.
- **Sensitive vars need taint**: Terraform won't detect changes to `sensitive = true` fields. Use `terraform taint <resource>` then apply.
- Always run `terraform fmt -recursive` before committing
- GKE uses native `google_container_cluster` / `google_container_node_pool` — do not migrate to community module
- CI runs `fmt -check`, `validate`, `tfsec`, and `tflint` on every PR touching `tf/` — fix locally before pushing
- **Stateful resources have `prevent_destroy = true`**: Vault PKI root + intermediate mounts (`vault-pki-consul`), Vault KV mount (`vault-config`), and the GCP secrets backend. Destroying any of these would invalidate every Connect mTLS cert in the mesh or wipe MCP agent config. To intentionally destroy, comment out the lifecycle block, apply, then restore.
- **Provider versions are pinned to minor**: `~> 5.44` (google), `~> 4.4` (vault), `~> 2.36` (kubernetes), `~> 2.17` (helm), `~> 2.21` (consul). Bumps require regenerating `.terraform.lock.hcl` (`terraform init -upgrade`) and re-running CI.

## Conventions

- Never hardcode GCP project IDs — always `var.project_id`
- Vault policies: least-privilege, add paths explicitly
- PKI TTLs: root 10yr, intermediate 5yr, leaf 72h (auto-rotate)
- Consul Connect mTLS always on — no plaintext service communication

## Service mesh architecture

- **Local/stdio**: MCP servers as subprocesses (`transport: stdio`). For local dev.
- **GKE/SSE**: Separate K8s Deployments. Agent connects via Consul upstreams on `localhost:20000` (data), `localhost:20001` (compute).

| Deployment | Purpose | Port |
|---|---|---|
| `mcp-agent` | CLI + ttyd web terminal | 7681 |
| `mcp-data-server` | GCS + BigQuery MCP (SSE) | 8080 |
| `mcp-compute-server` | GCE MCP (SSE) | 8080 |

**Adding a new MCP server**: add entry to `local.mcp_servers` in `deployment.tf` (including `tags` list and `meta` map — see below), add upstream to agent annotation, add to `mcp_servers` map in `kv.tf` `yamlencode()` block. The `for_each` creates deployment, service, PDB, SA, ConfigMap, and intention automatically.

### Consul catalog metadata (tags + meta)

Each MCP server registers with Consul carrying `ServiceTags` and `ServiceMeta` derived from `local.mcp_servers[*].tags` / `meta`. Annotations are emitted as `consul.hashicorp.com/service-tags` (comma-joined) and `consul.hashicorp.com/service-meta-<key>` (one per entry).

What this gives us:
1. **Self-documenting catalog** — `curl /v1/catalog/service/mcp-data-server | jq '.[0].ServiceMeta'` answers "what does this service do, what's it allowed to touch, is it cost-capped?" without reading Terraform or source. Useful for on-call, onboarding, and audit.
2. **Filterable ops queries** — `consul catalog services -filter 'Meta.domain == "gcp-data"'`, Grafana labels keyed by `Meta.capabilities`, Consul-exporter metrics broken down by tag.
3. **Tag-scoped intentions (latent)** — ServiceIntentions can match source/destination by tag, so future policies like "only `read-only` clients reach `mcp-data-server`" become one-line rules instead of per-service enumeration.
4. **Migration-free Phase 2** — if a fourth server or multi-instance routing later forces capability-based discovery, the metadata is already in the catalog; no retrofit.

What it does **not** give us: runtime behavior change (the agent still dials hardcoded `localhost:20000/20001` upstreams), new auth (`capabilities.yaml` still owns RBAC), or capability routing.

Conventions when extending:
- `tags` are short identifiers used for filtering/intentions (`read-only`, `gcs`, `vm-lifecycle`).
- `meta.capabilities` is a CSV of MCP tool names; `meta.domain` is a single coarse-grained owner (`gcp-data`, `gcp-compute`); other meta keys are free-form but should be queryable (avoid embedding JSON).
- Keep tags/meta in sync with the actual tools registered in the server's `list_tools()` — this is the contract the catalog publishes.

## Critical operational rules

### Vault K8s auth
- `vault write auth/kubernetes/config` replaces ALL fields — never omit `kubernetes_ca_cert` or `issuer`
- Never set `audience` on Vault K8s roles — causes "invalid audience (aud) claim" errors
- `vault-reviewer` SA/CRB/Secret are top-level in `vault-config.tf`. `phase3:apply` explicitly targets them alongside `module.mcp_agents`. If pods show `Init:0/2` with 403: check `kubectl get clusterrolebinding vault-reviewer`, run `task vault:configure-k8s-auth`

### Consul TLS
- vault-agent writes TLS as `vault:vault 0640`. Consul reads via: (1) Packer `usermod -aG vault consul`, (2) vault-agent template `chgrp consul` post-render. Both required — losing either causes crash-loops.
- **Do NOT `systemctl reload consul` to renew certs** — use `task consul:refresh-tls` or `vault-agent-cert-refresh.sh` directly. SIGHUP causes Consul to re-initialize the Vault CA provider → new Connect intermediate CA → all pods crash.
- `consul-ca-cert` K8s secret has `lifecycle { ignore_changes = [data] }`. Terraform seeds it; `consul:refresh-tls` manages live data.

### Phase-gated apply
1. **Phase 1** (`gke_cluster_ready = false`): VPC, GKE, Consul VMs, HCP Vault
2. **Phase 2** (auto-detected by `gke:ensure-ready`): Consul Helm, VSO
3. **Phase 3**: MCP deployments + vault-reviewer resources
4. **Phase 4**: Full reconcile

Never set `gke_cluster_ready = true` before GKE exists — data source lookup will fail.

**Phase 3 prerequisite**: The Docker image must exist in Artifact Registry before `phase3:apply`. If pods show `ImagePullBackOff`, run `task docker:build && task docker:push` then `kubectl rollout restart deployment -n mcp-agents`.

### Consul Helm ACL init
The `consul-server-acl-init` Job must complete before dataplane pods authenticate. `wait_for_jobs = true` in `helm_release` ensures this. Consul VMs must use the **private** GKE endpoint for TokenReview (`gke:ensure-ready` auto-populates it).

**Recovery** (auth method missing): `task consul:helm-clean` then `task phase2:apply`

### Recovery: cert expired, pods in CrashLoopBackOff
```sh
task consul:refresh-tls
kubectl rollout restart deployment -n consul
```

### Recovery: full destroy → re-deploy (canonical sequence)

A clean destroy of the audit-hardened (commit `32e412d`) stack requires neutralising **two** classes of protection before `task destroy`. Skipping either causes an interactive-looking failure mid-destroy. Restore both after destroy completes — Terraform applies will re-add them on the new resources.

1. **Flip `prevent_destroy` on Vault stateful resources** (4 lines, all `prevent_destroy = true`):
   - `tf/modules/vault-config/kv.tf` (KV mount)
   - `tf/modules/vault-config/gcp-engine.tf` (GCP secret backend)
   - `tf/modules/vault-pki-consul/pki.tf` (root + intermediate CA mounts — 2 lines)

   Use a sentinel marker (`# TEMP-OVERRIDE-DESTROY`) so you can grep-restore them.

2. **Set `gke_deletion_protection = false` in tfvars and apply the flag flip** (cluster-side `deletion_protection` is the real GCP-side block; Terraform's `prevent_destroy` is separate):
   ```sh
   echo 'gke_deletion_protection = false # TEMP-OVERRIDE-DESTROY' >> tf/scenarios/consul-mcp-gke/terraform.tfvars
   terraform -chdir=tf/scenarios/consul-mcp-gke apply -auto-approve \
     -target=module.gke.google_container_cluster.main
   ```

3. `task --yes destroy`

4. After destroy succeeds, **restore everything**: revert all four `prevent_destroy` lines, remove the `gke_deletion_protection` line.

### Recovery: network drop mid-apply (orphan resources, state lock, errored.tfstate)

Long applies (HCP Vault provisioning ~10m, GKE ~8m, Helm ~5m) frequently lose connectivity to `storage.googleapis.com` or `container.googleapis.com`, leaving:
- A stale `default.tflock` object in the GCS state bucket
- An `errored.tfstate` file in the scenario dir
- Possibly an orphan resource on the cloud side that's not in remote state

Recovery sequence:
```sh
gsutil rm gs://<state-bucket>/terraform/consul-mcp-gke/default.tflock
terraform -chdir=tf/scenarios/consul-mcp-gke state push tf/scenarios/consul-mcp-gke/errored.tfstate
rm tf/scenarios/consul-mcp-gke/errored.tfstate
```

If a resource exists on the cloud but not in state (e.g., GCE VM, GKE cluster), either:
- `terraform import <addr> <id>` (preferred, but may fail if any provider config is unresolvable — the helm/consul providers in `versions.tf` depend on apply-time values)
- Or delete the orphan via `gcloud` and re-run the relevant phase to recreate

### Recovery: tainted resource after partial create

If terraform's apply was interrupted *after* a resource was created on the cloud but *before* state was saved, on the next plan the resource appears as **tainted** ("must be replaced"). For protected resources (`deletion_protection`, `prevent_destroy`) this surfaces as a confusing "cannot destroy" error during what looks like a creation flow. Verify the resource is actually healthy on the cloud, then `terraform untaint <addr>`.

### Recovery: docker push hangs silently

`docker push` can stall after appearing to push all layers (no error, just no progress). The push client output is **not** authoritative — check Artifact Registry directly:
```sh
gcloud artifacts docker tags list us-central1-docker.pkg.dev/<project>/<repo>/vault-mcp-agents
```
If the tag is missing, kill the stuck `docker push` PID and retry.

### Recovery: Vault K8s auth — JWT field looks empty after taint+apply

`token_reviewer_jwt` is a `sensitive` field, and Terraform won't always re-write it during a `taint` + targeted apply (the K8s auth backend config resource sometimes plans no change even when tainted). When pods show `Init:0/2` with `permission denied` on `auth/kubernetes/login`, fall back to writing all five fields directly:
```sh
vault write auth/kubernetes/config \
  kubernetes_host="https://<gke-public-endpoint>:443" \
  kubernetes_ca_cert="$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="<ctx>")].cluster.certificate-authority-data}' | base64 -d)" \
  token_reviewer_jwt="$(kubectl get secret vault-reviewer-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)" \
  issuer="https://container.googleapis.com/v1/projects/<project>/locations/<region>/clusters/<cluster>" \
  disable_iss_validation=true \
  disable_local_ca_jwt=true
```
A read-back will show `token_reviewer_jwt` as length 0 (Vault never echoes it back) — that's expected. Verify by deleting the failing pods and watching them progress past Init.

### HCP Vault → GKE master access (`gke_enable_master_authorized_networks`)

The audit hardening (commit `32e412d`) added `master_authorized_networks_config` to the GKE cluster. With it enabled and only operator IPs in `gke_authorized_cidrs`, vault-agent-init pods get `permission denied` on `auth/kubernetes/login` because HCP Vault's TokenReview call to the K8s API is blocked — HCP Vault Public Tier has no stable egress IPs to allowlist, and no HVN→VPC peering exists in this scenario (`module.hcp_vault.hcp_hvn.main` is created but no `hcp_*_network_peering` resource), so the private-endpoint path doesn't work either.

The block is now controlled by `gke_enable_master_authorized_networks` (scenario var → `enable_master_authorized_networks` on the module), wrapping `master_authorized_networks_config` in a `dynamic` block. **Default is `false`** — master endpoint open to the internet, matching the pre-audit behaviour. Set true once you've solved the connectivity in one of two ways:

1. **HVN-VPC peering** (proper fix): add `hcp_*_network_peering` + Cloud Router routes so the HVN can reach the GKE master CIDR over private peering, then point `kubernetes_host` at the private endpoint. Then set `gke_enable_master_authorized_networks = true` and leave `gke_authorized_cidrs` operator-only.
2. **HCP Plus-tier egress CIDRs** (allowlist): HashiCorp publishes per-region egress CIDRs for Plus-tier clusters; add them to `gke_authorized_cidrs` alongside the operator IP, then set `gke_enable_master_authorized_networks = true`. (Note: HashiCorp may rotate these.)

### Recovery: Vault auth role policies / audience

The two K8s auth roles (`mcp-agent`, `mcp-server`) both reference policy `mcp-server-policy` (singular policy serves both). If either role ends up with a missing/wrong policy, vault-agent will authenticate but get `permission denied` on subsequent secret reads (`secret/data/mcp-agents/{config,policies,llm-keys}`). Audience must remain **unset** on the role: the projected SA token volume mounts use `audience: "vault"`, but Vault validates audience locally and rejects when role's `audience` is set on this GKE OIDC issuer (`invalid audience (aud) claim`). Direct fix:
```sh
vault write auth/kubernetes/role/mcp-agent \
  bound_service_account_names=mcp-agent \
  bound_service_account_namespaces=mcp-agents \
  token_policies="default,mcp-server-policy" token_ttl=1h token_max_ttl=24h
vault write auth/kubernetes/role/mcp-server \
  bound_service_account_names="mcp-server,mcp-data-server,mcp-compute-server" \
  bound_service_account_namespaces=mcp-agents \
  token_policies="default,mcp-server-policy" token_ttl=1h token_max_ttl=24h
```

### Operator IP rotation: two CIDR fields, only one auto-syncs

`task ingress:sync-ip` only updates `allowed_ingress_cidrs` (LoadBalancer source ranges). `gke_authorized_cidrs` (master_authorized_networks) does **not** auto-sync — when the operator's public IP rotates, kubectl breaks silently with `i/o timeout` to the master endpoint. Either run `task ingress:sync-ip` then manually update `gke_authorized_cidrs` and `terraform apply -target=module.gke.google_container_cluster.main`, or fix `scripts/ingress-sync-ip.sh` (extension) to update both.

### Vault-agent HCL heredoc bug
- **Do NOT use `<<-TMPL` heredocs in vault-agent templates to render YAML/config files.** Vault-agent's HCL parser corrupts indentation: lines after the first get spurious extra whitespace, producing invalid YAML. Use `yamlencode()` in Terraform to store the complete YAML as a single KV string, and a one-liner vault-agent template to read/write it: `"{{ with secret \"path\" }}{{ .Data.data.settings_yaml }}{{ end }}"`.
- The KV secrets `mcp-agents/config` and `mcp-agents/policies` each store a single pre-rendered YAML field (`settings_yaml` / `policies_yaml`), not individual config fields.

### Provider gotchas
- **HCP Vault admin token expires in 6h** — `terraform apply -target=module.hcp_vault.hcp_vault_cluster_admin_token.main` will *not* refresh it on its own (terraform sees no diff). Force regen via `terraform taint module.hcp_vault.hcp_vault_cluster_admin_token.main` then `terraform apply -target=...` — confirmed by "1 added, 1 destroyed" on apply.
- **`terraform init -upgrade` queries the registry every run** — when the Terraform Registry is flaky (frequent `context deadline exceeded`), init fails even though all providers are already cached locally. Workaround for transient outages: run `terraform -chdir=tf/scenarios/consul-mcp-gke init -backend-config="bucket=..."` (without `-upgrade`) once to satisfy `tf:init`, then re-run the phase task.
- **HCP HVN org quota** — the org has a hard cap on concurrent HVNs (failure mode: `HVN quota reached, quota_value: "0"`). Each `terraform apply` creates one HVN named `${random_pet.prefix}-hvn`; if `terraform destroy` is skipped, every prior run leaves an orphan HVN + Vault cluster. Before applying, run `task hcp:list-orphans` to surface random_pet-shaped HVNs (`^[a-z]+-[a-z]+-hvn$`); delete unused pairs (cluster first, then HVN) via the HCP UI or API. Do **not** delete HVNs whose names don't match the random_pet pattern — they belong to other demos.
- **Consul provider needs IAP tunnel** — `task consul:tunnel` first, set `consul_address_override = "https://localhost:18501"` with `insecure_https = true`
- **K8s provider identity bug**: `terraform apply`/`destroy` may hit `Unexpected Identity Change`. The fix script (`tf-fix-k8s-identity.sh`) unconditionally removes all matched resources from state before apply/destroy — Terraform recreates them cleanly. Runs automatically in `phase3:apply` (scoped to `consul_` resources only); for destroy use `task tf:fix-k8s-identity`. **IMPORTANT**: When passing custom patterns to the script, scope to the specific resource type affected (e.g. `consul_`), not the entire module — removing all K8s resources from state forces re-import of every deployment, service, configmap, PDB, and SA.

## Python patterns

- **RBAC at LLM level** — tool filtering in `agent.py`. MCP servers trust the caller. Always add new tools to `capabilities.yaml` role definitions.
- **SQL validation** — `_is_read_only_query()` uses sqlglot AST. Falls back to regex.
- **Adding a new MCP tool**: add to server's `list_tools()` + `call_tool()`, add to `capabilities.yaml`, rebuild: `task docker:build && task docker:push && task mcp:restart`

## Security rules

- BigQuery: DML/DDL blocked via sqlglot AST. Cost capped by `BQ_MAX_BYTES_BILLED` (1 GB default).
- Compute: `ALLOWED_MACHINE_TYPES` whitelist (e2/n2 types)
- All tool handlers validate required args before GCP calls
- Error sanitization: only `type(exc).__name__` returned to LLM, details logged server-side
- `allowed_ingress_cidrs` has no default, rejects `0.0.0.0/0`. Same validation applies to `gke_authorized_cidrs` (operator + HCP CIDRs only — never the open internet).
- IAM: least-privilege SAs (`storage.objectAdmin` not `storage.admin`, `compute.instanceAdmin.v1` not `compute.admin`)
- **Vault impersonator SA has no project-level IAM grants** — `serviceAccountTokenCreator` is bound only to the specific data/compute agent SAs via `google_service_account_iam_member`. Adding a project-level role on this SA would broaden blast radius to every SA in the project.
- **K8s pods run with `read_only_root_filesystem = true`** — agent and server containers each mount a tmpfs `emptyDir` at `/tmp` for the readiness probe sentinel and any process-local writes. Any new container that needs to write outside `/tmp` requires its own writable `volume_mount`; do not flip ROFS off.
- **Sensitive env vars come from Secrets, not plain `value`** — e.g. `TTYD_CREDENTIAL` is sourced via `secret_key_ref` from `kubernetes_secret.ttyd_credential` so it never appears in `kubectl describe pod` or audit logs. Apply the same pattern to any new credential env var.
- **Consul ingress gateway LB is restricted** — Helm values include `loadBalancerSourceRanges` derived from `allowed_ingress_cidrs`. Matches the mcp-agent LB pattern; do not expose the gateway openly.
- **GKE uses STABLE release channel + 45m create timeout** — control plane and node pools auto-upgrade. Optional `gke_database_encryption_key` (Cloud KMS resource name) enables Application-layer Secrets Encryption (CIS 8.5.5) when set; empty default falls back to Google-managed encryption at rest.
- Docker: Chainguard Wolfi-based images (`cgr.dev/chainguard/wolfi-base`, `cgr.dev/chainguard/python:latest-dev`) — zero/near-zero CVEs vs. dozens in `python:3.11-slim`. Runtime `python-3.14` apk version must match builder `latest-dev` Python version.
- Docker binary verification: Vault uses GPG-signed `SHA256SUMS` from HashiCorp (key `C874011F0AB405110D02105534365D9472D7468F`); ttyd uses upstream `SHA256SUMS` from GitHub release. No hardcoded checksums — version bumps only require changing the `ARG` version.

## CI/CD

**GitHub Actions pipeline** (`.github/workflows/terraform.yml`) runs on PRs and pushes to `main` that touch `tf/` files. Four jobs, no cloud credentials required:

| Job | Tool | Purpose |
|-----|------|---------|
| `fmt` | `terraform fmt -check -recursive` | Catch formatting drift |
| `validate` | `terraform init -backend=false && validate` | Syntax + internal consistency |
| `tfsec` | `aquasecurity/tfsec-action` | Static security analysis (CIS, OWASP) |
| `tflint` | `tflint` + google plugin | Provider-aware linting (invalid types, deprecated args) |

- **No cloud credentials needed** — validation uses `-backend=false`
- **Applies remain manual** via Taskfile (`task tf:plan` / `task tf:apply`) — the phase-gated workflow is too complex for automated apply
- **tfsec hard-fails** the pipeline on any finding (`soft_fail: false`). tflint also hard-fails — the per-module loop tracks an `exit_code` and exits non-zero if any module fails.
- **tflint config**: `.tflint.hcl` at repo root, uses the `google` provider ruleset
- To run the same checks locally before pushing: `terraform fmt -check -recursive tf/ && tflint --init --config .tflint.hcl && tflint --config .tflint.hcl --chdir tf/scenarios/consul-mcp-gke`

## Deployment discipline

**All fixes must be automated.** No "run this manually after deploy" — encode in Taskfile tasks, Terraform, or Packer.

**Every change must**: update docs if applicable, state the apply commands:
- Terraform: `task tf:plan` then `task tf:apply`
- Docker/Python: `task docker:build && task docker:push && task mcp:restart`
- Packer: `task packer:build` then `task tf:apply`
- Full: `task all`

## Keeping CLAUDE.md current

Update this file whenever you:
- Add or remove a Taskfile task (update Commands)
- Discover a new failure mode or operational pitfall (add to Critical operational rules)
- Change a Terraform convention, naming scheme, or module interface
- Add a new security control or change an existing one
- Resolve a recurring mistake — capture the prevention rule here

Do not wait to be asked. If a change would have made this session easier had it been written down before, write it down now.
