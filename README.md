# consul-mcp-agents

**GKE + Consul Dataplane + HCP Vault Dedicated + MCP AI Agents**

A production-grade infrastructure stack that deploys Vault-secured AI agents with MCP (Model Context Protocol) servers onto GKE, using HCP Vault Dedicated as both a Certificate Authority for Consul and a dynamic credential broker for GCP APIs.

---

## Architecture

![Overall Architecture](docs/diagrams/overall-architecture.png)

### Component Stack

| Layer | Component | Purpose |
|-------|-----------|---------|
| Identity & Secrets | HCP Vault Dedicated | PKI CA, GCP dynamic creds, config store, human + pod auth |
| Service Mesh CA | Vault PKI (Root + Intermediate) | Issues mTLS leaf certs for Consul Connect |
| Control Plane | Consul VMs (external) | External Consul control plane for GKE dataplane mode |
| Compute | GKE (regional cluster) | Runs MCP agent pods; Consul dataplane in sidecar proxies |
| Credentials | Vault GCP Secrets Engine | 5-minute OAuth2 tokens via service account impersonation |
| Agent AI | vault-mcp-agents (Python) | LangChain agents + MCP servers (GCS, BigQuery, GCE tools) |
| User Access | ttyd web terminal | Browser-based CLI access; existing prompt/cli.py unchanged |

### Certificate Chain

```
HCP Vault PKI
  └── Root CA  (connect-root)          10-year validity, never exported
        └── Intermediate CA  (connect-intermediate)  5-year validity
              └── Consul Connect leaf certs          72h, auto-rotated
              └── Consul server TLS certs            72h, auto-rotated
```

### Credential Flow (5-Minute GCP Tokens)

```
User → Vault userpass login → Session token
  → LangChain agent → MCP server → _get_gcp_token()
  → hvac.secrets.gcp.generate_impersonated_account_oauth2_access_token()
  → Vault GCP engine → GCP generateAccessToken API
  → OAuth2 token (TTL: 5 min, enforced at two layers)
  → GCS / BigQuery / GCE API call
```

### What Lives in Vault

| Secret Path | Content | Consumer |
|---|---|---|
| `connect-root/` | PKI Root CA | Consul TLS trust anchor |
| `connect-intermediate/` | PKI Intermediate CA | Issues leaf certs to Consul |
| `auth/gcp` | GCP IAM auth method | Consul server VM vault-agent |
| `auth/kubernetes` | K8s auth method | GKE pod vault-agent |
| `auth/userpass` | Human user accounts | MCP CLI users |
| `gcp/impersonated-account/data-agent-gcp` | GCP OAuth2 tokens (5-min) | data_agent MCP server |
| `gcp/impersonated-account/compute-agent-gcp` | GCP OAuth2 tokens (5-min) | compute_agent MCP server |
| `secret/mcp-agents/config` | settings.yaml content | MCP pods via vault-agent |
| `secret/mcp-agents/policies` | capabilities.yaml content | MCP pods via vault-agent |
| `secret/mcp-agents/llm-keys` | Anthropic/OpenAI API keys | MCP pods via vault-agent |
| `secret/consul/acl-token` | Consul bootstrap ACL token | Written post-bootstrap |

---

## How Pods Retrieve Secrets from Vault

Secret delivery is split across two phases: **pod startup** (vault-agent init container) and **runtime** (Python hvac calls per user session).

### Phase 1 — vault-agent init container

Every `mcp-agents` pod runs a `vault-agent-init` container before the main container starts. It authenticates to Vault once, renders all static secrets into a shared memory volume, then exits.

```mermaid
sequenceDiagram
    autonumber
    participant K8s as Kubernetes API
    participant VA  as vault-agent-init
    participant V   as HCP Vault
    participant Vol as /vault/secrets<br/>(memory emptyDir)

    VA->>K8s: Present projected SA token<br/>(audience=vault, TTL 2h)
    K8s->>V: TokenReview (vault-reviewer JWT)
    V-->>VA: Vault token (TTL 1h, policy: mcp-server-policy)

    VA->>V: Read secret/data/mcp-agents/llm-keys
    V-->>VA: Anthropic + OpenAI API keys
    VA->>Vol: Render → /vault/secrets/anthropic-key
    VA->>Vol: Render → /vault/secrets/openai-key

    VA->>V: Read secret/data/mcp-agents/config
    V-->>VA: settings.yaml variables
    VA->>Vol: Render → /vault/secrets/settings.yaml

    VA->>V: Read secret/data/mcp-agents/policies
    V-->>VA: capabilities.yaml variables
    VA->>Vol: Render → /vault/secrets/capabilities.yaml

    VA->>Vol: Write /vault/secrets/.ready (sentinel)
    Note over VA: exits (exit-after-auth=true)
```

**Authentication details:**

| Field | Value |
|---|---|
| Auth method | Kubernetes (`auth/kubernetes`) |
| JWT source | Projected SA token at `/var/run/secrets/vault/token` |
| SA | `mcp-server` in namespace `mcp-agents` |
| Vault role | `mcp-server` — bound to that SA + namespace |
| Token reviewer | `vault-reviewer` SA in `kube-system` (managed by Terraform) |

**Secrets rendered at startup:**

| Vault path | Rendered file | Contents |
|---|---|---|
| `secret/data/mcp-agents/llm-keys` | `/vault/secrets/anthropic-key`<br/>`/vault/secrets/openai-key` | Raw API key values |
| `secret/data/mcp-agents/config` | `/vault/secrets/settings.yaml` | Vault addr, GCP project, agent definitions, transport config |
| `secret/data/mcp-agents/policies` | `/vault/secrets/capabilities.yaml` | Role → tool allowlists, max GCP token TTL |

All files land in an `emptyDir` volume with `medium: Memory` — they never touch node disk.

### Phase 2 — main container startup

`docker/entrypoint.sh` waits for the `.ready` sentinel (max 120 s), then:

```bash
# Read rendered files and export as env vars for the ttyd subprocess
ANTHROPIC_API_KEY=$(cat /vault/secrets/anthropic-key)
OPENAI_API_KEY=$(cat /vault/secrets/openai-key)
export ANTHROPIC_API_KEY OPENAI_API_KEY
exec ttyd ... vault-mcp-agents ...
```

The application reads `settings.yaml` and `capabilities.yaml` from the same volume at import time.

### Phase 3 — runtime, per user session

When a user logs in through the web terminal:

```mermaid
sequenceDiagram
    autonumber
    participant U   as User (browser)
    participant App as vault-mcp-agents CLI
    participant V   as HCP Vault
    participant MCP as MCP Server subprocess
    participant GCP as GCP API

    U->>App: vault-mcp-agents --user alice --password …
    App->>V: auth/userpass login (alice)
    V-->>App: Session token (policy: operator-policy)

    App->>V: gcp/impersonated-account/data-agent-gcp/token
    V->>GCP: generateAccessToken (SA impersonation)
    GCP-->>V: OAuth2 token (TTL 5 min)
    V-->>App: OAuth2 token

    App->>MCP: spawn subprocess<br/>env: GOOGLE_ACCESS_TOKEN=<token>
    MCP->>GCP: storage.Client / bigquery.Client / compute_v1.InstancesClient<br/>(credentials from GOOGLE_ACCESS_TOKEN)
    GCP-->>MCP: API response
    MCP-->>App: Tool result
    App-->>U: Agent response
```

A fresh GCP token is fetched from Vault on every agent invocation. Tokens expire after 5 minutes server-side (Vault GCP engine TTL) and are also capped client-side in `capabilities.yaml`.

### Secret lifetime summary

| Secret | Fetched | TTL | Stored in |
|---|---|---|---|
| Kubernetes projected SA JWT | Pod creation | 2 h | `/var/run/secrets/vault/` (K8s managed) |
| Vault pod token | Init container | 1 h | `/home/vault/.vault-token` (emptyDir) |
| LLM API keys | Init container | Until pod restart | `/vault/secrets/` (memory emptyDir) |
| `settings.yaml`, `capabilities.yaml` | Init container | Until pod restart | `/vault/secrets/` (memory emptyDir) |
| Vault user session token | User login | Policy TTL | Python process memory |
| GCP OAuth2 token | Per agent spawn | 5 min | `GOOGLE_ACCESS_TOKEN` env var in subprocess |

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.9.0 | [terraform.io](https://terraform.io) |
| Packer | >= 1.10.0 | [packer.io](https://packer.io) |
| Task | >= 3.0 | `brew install go-task` |
| gcloud | latest | [cloud.google.com/sdk](https://cloud.google.com/sdk) |
| kubectl | >= 1.28 | `gcloud components install kubectl` |
| docker | >= 24.0 | [docs.docker.com](https://docs.docker.com) |
| vault CLI | >= 1.17 | [vaultproject.io](https://vaultproject.io) |
| jq | >= 1.6 | `brew install jq` |

### GCP Requirements

- A GCP project with billing enabled
- `roles/owner` or custom role with: `compute.*`, `container.*`, `iam.*`, `artifactregistry.*`
- APIs enabled: Compute Engine, GKE, IAM, Artifact Registry, Cloud NAT

### HCP Requirements

- HCP account at [portal.cloud.hashicorp.com](https://portal.cloud.hashicorp.com)
- A **service principal** with `Contributor` role (create in HCP → Access control → Service principals)
- Note the **Client ID** and **Client Secret** — used in terraform.tfvars

---

## Quick Start

### Step 1: Clone the consul-mcp-agents repo

```bash
git clone consul-mcp-agents.git
cd consul-mcp-agents
```

### Step 2: Configure the terraform.tfvars file

```bash
cp tf/scenarios/consul-mcp-gke/terraform.tfvars.example \
   tf/scenarios/consul-mcp-gke/terraform.tfvars

# Edit terraform.tfvars

#
# 1. Replace the "your-gcp-project-id" placeholder with your actual GCP project id:
#

# ---- GCP ----
gcp_project_id = "your-gcp-project-id"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"
environment    = "dev"

#
# 2. Replace the "your-hcp-client-id" and "your-hcp-client-secret" with your own HCP credentials
#

# ---- HCP ----
# Create a service principal in HCP portal → Access control → Service principals
hcp_client_id     = "your-hcp-client-id"
hcp_client_secret = "your-hcp-client-secret"
hcp_hvn_cidr      = "172.25.16.0/20"  # Must not overlap GCP subnets
hcp_vault_tier    = "plus_small"

#
# 3. Enter your LLM provider API key here in place of the placeholder
#

# ---- LLM ----
llm_provider     = "anthropic"
llm_model        = "claude-sonnet-4-6"
anthropic_api_key = "sk-ant-..."  # Your Anthropic API key
```

### Step 3: Authenticate with GCP

All four commands below are required before deploying. `task preflight` will verify them.

```bash
# 1. User login — authenticates gcloud CLI, kubectl, and Taskfile tasks
gcloud auth login

# 2. Application Default Credentials — used by Terraform's google provider
gcloud auth application-default login

# 3. Set the active project (must match gcp_project_id in terraform.tfvars)
gcloud config set project <your-project-id>

# 4. Docker credential helper — allows pushing images to Artifact Registry
gcloud auth configure-docker <region>-docker.pkg.dev   # e.g. us-central1-docker.pkg.dev
```

| Command | Used by |
|---------|---------|
| `gcloud auth login` | `gcloud`, `kubectl`, Taskfile tasks (`consul:*`, `gke:*`, `packer:build`) |
| `gcloud auth application-default login` | Terraform GCP provider, Packer, any Google client library |
| `gcloud config set project` | Default `--project` for all `gcloud` commands |
| `gcloud auth configure-docker` | `task docker:push` — authenticates Docker to Artifact Registry |

### Step 4: Create state bucket and set backend

```bash
task tf:backend:create
# Update tf/scenarios/consul-mcp-gke/versions.tf with the bucket name
```

### Step 5: Check preflight

```bash
task preflight
```

### Step 6: Run full deployment

```bash
task all
# This takes ~25-35 minutes total:
#   Phase 1 (Vault + PKI + Consul):  ~10 min
#   Phase 2 (GKE + Consul Helm):     ~15 min
#   Phase 3 (MCP agents):             ~2 min
```

### Step 7: Access the web terminal

```bash
task mcp:url
# Navigate to http://<IP>/ in your browser
# Log in with: alice/alice-pass (operator), bob/bob-pass (analyst), carol/carol-pass (viewer)
```
---

## Deployment Phases

The deployment is split into phases to handle Terraform dependency ordering:

```
Phase 1a: Network (VPC, subnets, Cloud NAT)
Phase 1b: HCP Vault (HVN + Vault cluster + VPC peering)
Phase 1c: Vault PKI (Root CA + Intermediate CA + GCP auth roles)
Phase 1d: Vault Config (KV secrets, GCP engine, userpass, K8s auth skeleton)
Phase 1e: Consul VMs (boot with vault-agent → GCP IAM auth → certs from Vault PKI)

Phase 2:  GKE Cluster + Consul dataplane Helm (TLS via Vault PKI CA cert)

Post-GKE: vault:configure-k8s-auth (fills in GKE endpoint + CA in Vault K8s auth)

Phase 3:  MCP agent Docker image build + push to Artifact Registry
Phase 4:  MCP agent Kubernetes Deployment + Services
```

### Why phases?

- **HCP Vault** must exist before Vault PKI/config can be applied
- **Vault PKI** must exist before Consul VMs boot (vault-agent fetches certs)
- **Consul VMs** must be running before GKE Helm chart can connect to external servers
- **GKE cluster endpoint** is only known after GKE apply — needed for Vault K8s auth config
- **Vault K8s auth** must be configured before MCP pods can authenticate to Vault

---

## Individual Component Operations

### Vault

```bash
task vault:status              # Check Vault cluster health
task vault:login:operator      # Log in as alice (operator role)
task vault:configure-k8s-auth  # Re-configure K8s auth (after cluster changes)
```

### Consul

```bash
task consul:status             # Check Consul member list (via IAP SSH)
```

### GKE

```bash
task gke:ensure-ready          # Get kubeconfig + set phase gate + update private endpoint
task gke:nodes                 # List cluster nodes
```

### MCP Agents

```bash
task mcp:status                # Pod and service status
task mcp:url                   # Get web terminal URL
task mcp:logs                  # Tail pod logs
task mcp:exec                  # Shell into a pod
task mcp:restart               # Rolling restart
```

### Docker

```bash
task docker:build              # Build image with current git SHA tag
task docker:push               # Push to Artifact Registry
task docker:run-local          # Run locally against local Vault dev server
```

### Diagrams

```bash
task diagrams:generate         # Generate/regenerate architecture PNGs
```

---

## Directory Structure

```
consul-mcp-agents/
├── Taskfile.yml                    # Orchestration (run: task --list for all tasks)
├── README.md                       # This file
├── .gitignore
│
├── docker/
│   ├── Dockerfile                  # Multi-stage Python + vault + ttyd image
│   └── entrypoint.sh               # Container entrypoint (waits for vault-agent, starts ttyd)
│
├── packer/
│   ├── gcp-almalinux-consul-server.pkr.hcl   # Consul server VM image (with vault-agent)
│   ├── configs/
│   │   ├── consul-server.hcl                  # Base Consul server config (baked in)
│   │   └── vault-agent-consul.hcl.tmpl        # vault-agent config template (rendered at boot)
│   └── scripts/
│       ├── provision-consul.sh                 # Install Consul binary + systemd
│       └── provision-vault-agent.sh            # Install vault-agent binary + systemd
│
├── docs/
│   └── diagrams/
│       ├── generate_diagrams.py               # Matplotlib diagram generator
│       ├── overall-architecture.png
│       ├── vault-pki-chain.png
│       ├── credential-flow.png
│       └── deployment-sequence.png
│
└── tf/
    ├── modules/
    │   ├── hcp-vault/                # HCP HVN + Vault Dedicated + VPC peering
    │   ├── vault-pki-consul/         # Root CA + Intermediate CA + GCP auth + policies
    │   ├── vault-config/             # KV secrets + GCP engine + userpass + K8s auth
    │   ├── network/                  # VPC + subnets + Cloud NAT + firewalls
    │   ├── consul/                   # Consul server VMs (GCE instances)
    │   ├── gke-consul-dataplane/     # GKE cluster + Consul Helm (TLS-enabled)
    │   └── mcp-agents-k8s/           # K8s namespace + SA + vault-agent ConfigMap + Deployment + Services
    └── scenarios/
        └── consul-mcp-gke/            # Root module wiring all modules together
            ├── versions.tf           # Provider constraints + GCS backend
            ├── variables.tf
            ├── locals.tf
            ├── outputs.tf
            ├── network.tf
            ├── hcp-vault.tf
            ├── vault-pki.tf
            ├── vault-config.tf
            ├── consul.tf
            ├── gke.tf
            ├── mcp-agents.tf
            └── terraform.tfvars.example
```

---

## Security Design

### No long-lived credentials in images or manifests

| What | How |
|------|-----|
| Consul VM → Vault auth | GCP IAM auth (VM SA identity JWT) |
| GKE pod → Vault auth | Kubernetes auth (pod SA JWT) |
| Vault → GCP APIs | Service account key in Vault state (rotatable) |
| LLM API keys | Vault KV → vault-agent env injection → never in K8s manifests |
| GCP credentials | 5-minute OAuth2 via impersonation (two-layer TTL enforcement) |
| Consul TLS | Vault PKI leaf certs (72h, auto-rotated by vault-agent) |
| User passwords | Vault userpass (managed in Terraform, rotate out-of-band) |

### Defence-in-depth for tool access

1. **Vault policy layer** — vault-agent token only allows reading specific GCP impersonated-account paths
2. **Application policy layer** — `capabilities.yaml` maps (role, agent) → allowed tool names
3. **MCP server layer** — `_get_visible_tools()` filters the tool registry at startup
4. **GCP IAM layer** — each agent SA has only the permissions it needs (storage.admin, bigquery.admin, compute.admin)

---

## Troubleshooting

### Consul server VMs not joining cluster

```bash
# SSH to a Consul VM via IAP
gcloud compute ssh <consul-vm-name> --project <project> --zone <zone> --tunnel-through-iap

# Check vault-agent status
sudo systemctl status vault-agent
sudo journalctl -u vault-agent -f

# Check if vault-agent rendered configs
ls -la /etc/consul.d/
cat /etc/consul.d/connect-ca.hcl  # Should show Vault CA config

# Check Consul service
sudo systemctl status consul
sudo journalctl -u consul -f
```

### MCP pods stuck in `Init:0/2` — vault-agent `permission denied`

**Symptom:** All pods in `mcp-agents` namespace show `Init:0/2` status. The `vault-agent-init` container logs show repeated `403 permission denied` errors on `auth/kubernetes/login`.

**Cause:** The `vault-reviewer` ClusterRoleBinding is missing. This binding grants the `vault-reviewer` service account (in `kube-system`) the `system:auth-delegator` role, which Vault needs to call the Kubernetes TokenReview API. Without it, Vault cannot validate pod ServiceAccount JWTs.

The vault-reviewer SA, ClusterRoleBinding, and token Secret are top-level Terraform resources in `vault-config.tf` — not inside `module.vault_config`. A targeted apply of only `module.vault_config` will skip them.

**Fix:**

```bash
# Verify the CRB is missing
kubectl get clusterrolebinding vault-reviewer
# Error from server (NotFound): ...

# Re-run vault:configure-k8s-auth (now targets the vault-reviewer resources)
task vault:configure-k8s-auth

# Restart pods so init containers retry immediately
kubectl rollout restart deployment/mcp-agent deployment/mcp-data-server deployment/mcp-compute-server -n mcp-agents
```

### MCP pods not authenticating to Vault (other causes)

```bash
# Check init container logs
kubectl logs -n mcp-agents <pod-name> -c vault-agent-init

# Verify the K8s auth backend is configured
vault read auth/kubernetes/config

# Check Vault K8s auth role
vault read auth/kubernetes/role/mcp-server
```

### Terraform warns about undeclared variables `gke_cluster_endpoint` / `gke_cluster_ca_certificate`

```
Warning: Value for undeclared variable — "gke_cluster_endpoint"
Warning: Value for undeclared variable — "gke_cluster_ca_certificate"
```

These variables are not declared in the root module. The scenario auto-discovers the cluster endpoint and CA certificate from GCP via `data.google_container_cluster.main` when `gke_cluster_ready = true` — no manual values are needed.

**Fix**: Remove both lines from `terraform.tfvars`. They should not be set manually and are not present in `terraform.tfvars.example`.

### ttyd web terminal not loading

```bash
# Check all containers are running
kubectl get pods -n mcp-agents -o wide

# Check ttyd container logs
kubectl logs -n mcp-agents deployment/mcp-agents -c ttyd

# Check LoadBalancer IP
kubectl get svc mcp-agents-lb -n mcp-agents
```
