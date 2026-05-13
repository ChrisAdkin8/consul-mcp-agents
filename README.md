# consul-mcp-agents

**GKE + Consul service mesh + HCP Vault Dedicated + MCP AI agents on GCP.**

An end-to-end reference stack for running LLM agents that touch real cloud APIs, with **zero long-lived credentials**, **mTLS on every hop**, and **5-minute GCP tokens**. HCP Vault Dedicated is both the certificate authority for the Consul Connect mesh and a dynamic broker for GCP OAuth2 tokens; the Consul control plane runs on GCE VMs while the dataplane (Envoy sidecars) runs in GKE; the AI agents and their MCP tool servers are separate pods that talk to each other only through the mesh.

### What you get

- **An AI agent web terminal** (ttyd) where authenticated users drive an LLM with role-scoped tools against GCS, BigQuery, and Compute Engine.
- **Three trust boundaries between user prompt and a GCP API call**: Vault userpass (who you are) → Consul intentions (which services may speak) → `capabilities.yaml` (which tools the LLM sees).
- **No secrets in images, manifests, or environment variables** — every credential is rendered by vault-agent into tmpfs and rotated under TTL.
- **A turn-key deployment**: ~25–35 min from `task all` to a working web terminal, with phase-gated Terraform that handles HCP Vault → Vault PKI → Consul VMs → GKE → MCP pods in the right order.

### Who it's for

Platform engineers and security architects evaluating how to give LLM agents real cloud capabilities without handing out static API keys; HashiCorp customers wanting an opinionated reference for HCP Vault + Consul + GKE; teams who want a working artefact to fork rather than a slideware diagram.

### Table of contents

- [Quick Start](#quick-start) — prerequisites, configure, deploy, log in
- [Architecture](#architecture) — component stack, certificate chain, what lives in Vault
- [Deployment Phases](#deployment-phases) — why the apply is split, in what order
- [Operations](#operations) — Taskfile commands per component
- [Directory Structure](#directory-structure)
- [Security at a Glance](#security-at-a-glance)
- [Troubleshooting](#troubleshooting)
- **Deep dives** — [`docs/architecture.md`](docs/architecture.md) (per-pod Vault flow, secret lifetimes) · [`docs/mesh.md`](docs/mesh.md) (Vault PKI as Consul Connect CA, VM TLS) · [`docs/blog-securing-agentic-platforms.md`](docs/blog-securing-agentic-platforms.md) (essay on the OWASP-LLM mapping)

---

## Quick Start

### Prerequisites

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

You'll also need:

- A **GCP project** with billing enabled, `roles/owner` (or a custom role covering `compute.*`, `container.*`, `iam.*`, `artifactregistry.*`), and the Compute Engine, GKE, IAM, Artifact Registry, and Cloud NAT APIs enabled.
- An **HCP account** ([portal.cloud.hashicorp.com](https://portal.cloud.hashicorp.com)) with a service principal (Contributor role) — note the Client ID and Client Secret for `terraform.tfvars`.
- An **Anthropic or OpenAI API key**.

### 1 · Clone

```bash
git clone https://github.com/ChrisAdkin8/consul-mcp-agents.git
cd consul-mcp-agents
```

### 2 · Configure `terraform.tfvars`

```bash
cp tf/scenarios/consul-mcp-gke/terraform.tfvars.example \
   tf/scenarios/consul-mcp-gke/terraform.tfvars
```

Edit the three required blocks:

```hcl
# ---- GCP ----
gcp_project_id = "your-gcp-project-id"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"
environment    = "dev"

# ---- HCP ----  (service principal: HCP portal → Access control → Service principals)
hcp_client_id     = "your-hcp-client-id"
hcp_client_secret = "your-hcp-client-secret"
hcp_hvn_cidr      = "172.25.16.0/20"   # must not overlap GCP subnets
hcp_vault_tier    = "plus_small"

# ---- LLM ----
llm_provider     = "anthropic"
llm_model        = "claude-sonnet-4-6"
anthropic_api_key = "sk-ant-..."
```

### 3 · Authenticate with GCP

All four commands are required; `task preflight` will verify them.

```bash
gcloud auth login                                              # gcloud CLI + kubectl + Taskfile
gcloud auth application-default login                          # Terraform google provider + Packer
gcloud config set project <your-project-id>                    # default --project
gcloud auth configure-docker us-central1-docker.pkg.dev        # docker push to Artifact Registry
```

### 4 · Deploy

```bash
task tf:backend:create   # creates the GCS state bucket
task preflight           # verifies tools, credentials, tfvars
task all                 # full deployment, ~25–35 min
```

Phase timing: Phase 1 (HCP Vault + PKI + Consul VMs) ~10 min · Phase 2 (GKE + Consul Helm) ~15 min · Phase 3 (MCP agents) ~2 min.

### 5 · Log in

```bash
task mcp:url
# Open http://<IP>/ — log in with:
#   alice / alice-pass    (operator, all tools)
#   bob   / bob-pass      (analyst, read + query)
#   carol / carol-pass    (viewer, read-only)
```

---

## Architecture

![Overall Architecture](docs/diagrams/overall-architecture.png)

### Component stack

| Layer | Component | Purpose |
|-------|-----------|---------|
| Identity & Secrets | HCP Vault Dedicated | PKI CA, GCP dynamic creds, config store, human + pod auth |
| Service mesh CA | Vault PKI (Root + Intermediate) | Issues mTLS leaf certs for Consul Connect |
| Control plane | Consul on GCE VMs | External Consul control plane for the GKE dataplane |
| Compute | GKE (regional cluster) | Runs MCP agent pods + Envoy sidecars |
| Credentials | Vault GCP Secrets Engine | 5-minute OAuth2 tokens via service-account impersonation |
| Agent AI | vault-mcp-agents (Python) | Anthropic/OpenAI SDK adapter + MCP tool servers (GCS, BigQuery, GCE) |
| User access | ttyd web terminal | Browser-based access to the `vault-mcp-agents` CLI inside the pod |

### Certificate chain

```
HCP Vault PKI
  └── Root CA  (connect-root)          10-year validity, never exported
        └── Intermediate CA  (connect-intermediate)  5-year validity
              ├── Consul Connect leaf certs          72h, auto-rotated
              └── Consul server TLS certs            72h, auto-rotated
```

### Credential flow (5-minute GCP tokens)

```
User → Vault userpass login → Session token
  → Agent selects role + agent, opens MCP connection over the Consul mesh
  → (mTLS hop through Envoy sidecars; ServiceIntention authorises)
  → MCP server pod calls tool handler
  → Reads /vault/secrets/gcp-token (refreshed by its vault-agent sidecar)
  → Token came from: Vault GCP secrets engine → GCP generateAccessToken API
  → OAuth2 token (TTL 5 min, enforced server-side by Vault lease)
  → GCS / BigQuery / GCE API call
```

The agent process never fetches GCP credentials itself. Each MCP server pod owns its own Vault role and its own GCP impersonation chain — the agent's compromise blast radius is "issue MCP RPCs the intentions allow," not "mint GCP tokens."

### What lives in Vault

| Secret path | Content | Consumer |
|---|---|---|
| `connect-root/` | PKI Root CA | Consul TLS trust anchor |
| `connect-intermediate/` | PKI Intermediate CA | Issues leaf certs to Consul |
| `auth/gcp` | GCP IAM auth method | Consul server VM vault-agent |
| `auth/kubernetes` | K8s auth method | GKE pod vault-agent |
| `auth/userpass` | Human user accounts | MCP CLI users |
| `gcp/impersonated-account/data-agent-gcp` | GCP OAuth2 tokens (5-min) | `mcp-data-server` |
| `gcp/impersonated-account/compute-agent-gcp` | GCP OAuth2 tokens (5-min) | `mcp-compute-server` |
| `secret/mcp-agents/config` | `settings.yaml` content | MCP pods via vault-agent |
| `secret/mcp-agents/policies` | `capabilities.yaml` content | MCP pods via vault-agent |
| `secret/mcp-agents/llm-keys` | Anthropic/OpenAI API keys | `mcp-agent` pod via vault-agent |
| `secret/consul/acl-token` | Consul bootstrap ACL token | Written post-bootstrap |

**Want more depth?** [`docs/architecture.md`](docs/architecture.md) walks through each pod's vault-agent flow (init container, sidecar, sequence diagrams, secret lifetimes). [`docs/mesh.md`](docs/mesh.md) covers Vault PKI as the Consul Connect CA, the GCP-IAM auth path on the VMs, and TLS renewal without SIGHUP.

---

## Deployment Phases

The deployment is split into phases because Terraform can't observe runtime values (GKE endpoint, Vault token, Consul ACL bootstrap) until earlier resources exist.

```
Phase 1a   Network            VPC, subnets, Cloud NAT
Phase 1b   HCP Vault          HVN + Vault cluster + VPC peering
Phase 1c   Vault PKI          Root CA + Intermediate CA + GCP auth roles
Phase 1d   Vault Config       KV secrets, GCP engine, userpass, K8s auth skeleton
Phase 1e   Consul VMs         Boot with vault-agent → GCP IAM auth → certs from Vault PKI

Phase 2    GKE + Consul Helm  Cluster + Consul dataplane Helm (TLS via Vault PKI CA cert)

Post-GKE   K8s auth wiring    `vault:configure-k8s-auth` fills in GKE endpoint + CA

Phase 3    Docker image       MCP agent image build + push to Artifact Registry
Phase 4    K8s workloads      MCP agent + server Deployments, Services, Intentions
```

Why split: **HCP Vault** must exist before Vault PKI/config can be applied; **Vault PKI** must exist before Consul VMs boot (vault-agent fetches certs); **Consul VMs** must be running before GKE Helm can connect to external servers; **GKE endpoint** is only known after GKE apply (Vault K8s auth needs it); **Vault K8s auth** must be configured before MCP pods can authenticate.

---

## Operations

```bash
# Vault
task vault:status                # cluster health
task vault:login:operator        # log in as alice
task vault:configure-k8s-auth    # re-wire K8s auth after cluster changes

# Consul
task consul:status               # member list (via IAP SSH)
task consul:refresh-tls          # re-issue TLS cert + sync consul-ca-cert K8s secret
task consul:bootstrap-acl        # bootstrap ACLs (idempotent)

# GKE
task gke:ensure-ready            # kubeconfig + phase gate + private endpoint tfvar
task gke:nodes                   # list nodes

# MCP agents
task mcp:status                  # pod and service status
task mcp:url                     # web terminal URL
task mcp:logs                    # tail pod logs
task mcp:exec                    # shell into a pod
task mcp:restart                 # rolling restart

# Docker
task docker:build                # build with git SHA tag
task docker:push                 # push to Artifact Registry

# HCP
task hcp:list-orphans            # surface leaked random_pet HVNs from prior runs

# Diagrams
task diagrams:generate           # regenerate architecture PNGs
```

Full list: `task --list`.

---

## Directory Structure

```
consul-mcp-agents/
├── Taskfile.yml                # Orchestration (task --list)
├── README.md
├── CLAUDE.md                   # Working notes / operational rules for contributors
│
├── docker/                     # Multi-stage Python + vault-agent + ttyd image
├── packer/                     # Consul server VM image (AlmaLinux + vault-agent baked in)
├── src/vault_mcp_agents/       # Agent CLI + MCP servers (data, compute)
├── config/                     # Bundled settings.yaml + capabilities.yaml defaults
│
├── docs/
│   ├── architecture.md         # Per-pod Vault flow, secret lifetimes
│   ├── mesh.md                 # Vault PKI as Consul Connect CA, VM TLS
│   ├── blog-securing-agentic-platforms.md
│   └── diagrams/               # Architecture PNGs + D2 sources
│
└── tf/
    ├── modules/
    │   ├── hcp-vault/          # HVN + Vault Dedicated + VPC peering
    │   ├── vault-pki-consul/   # Root + Intermediate CA, GCP auth, policies
    │   ├── vault-config/       # KV, GCP engine, userpass, K8s auth
    │   ├── network/            # VPC + subnets + Cloud NAT + firewalls
    │   ├── consul/             # Consul server VMs (GCE)
    │   ├── gke-consul-dataplane/  # GKE cluster + Consul Helm
    │   └── mcp-agents-k8s/     # K8s ns, SA, vault-agent ConfigMaps, Deployments
    └── scenarios/
        └── consul-mcp-gke/     # Root module wiring everything together
```

---

## Security at a Glance

| What | How |
|------|-----|
| Consul VM → Vault auth | GCP IAM auth (VM SA identity JWT) |
| GKE pod → Vault auth | Kubernetes auth (pod SA JWT) |
| Vault → GCP APIs | Service account key in Vault state (rotatable) |
| LLM API keys | Vault KV → vault-agent → tmpfs file (never in K8s manifests) |
| GCP credentials | 5-minute OAuth2 via impersonation (server-side lease + client-side TTL) |
| Consul mTLS | Vault PKI leaf certs (72h, auto-rotated by vault-agent) |
| Agent ↔ server | Consul Connect mTLS + ServiceIntentions (no plaintext) |
| User passwords | Vault userpass (managed in Terraform, rotate out-of-band) |

Four-layer defence-in-depth on every tool call (Vault policy → Consul intention → `capabilities.yaml` → GCP IAM). See [`docs/architecture.md`](docs/architecture.md#defence-in-depth-for-tool-access) for what each layer enforces.

---

## Troubleshooting

### Consul server VMs not joining cluster

```bash
gcloud compute ssh <consul-vm-name> --project <project> --zone <zone> --tunnel-through-iap

sudo systemctl status vault-agent
sudo journalctl -u vault-agent -f       # auth + render activity
ls -la /etc/consul.d/                   # vault-agent should have written tls/, connect-ca.hcl
sudo systemctl status consul
sudo journalctl -u consul -f
```

### MCP pods stuck in `Init:0/2` — vault-agent `permission denied`

**Symptom:** pods in `mcp-agents` show `Init:0/2`; `vault-agent-init` logs show repeated `403 permission denied` on `auth/kubernetes/login`.

**Cause:** the `vault-reviewer` ClusterRoleBinding is missing. Vault needs it to call the K8s TokenReview API. The vault-reviewer SA + CRB + token Secret are top-level resources in `vault-config.tf` — not inside `module.vault_config` — so a targeted apply of just the module skips them.

```bash
kubectl get clusterrolebinding vault-reviewer    # expect: not NotFound

task vault:configure-k8s-auth                    # re-applies the vault-reviewer resources
kubectl rollout restart deployment/mcp-agent deployment/mcp-data-server deployment/mcp-compute-server -n mcp-agents
```

Other causes of pod-to-Vault auth failure:

```bash
kubectl logs -n mcp-agents <pod-name> -c vault-agent-init
vault read auth/kubernetes/config
vault read auth/kubernetes/role/mcp-server
```

### Terraform warns about undeclared variables `gke_cluster_endpoint` / `gke_cluster_ca_certificate`

The scenario auto-discovers both via `data.google_container_cluster.main` when `gke_cluster_ready = true`. Remove the manual lines from `terraform.tfvars` — they aren't in `terraform.tfvars.example` and shouldn't be set by hand.

### ttyd web terminal not loading

```bash
kubectl get pods -n mcp-agents -o wide
kubectl logs -n mcp-agents deployment/mcp-agents -c ttyd
kubectl get svc mcp-agents-lb -n mcp-agents
```

For deeper operational failure modes (TLS expired pods crash-looping, Vault K8s auth JWT empty after taint, HCP HVN quota exhausted, `errored.tfstate` recovery), see the **Critical operational rules** section in [`CLAUDE.md`](CLAUDE.md).
