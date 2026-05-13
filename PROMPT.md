# prompt.md — Recreation Prompt for consul-mcp-agents

This prompt contains enough detail to recreate the entire consul-mcp-agents repository from scratch. It is organized by component, with implementation-level specifics for each file.

---

## 1. Project Overview

Build a production-grade infrastructure project that deploys MCP-driven AI agents on GKE, secured by Consul service mesh (mTLS) and HCP Vault Dedicated (PKI CA + dynamic GCP credentials). The agents talk to Anthropic or OpenAI via their official SDKs (no LangChain) and reach GCP services (GCS, BigQuery, GCE) through MCP (Model Context Protocol) tool servers. Access control is enforced at three layers: Vault policies (per-user), Consul intentions (per-service), and LLM tool filtering (per-role).

### High-level architecture

```
User (browser) → ttyd web terminal → vault-mcp-agents CLI
  → Vault userpass login → role determination (operator/analyst/viewer)
  → Agent selection (data_agent or compute_agent)
  → MCP connection: SSE through Envoy sidecar upstream (localhost:20000/20001)
    → Consul Connect mTLS → MCP server pod (ServiceIntention enforced)
  → MCP server fetches 5-min GCP OAuth2 token from its own vault-agent file
  → LLM REPL (Anthropic Claude or OpenAI) with filtered tool list
  → MCP tool calls → GCP API operations → results back to user
```

### Infrastructure layers

| Layer | Component | Implementation |
|---|---|---|
| Secrets + PKI | HCP Vault Dedicated | Root CA (EC P-384, 10yr) → Intermediate CA (EC P-256, 5yr) → 72h leaf certs |
| Service mesh | Consul (external VMs, dataplane mode) | mTLS between all services, intentions for access control |
| Compute | GKE (private cluster, Calico, Workload Identity) | 3 deployments: agent, data-server, compute-server |
| Credentials | Vault GCP secrets engine | 5-min OAuth2 tokens via SA impersonation |
| Application | Python 3.11 CLI + MCP servers | Click CLI, asyncio, Starlette/uvicorn SSE transport |
| Access control | Consul intentions + Vault policies + capabilities.yaml | Three roles: operator (full), analyst (read+query), viewer (read-only) |

---

## 2. Repository Structure

```
consul-mcp-agents/
├── CLAUDE.md                    # AI assistant instructions
├── README.md                    # User-facing documentation
├── Taskfile.yml                 # Task orchestration (replaces Makefile)
├── pyproject.toml               # Python package definition
├── .gitignore
├── tf/
│   ├── modules/
│   │   ├── network/             # VPC, subnets, Cloud NAT, firewall
│   │   ├── hcp-vault/           # HVN, Vault Dedicated cluster, admin token
│   │   ├── vault-pki-consul/    # Root/Intermediate PKI, GCP auth, policies
│   │   ├── vault-config/        # K8s auth, GCP secrets engine, KV, userpass
│   │   ├── consul/              # Consul server GCE VMs
│   │   ├── gke-consul-dataplane/ # GKE cluster, node pool, Consul Helm
│   │   └── mcp-agents-k8s/     # 3 K8s deployments, RBAC, intentions
│   └── scenarios/
│       └── consul-mcp-gke/      # Main scenario wiring all modules
├── src/vault_mcp_agents/
│   ├── __init__.py
│   ├── main.py                  # Click CLI entry point
│   ├── config.py                # Dataclass config loaders
│   ├── vault_client.py          # hvac wrapper
│   ├── agent.py                 # Session orchestrator + LLM REPLs
│   └── mcp/
│       ├── __init__.py
│       ├── data_server.py       # GCS + BigQuery MCP server (8 tools)
│       └── compute_server.py    # GCE MCP server (6 tools)
├── config/
│   └── settings.yaml            # Default config for local dev
├── policies/
│   └── capabilities.yaml        # Role-based tool access matrix
├── docker/
│   ├── Dockerfile               # Multi-stage Python + Vault + ttyd
│   └── entrypoint.sh            # Container startup script
├── packer/
│   ├── gcp-almalinux-consul-server.pkr.hcl
│   ├── configs/
│   │   ├── consul-server.hcl
│   │   └── vault-agent-consul.hcl.tmpl
│   └── scripts/
│       ├── provision-vault-agent.sh
│       └── provision-consul.sh
├── docs/diagrams/
│   └── generate_diagrams.py     # Matplotlib-based architecture diagrams
└── scripts/                     # (optional helper scripts)
```

---

## 3. Terraform Modules

### 3.1 Module: network (`tf/modules/network/`)

**Purpose**: VPC infrastructure for Consul VMs and GKE.

**Files**: `main.tf`, `variables.tf`, `outputs.tf`

**Resources**:
- `google_compute_network` — custom-mode VPC (no auto subnets)
- `google_compute_subnetwork` — primary subnet with two secondary IP ranges:
  - `pods` — for GKE pod IPs (e.g., `/22`)
  - `services` — for GKE service IPs (e.g., `/22`)
  - Private Google Access enabled, flow logs (10-min aggregation, 50% sampling)
- `google_compute_router` + `google_compute_router_nat` — Cloud NAT for private instance egress (no public IPs)
- Firewall rules:
  - `consul-internal` — ports 8300-8503 TCP+UDP between consul-server tagged instances
  - `iap-ssh` — SSH (22) + HTTPS (8501) from IAP range `35.235.240.0/20`
  - `gke-master-to-nodes` — ports 443, 8443, 10250 from GKE master CIDR to nodes

**Standard inputs**: `project_id`, `name_prefix`, `region`, `subnet_cidr`, `pods_cidr`, `services_cidr`, `gke_master_cidr`

**Outputs**: `network_name`, `network_self_link`, `subnet_self_link`, `pods_range_name`, `services_range_name`, `router_name`

### 3.2 Module: hcp-vault (`tf/modules/hcp-vault/`)

**Purpose**: HCP Vault Dedicated cluster with HVN.

**Files**: `main.tf`, `variables.tf`, `outputs.tf`

**Resources**:
- `hcp_hvn` — HashiCorp Virtual Network (cloud_provider = "aws", HCP requirement)
- `hcp_vault_cluster` — Vault Dedicated cluster (tier validated: plus_small/plus_medium/plus_large/starter_small)
- `hcp_vault_cluster_admin_token` — ephemeral admin token (6h expiry, used only during Terraform apply)

**Critical notes**:
- HCP Vault runs on AWS — no GCP VPC peering possible. All connectivity via public HTTPS endpoint.
- Admin token expires after 6h. Subsequent applies >6h apart need `terraform apply -target=module.hcp_vault` to regenerate.

**Outputs**: `vault_public_endpoint_url`, `vault_private_endpoint_url` (same as public), `admin_token` (sensitive), `cluster_id`, `hvn_id`

### 3.3 Module: vault-pki-consul (`tf/modules/vault-pki-consul/`)

**Purpose**: Vault PKI certificate hierarchy for Consul Connect mTLS.

**Files**: `pki.tf`, `auth-gcp.tf`, `policy.tf`, `variables.tf`, `outputs.tf`

**Certificate hierarchy**:
```
Root CA (vault_mount "connect-root")
  - Type: pki, max_lease_ttl = 87600h (10 years)
  - Root cert: internal (key_type=ec, key_bits=384), self-signed
  - Subject: CN=Consul Connect Root CA

Intermediate CA (vault_mount "connect-intermediate")
  - Type: pki, max_lease_ttl = 43800h (5 years)
  - CSR signed by root CA
  - Subject: CN=Consul Connect Intermediate CA

Roles:
  - "consul-connect": allow_any_name=true, allow_subdomains=true, generate_lease=true,
    max_ttl=72h, key_type=ec, key_bits=256 — for service mesh leaf certs
  - "consul-server-tls": allowed_domains=["{datacenter}.consul"], allow_subdomains=true,
    max_ttl=72h, key_type=ec, key_bits=256 — for Consul server gossip/RPC TLS
```

**GCP auth backend**:
- `vault_gcp_auth_backend` — mount at `auth/gcp`, credentials from SA key JSON
- `vault_gcp_auth_backend_role` — type=iam, bound to consul-server SA email
- Required because HCP Vault has no GCP ADC; explicit credentials needed for JWT verification

**Policies**:
- `consul-server-policy` — full PKI access (issue, sign, read CA chain)
- `consul-connect-ca-policy` — minimal for Consul Connect CA provider

**Inputs**: `vault_addr`, `root_pki_path`, `intermediate_pki_path`, `datacenter`, `org_name`, `consul_server_sa_email`, `vault_gcp_auth_credentials_json`

### 3.4 Module: vault-config (`tf/modules/vault-config/`)

**Purpose**: Application-level Vault configuration — auth methods, secrets engines, policies, demo users.

**Files**: `auth-k8s.tf`, `gcp-engine.tf`, `auth-userpass.tf`, `kv.tf`, `variables.tf`, `outputs.tf`

**Kubernetes auth backend** (`auth-k8s.tf`):
- Gated on `var.gke_endpoint != ""` (count = 0 before GKE exists)
- Config requires: `kubernetes_host`, `kubernetes_ca_cert`, `token_reviewer_jwt`, `issuer`, `disable_iss_validation=true`, `disable_local_ca_jwt=true`
- Roles:
  - `mcp-server` — bound SAs: mcp-server, mcp-data-server, mcp-compute-server (namespace: mcp-agents)
  - `mcp-agent` — bound SA: mcp-agent (namespace: mcp-agents)
  - Token TTL: 3600s, max: 86400s
- NEVER set `audience` on roles — causes "invalid audience claim" errors with projected tokens

**GCP secrets engine** (`gcp-engine.tf`):
- Mount at `gcp`, credentials from SA key JSON
- Default and max lease: 300s (5 minutes)
- Impersonated accounts:
  - `data-agent-gcp` → data-agent SA (roles: storage.objectAdmin, bigquery.dataEditor, bigquery.jobUser)
  - `compute-agent-gcp` → compute-agent SA (roles: compute.instanceAdmin.v1)
- Impersonator SA needs: serviceAccountKeyAdmin, serviceAccountTokenCreator

**KV v2 secrets** (`kv.tf`):
```
secret/
  mcp-agents/
    config        → settings.yaml (vault addr, auth, LLM config, agent/server defs)
    policies      → capabilities.yaml (role→tool matrix)
    llm-keys      → {anthropic_api_key, openai_api_key}
  consul/
    acl-token     → {token: <bootstrap-token>}
```

**Userpass auth** (`auth-userpass.tf`):
- Three demo users (alice=operator, bob=analyst, carol=viewer)
- Each mapped to corresponding Vault policy
- Policies grant: KV read, GCP secrets engine token generation for allowed rolesets

### 3.5 Module: consul (`tf/modules/consul/`)

**Purpose**: External Consul control plane on GCE VMs (no Consul servers in GKE).

**Files**: `main.tf`, `variables.tf`, `outputs.tf`, `templates/consul-server-startup.sh.tpl`

**Resources**:
- `data.google_compute_image` — latest from `almalinux-consul-server-vault` family
- `google_compute_instance` (count = var.instance_count, validated to 1/3/5):
  - No public IP, Shielded VM, tags: consul-server, vault-client
  - GCP metadata attributes: vault-address, vault-gcp-auth-role, vault-root-pki-path, vault-inter-pki-path, consul-datacenter, consul-bootstrap-expect, consul-retry-join
  - Startup script: renders runtime-config.hcl (node_name, bootstrap_expect, retry_join via GCP internal DNS)
  - `lifecycle { ignore_changes = [boot_disk.image] }` — prevents recreation on Packer rebuild

**SA is NOT created in this module** — accepted as `consul_server_sa_email` input. Created in the scenario's `vault-pki.tf` to allow Vault GCP auth binding before VMs boot.

### 3.6 Module: gke-consul-dataplane (`tf/modules/gke-consul-dataplane/`)

**Purpose**: Private GKE cluster configured for Consul dataplane mode.

**Files**: `cluster.tf`, `consul-helm.tf`, `variables.tf`, `outputs.tf`

**GKE cluster** (`cluster.tf`):
- Uses native `google_container_cluster` + `google_container_node_pool` — NOT the community module
- Private cluster: private nodes, public endpoint (for kubectl access)
- Calico network policy (required for Consul Connect intentions)
- Workload Identity enabled
- Release channel: STABLE (auto-managed versions)
- Node pool: e2-standard-4, max_pods_per_node=32, UBUNTU_CONTAINERD, 100GB SSD
- Shielded nodes, auto-repair, auto-upgrade, max_surge=1, max_unavailable=0
- Workload Identity bindings for data-agent and compute-agent SAs

**Consul Helm** (`consul-helm.tf`, gated on `var.gke_endpoint != ""`):
- `kubernetes_namespace.consul` + bootstrap ACL token secret + CA cert secret
- `helm_release.consul` — chart version 1.9.2 (default)
- Config: TLS enabled, HTTPS only, external servers (Consul VM IPs), port 8501/8503
- Server/client disabled (dataplane mode — only connect-inject + sidecar proxies)
- Connect inject: enabled (explicit opt-in via pod annotation)
- Sync catalog: K8s→Consul, **excludes mcp-agents namespace** (uses connect-inject instead; without exclusion, sync-catalog registers duplicate services → connect-init fails)

### 3.7 Module: mcp-agents-k8s (`tf/modules/mcp-agents-k8s/`)

**Purpose**: MCP AI agent Kubernetes deployments (3 services with Consul sidecars).

**Files**: `namespace.tf`, `rbac.tf`, `deployment.tf`, `service.tf`, `consul.tf`, `vault-agent-config.tf`, `variables.tf`, `outputs.tf`

**Three deployments** (all gated on `var.gke_cluster_ready`):

1. **mcp-agent** — CLI + ttyd web terminal
   - Init container: vault-agent (exit-after-auth)
   - Main container: Python CLI on port 7681
   - Consul annotation: `connect-service-upstreams = "mcp-data-server:20000,mcp-compute-server:20001"`
   - vault-agent renders: settings.yaml (SSE URLs), capabilities.yaml, LLM API keys
   - Service: LoadBalancer (port 80 → 7681)

2. **mcp-data-server** — GCS + BigQuery MCP server
   - Init container: vault-agent (exit-after-auth)
   - Main container: Python SSE server on port 8080 (`MCP_TRANSPORT=sse`)
   - vault-agent renders: GCP access token
   - Service: ClusterIP (port 8080)

3. **mcp-compute-server** — GCE MCP server
   - Same pattern as data-server
   - Service: ClusterIP (port 8080)

**vault-agent ConfigMaps** (3 separate, in `vault-agent-config.tf`):
- Agent config: templates for settings.yaml, capabilities.yaml, anthropic-key, openai-key, .ready sentinel
- Data-server config: template for GCP access token
- Compute-server config: template for GCP access token

**Consul intentions** (`consul.tf`):
- `mcp-agent → mcp-data-server`: allow
- `mcp-agent → mcp-compute-server`: allow
- Default: deny

**PodDisruptionBudget**: min_available=1 for mcp-agent and each mcp-server

### 3.8 Scenario: consul-mcp-gke (`tf/scenarios/consul-mcp-gke/`)

**Purpose**: Wires all 7 modules together with phased apply and explicit dependencies.

**Files**: `versions.tf`, `locals.tf`, `variables.tf`, `network.tf`, `hcp-vault.tf`, `vault-pki.tf`, `vault-config.tf`, `consul.tf`, `gke.tf`, `mcp-agents.tf`, `artifact-registry.tf`, `outputs.tf`

**Provider configuration** (`versions.tf`):
- Terraform >= 1.9.0
- Providers: google (~5.0), hcp (~0.94), vault (~4.0), kubernetes (~2.0), helm (~2.0), consul (~2.0)
- Vault provider: uses HCP admin token
- Kubernetes/Helm providers: use `data.google_client_config.default.access_token` + cluster endpoint from `data.google_container_cluster.main` (gated on `gke_cluster_ready`)
- Consul provider: uses first Consul server internal IP + Vault CA + bootstrap token

**Naming** (`locals.tf`):
```
name_prefix = "{random_pet}-{datacenter}"    # e.g., "happy-panda-dc1"
short_prefix = "{random_pet}"
sa_prefix = trimsuffix(substr(short_prefix, 0, 14), "-")  # GCP SA ID ≤ 30 chars
common_labels = {project, environment, managed_by, scenario, datacenter}
```

**Phase gating**:
- `gke_cluster_ready = false` → `module.mcp_agents` count=0, `data.google_container_cluster` count=0
- Set to `true` in tfvars after GKE cluster exists (automated by `task gke:ensure-ready`)
- `gke_endpoint = ""` → Consul Helm count=0, Vault K8s auth count=0

**Dependency order (enforced by Terraform targets in Taskfile)**:
```
Phase 1a: network, hcp_vault, SAs
Phase 1b: vault_pki, vault_config
Phase 1c: consul (VMs)
Phase 2a: gke (cluster only, no K8s resources)
Phase 2b: gke (Consul Helm + K8s resources after kubeconfig + phase gate)
Phase 3:  vault K8s auth, mcp_agents
Phase 4:  full apply (reconcile)
```

**Scenario-level resources** (not in modules):
- `google_service_account.consul_server` — Consul VM identity (bound to Vault GCP auth)
- `google_service_account.vault_gcp_verifier` + key — Vault GCP auth credentials
- `kubernetes_service_account.vault_reviewer` + CRB + Secret — Vault K8s auth TokenReview
- `google_artifact_registry_repository.mcp` — Docker image repo

---

## 4. Python Application

### 4.1 pyproject.toml

```toml
[project]
name = "vault-mcp-agents"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "anthropic>=0.40.0,<1.0",
    "openai>=1.0.0,<3.0",
    "mcp>=1.6.0,<2.0",
    "hvac>=2.1.0,<3.0",
    "google-cloud-storage>=2.0.0,<3.0",
    "google-cloud-bigquery>=3.0.0,<4.0",
    "google-cloud-compute>=1.14.0,<2.0",
    "google-auth>=2.0.0,<3.0",
    "pyyaml>=6.0,<7.0",
    "click>=8.0,<9.0",
    "rich>=13.0,<14.0",
    "starlette>=0.27.0,<1.0",
    "uvicorn>=0.24.0,<1.0",
    "httpx-sse>=0.4.0,<1.0",
    "sqlglot>=25.0.0,<27.0",
]

[project.scripts]
vault-mcp-agents = "vault_mcp_agents.main:cli"
```

### 4.2 main.py — CLI Entry Point

Click command with two required options:
- `--config` (Path, must exist) → path to settings.yaml
- `--policies` (Path, must exist) → path to capabilities.yaml

Calls `asyncio.run(run_agent_session(config, policies))`. Catches `KeyboardInterrupt` for clean exit.

### 4.3 config.py — Configuration Loading

Dataclass-based configuration with YAML loader:

**Dataclasses**:
- `VaultConfig` — address, namespace, auth_method, gcp_secrets_mount, agent_approle_mount
- `GcpConfig` — project_id, region
- `LlmConfig` — provider (anthropic/openai), model, temperature
- `AgentDef` — description, mcp_server (reference key), gcp_impersonated_account (Vault roleset name)
- `McpServerDef` — `url` (required) — the local Envoy upstream listener URL (e.g. `http://localhost:20000/sse`). Loader rejects empty `url`.
- `Settings` — vault, gcp, llm, agents (dict), mcp_servers (dict)
- `AgentRolePolicy` — allowed_tools (list), max_gcp_token_ttl
- `RolePolicy` — vault_policy, agents (dict of AgentRolePolicy)
- `Policies` — roles (dict of RolePolicy)

**Functions**:
- `load_settings(path: Path) -> Settings` — yaml.safe_load → map to nested dataclasses
- `load_policies(path: Path) -> Policies` — yaml.safe_load → map to nested dataclasses

### 4.4 vault_client.py — Vault Integration

Class `VaultClient` wrapping `hvac.Client`:

- `__init__(address, namespace="")` → creates hvac.Client
- `login_userpass(username, password) -> dict` → hvac auth, stores token, returns auth dict
- `token -> Optional[str]` — property returning current token
- `get_policies() -> list[str]` — token lookup, extract policies
- `determine_role(policies) -> Optional[str]` — checks for "operator-policy", "analyst-policy", "viewer-policy" in order
- `generate_gcp_token(gcp_mount, roleset) -> Optional[str]` — reads `{mount}/token/{roleset}`, returns OAuth2 token string. Retries up to 3 times with exponential backoff (`_MAX_RETRIES=3`, `_RETRY_BACKOFF_BASE=1.0s`). Returns None after all attempts fail.

### 4.5 agent.py — Session Orchestrator

Main function: `async def run_agent_session(config: Path, policies: Path) -> None`

**Flow**:
1. Load settings + policies from YAML
2. `_prompt_login(vault)` → Rich console prompts for username/password
3. `vault.login_userpass()` → get policies, display to user
4. `vault.determine_role(policies)` → operator/analyst/viewer (exit if unrecognized)
5. `_select_agent(settings, role, policies)` → numbered menu of available agents for role
6. Look up `AgentRolePolicy.allowed_tools` for selected agent+role
7. `_connect()` — asynccontextmanager: `sse_client(mcp_server_def.url, timeout=30)` against the local Envoy upstream listener. There is no stdio fallback; the agent must run in a pod (or any host) with a Consul dataplane sidecar bound to that port.
8. `ClientSession(read, write)` → `session.initialize()`
9. Select REPL based on `settings.llm.provider`:
    - `_run_anthropic_repl(session, allowed_tools, model, temperature, api_key)`
    - `_run_openai_repl(session, allowed_tools, model, temperature, api_key)`

**LLM REPL loop** (both providers follow same pattern):
1. Fetch tools via `session.list_tools()`, filter to `allowed_tools`
2. Build provider-specific tool schema
3. Loop: Rich prompt for user input → API call → check for tool_use/tool_calls
4. If tool call: `session.call_tool(name, arguments)` → append result → continue API loop
5. If text response: print to console, back to user input
6. Special commands: "exit", "quit" to break

### 4.6 data_server.py — GCS + BigQuery MCP Server

`mcp.server.Server` instance with `@server.list_tools()` and `@server.call_tool()` handlers.

**Transport detection**:
```python
if __name__ == "__main__":
    transport = os.environ.get("MCP_TRANSPORT", "stdio")
    if transport == "sse":
        _run_sse()    # Starlette app on 0.0.0.0:{MCP_PORT}
    else:
        asyncio.run(_run_stdio())  # mcp stdio_server
```

**SSE mode**: Starlette app with routes:
- `GET /sse` → SSE connection endpoint
- `POST /messages/` → message handling (SseServerTransport)
- uvicorn server on `0.0.0.0:{MCP_PORT}` (default 8080)

**GCP credential flow**: `_storage_client()` / `_bq_client()` check `GOOGLE_ACCESS_TOKEN` env var → `OAuthCredentials(token=...)` if set, else ADC fallback.

**7 tools**:

| Tool | Args | Returns |
|---|---|---|
| `list_buckets` | (none) | JSON array of bucket names |
| `read_object` | bucket, object | Text content of object |
| `write_object` | bucket, object, content, [content_type] | "Written N bytes to gs://..." |
| `delete_object` | bucket, object | "Deleted gs://..." |
| `list_datasets` | (none) | JSON array of dataset IDs |
| `create_dataset` | dataset_id, [location] | "Dataset 'X' created in Y" |
| `query_bigquery` | query, [max_results=100] | JSON array of result rows (DML/DDL blocked via sqlglot AST) |

**Security**: `_validate_required()` validates args before GCP calls. `_is_read_only_query()` uses sqlglot AST parsing to block DML/DDL (immune to comment/string bypass). `maximum_bytes_billed` cost cap via `BQ_MAX_BYTES_BILLED` env var (default 1GB). All sync GCP calls wrapped in `asyncio.to_thread()`. Errors return `type(exc).__name__` only; details logged server-side.

### 4.7 compute_server.py — GCE MCP Server

Same SSE/stdio transport pattern as data_server.

**GCP credential flow**: `_instance_client()` checks `GOOGLE_ACCESS_TOKEN` → `compute_v1.InstancesClient(credentials=...)` or default.

**6 tools**:

| Tool | Args | Returns |
|---|---|---|
| `list_instances` | [zone] | JSON array of instance summaries |
| `get_instance` | instance, [zone] | JSON instance detail |
| `start_instance` | instance, [zone] | "Start operation submitted: ..." |
| `stop_instance` | instance, [zone] | "Stop operation submitted: ..." |
| `create_instance` | instance, [machine_type=e2-micro], [zone] | "Create operation submitted: ..." |
| `delete_instance` | instance, [zone] | "Delete operation submitted: ..." |

`create_instance` uses Debian 12 cloud image, default VPC network. Machine type validated against `ALLOWED_MACHINE_TYPES` whitelist (env var, default e2/n2 types). Returns GCP operation name (async).

**Security**: `_validate_required()` validates args before GCP calls. `ALLOWED_MACHINE_TYPES` whitelist blocks unauthorized instance types. All sync GCP calls wrapped in `asyncio.to_thread()`. Errors return `type(exc).__name__` only; details logged server-side.

Helper `_instance_summary(inst)` extracts: name, status, machine_type (short), zone (short), network_ip, creation_timestamp.

---

## 5. Configuration Files

### 5.1 config/settings.yaml (local dev default)

```yaml
vault:
  address: "http://127.0.0.1:8200"
  namespace: ""
  auth_method: "userpass"
  gcp_secrets_mount: "gcp"
  agent_approle_mount: "approle"

gcp:
  project_id: ""
  region: "us-central1"

llm:
  provider: "anthropic"
  model: "claude-sonnet-4-6"
  temperature: 0

agents:
  data_agent:
    description: "Handles GCS and BigQuery operations"
    mcp_server: "data_server"
    gcp_impersonated_account: "data-agent-gcp"
  compute_agent:
    description: "Handles GCE instance and infrastructure operations"
    mcp_server: "compute_server"
    gcp_impersonated_account: "compute-agent-gcp"

# Each url is the Consul Connect upstream listener on the agent pod's Envoy
# sidecar (declared via consul.hashicorp.com/connect-service-upstreams).
mcp_servers:
  data_server:
    url: "http://localhost:20000/sse"
  compute_server:
    url: "http://localhost:20001/sse"
```

There is no stdio/subprocess transport. In production this file is rendered by vault-agent from Vault KV (`secret/data/mcp-agents/config`); the bundled copy in `config/settings.yaml` is the same shape.

### 5.2 policies/capabilities.yaml

Three roles with per-agent tool access:

- **operator**: all 7 data tools + all 6 compute tools
- **analyst**: list_buckets, read_object, query_bigquery, list_datasets + list_instances, get_instance
- **viewer**: list_buckets, read_object, list_datasets + list_instances

All roles: `max_gcp_token_ttl: "5m"` (dual-layer TTL enforcement with Vault's 300s lease).

Each role maps to a `vault_policy` name: operator-policy, analyst-policy, viewer-policy.

---

## 6. Docker

### 6.1 Dockerfile (multi-stage)

**Stage 1 — builder**:
- Base: `python:3.11-slim`
- Install: build-essential, git
- Create venv at `/opt/venv`, install package

**Stage 2 — runtime**:
- Base: `python:3.11-slim`
- Install: ca-certificates, curl, unzip, tini, bash
- Download Vault binary (ARG `VAULT_VERSION=1.19.0`) → `/usr/local/bin/vault` (SHA256 verified)
- Download ttyd binary (ARG `TTYD_VERSION=1.7.7`) → `/usr/local/bin/ttyd` (SHA256 verified)
- User: mcpuser (UID 1000)
- Copy venv from builder
- Copy app source to `/app`
- Volumes: `/vault/secrets`, `/tmp`
- Env: `MCP_CONFIG_PATH`, `MCP_POLICIES_PATH`, `MCP_TRANSPORT=stdio`, `MCP_PORT=8080`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1`
- Expose: 7681
- Entrypoint: `tini --`
- CMD: `/app/docker/entrypoint.sh`

### 6.2 entrypoint.sh

Four-step startup:

1. **Wait for vault-agent** — polls `/vault/secrets/.ready` up to `VAULT_AGENT_TIMEOUT` seconds (default 120). If timeout: exits with error unless `ALLOW_BUNDLED_FALLBACK=true`, in which case falls back to bundled `/app/config/` files.
2. **Source LLM API keys** — reads raw key values from `/vault/secrets/anthropic-key` and `/vault/secrets/openai-key` via `cat` (not `source`).
3. **Validate config** — exits with error if config file not found.
4. **Start ttyd** — wraps `vault-mcp-agents` CLI on port 7681 (`--writable --once`). Optional `TTYD_CREDENTIAL` for basic auth. Env vars exported to child shell (avoids interpolating secrets into `bash -c` strings — shell injection prevention). Displays ASCII login banner before starting CLI.

---

## 7. Packer Image

### 7.1 gcp-almalinux-consul-server.pkr.hcl

- Plugin: `github.com/hashicorp/googlecompute >= 1.1.0`
- Source: AlmaLinux 8, e2-standard-2, 30GB pd-ssd
- Variables: `consul_version` (default 1.20.2), `vault_version` (default 1.19.0)
- Output image family: `almalinux-consul-server-vault`

Build steps:
1. Upload `consul-server.hcl` and `vault-agent-consul.hcl.tmpl` to `/tmp/`
2. Run `provision-vault-agent.sh` (install vault binary, systemd services, first-boot renderer)
3. Run `provision-consul.sh` (install consul binary, systemd services, user/group setup)
4. Validation script (check versions, systemd enabled)

### 7.2 consul-server.hcl

Consul server config baked into image:
- `server = true`, `client_addr = "0.0.0.0"`, `bind_addr = "{{ GetInterfaceIP \"eth0\" }}"`
- TLS: enabled (verify_incoming=false for clients, verify_outgoing=true, verify_server_hostname=true for RPC)
- ACL: enabled, default_policy=deny, enable_token_persistence=true
- Connect: enabled (CA provider config rendered separately by vault-agent)
- UI: enabled
- Performance: raft_multiplier=1
- Telemetry: prometheus_retention_time=60s

### 7.3 vault-agent-consul.hcl.tmpl

Template with `__PLACEHOLDER__` values replaced at first boot from GCP instance metadata.

**Auto-auth**: GCP IAM method → writes Vault token to `/opt/vault/vault-token`

**Templates rendered**:
1. `/etc/consul.d/connect-ca.hcl` — Consul Connect CA provider config pointing to Vault PKI (root + intermediate paths, token from file, leaf_cert_ttl=72h)
2. `/etc/consul.d/tls-certs.hcl` — uses `pkiCert` to issue server TLS cert (CN=server.{dc}.consul), writes cert/key/CA-chain to `/etc/consul.d/tls/` with `chgrp consul` post-render + `systemctl reload consul`
3. `/tmp/vault-agent-ready` — sentinel file signaling all configs rendered

### 7.4 provision-vault-agent.sh

- Downloads Vault binary, installs to `/usr/local/bin`, sets `cap_ipc_lock=+ep`
- Creates vault user (system, home=/opt/vault)
- Creates `/usr/local/bin/render-vault-agent-config.sh` — reads GCP instance metadata, `sed` replaces __PLACEHOLDERS__ in template
- Creates systemd services:
  - `vault-agent-config.service` (Type=oneshot, runs renderer)
  - `vault-agent.service` (runs vault agent, Requires vault-agent-config, Before consul)

### 7.5 provision-consul.sh

- Downloads Consul binary, installs to `/usr/local/bin`, sets `cap_ipc_lock=+ep`
- Creates consul user (system, home=/opt/consul)
- Group membership: `usermod -aG consul vault` + `usermod -aG vault consul` (bidirectional access for rendered TLS files)
- Directory permissions: `/etc/consul.d/` mode 0770, `/etc/consul.d/tls/` owned consul:vault mode 2770 (setgid)
- Creates systemd service: `consul.service` (Requires vault-agent, After vault-agent)

---

## 8. Taskfile.yml — Orchestration

Task-based orchestration replacing Makefile. Key tasks:

| Task | Purpose |
|---|---|
| `all` | Full deployment: preflight → token → backend → packer → phase1 → ACL bootstrap → phase2 → phase3 → phase4 → summary |
| `destroy` | tf:destroy + packer:destroy |
| `preflight` | Check CLI tools + GCP auth + Docker credential helper |
| `phase1:apply` | Network + HCP Vault + PKI + Vault Config + Consul VMs |
| `phase2:apply` | GKE cluster + Consul Helm |
| `phase3:apply` | Vault K8s auth → Docker build+push → MCP agent K8s resources → URL |
| `phase4:apply` | Full reconcile apply |
| `tf:fix-k8s-identity` | Workaround for K8s provider identity bug |
| `consul:bootstrap-acl` | Bootstrap ACLs, update tfvars + K8s secret |
| `gke:ensure-ready` | Get kubeconfig, set gke_cluster_ready=true, update private endpoint |
| `docker:build` | Multi-platform Docker build (linux/amd64) |
| `docker:push` | Auth to Artifact Registry + push |

**Helper**: `tfvars:set` (internal) — idempotent key=value writer for terraform.tfvars, used by multiple tasks.

---

## 9. Architecture Diagrams

`docs/diagrams/generate_diagrams.py` generates PNG diagrams at 300 DPI with dark background (#0D1117):

1. **overall-architecture.png** — Full stack from HCP Vault → GKE → users
2. **vault-pki-chain.png** — Root CA → Intermediate CA → leaf certs with TTLs
3. **architecture-gke.png** — GKE-focused architecture view
4. **deployment-sequence.png** — 6 deployment phases with task commands

Color palette: Vault purple, HCP teal, Consul pink, GCP blue, GKE green, MCP orange, User gold.

---

## 10. Key Design Decisions

1. **External Consul control plane** (VMs, not in GKE) — decouples mesh control plane from compute; Consul servers can manage multiple clusters; dataplane mode minimizes GKE resource usage.

2. **Vault PKI as Consul Connect CA** (not Consul built-in) — centralized certificate management, CRL/OCSP revocation, consistent PKI hierarchy across services, audit logging.

3. **Three separate deployments** (not one pod) — each MCP server is its own service in the Consul catalog so `ServiceIntentions` can authorise the agent→server hop, the data and compute servers can be scaled and rotated independently, and a compromised server pod cannot read the others' Vault-rendered GCP tokens.

4. **RBAC at LLM level** (not MCP API level) — simpler implementation, MCP servers are generic. Tool list filtered before passing to LLM. Trust model: Consul intentions prevent unauthorized service-to-service access; within an authorized connection, tool filtering is advisory (enforced by LLM prompt, not API).

5. **GCP SA impersonation** (not direct credentials) — Vault generates short-lived OAuth2 tokens via impersonation chain. No long-lived GCP credentials in pods. 5-minute TTL limits blast radius.

6. **Native GKE resources** (not community module) — the cluster is Consul-dataplane-opinionated (Calico, pod density, per-namespace Workload Identity). ~200 lines, fully readable. Migration cost exceeds benefit.

7. **Phase-gated Terraform** — GKE cluster must exist before K8s/Helm resources can be created. `gke_cluster_ready` boolean gates `data.google_container_cluster` lookup and `module.mcp_agents` count.

---

## 11. Critical Implementation Notes

- **HCP Vault runs on AWS** — no GCP VPC peering. All traffic via public HTTPS endpoint.
- **Admin token expires in 6h** — re-apply from HCP module to regenerate.
- **Consul provider needs IAP tunnel** from outside VPC — `task consul:tunnel` on localhost:18501.
- **SA IDs capped at 30 chars** — `sa_prefix = trimsuffix(substr(short_prefix, 0, 14), "-")`.
- **Never set `audience` on Vault K8s roles** — projected SA tokens use cluster-specific audience.
- **`vault write auth/kubernetes/config` replaces ALL fields** — never omit kubernetes_ca_cert or issuer.
- **Terraform can't detect sensitive value changes** — use `terraform taint` after manual updates.
- **Consul sync-catalog excludes mcp-agents namespace** — prevents duplicate service registration.
- **vault-agent writes as vault:vault 0640** — Consul reads via group membership + post-render chgrp.
- **GKE lifecycle ignores** node_version, initial_node_count, min_master_version (auto-managed by release channel).
- **Consul VM lifecycle ignores** boot_disk image (prevents recreation on Packer rebuild).

## 12. Required GCP APIs

Enable before deploying: compute, container, iam, storage, artifactregistry, cloudresourcemanager, servicenetworking.

## 13. Testing & CI/CD

The repo currently has **no automated tests or CI/CD pipeline**. Verification is manual:
- `terraform validate` + `terraform fmt -recursive` for Terraform
- `task preflight` for environment readiness
- `task consul:bootstrap-acl` for Consul ACL health (idempotent — validates token if already bootstrapped)
- `kubectl get pods -n mcp-agents` for deployment status
- Manual agent session test via ttyd web terminal