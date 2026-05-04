#!/usr/bin/env bash
# scripts/smoke-test.sh — end-to-end functional smoke test of a deployed scenario.
#
# Designed to be safe to run against a deployment in any phase: every check is
# independent, prints PASS / FAIL / SKIP, and the script returns a non-zero exit
# code only if at least one FAIL was recorded (SKIPs are tolerated).
#
# Usage: scripts/smoke-test.sh <tf-dir> <gcp-project> <gcp-region>
set -uo pipefail

TF_DIR="${1:?usage: $0 <tf-dir> <gcp-project> <gcp-region>}"
GCP_PROJECT="${2:?missing gcp-project}"
GCP_REGION="${3:?missing gcp-region}"
TFVARS="$TF_DIR/terraform.tfvars"

# ---- output helpers ---------------------------------------------------------

PASS=0; FAIL=0; SKIP=0
RESULTS=()
CURRENT_SECTION="General"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$REPO_ROOT/.runs"
TS="$(date +%Y%m%d-%H%M%S)"
MD_FILE="$RUNS_DIR/smoke-$TS.md"
mkdir -p "$RUNS_DIR"

green()  { printf '\033[32m%s\033[0m' "$1"; }
red()    { printf '\033[31m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }

record() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) PASS=$((PASS+1)); printf '  [%s] %-45s %s\n' "$(green PASS)"   "$name" "$detail" ;;
    FAIL) FAIL=$((FAIL+1)); printf '  [%s] %-45s %s\n' "$(red   FAIL)"   "$name" "$detail" ;;
    SKIP) SKIP=$((SKIP+1)); printf '  [%s] %-45s %s\n' "$(yellow SKIP)"  "$name" "$detail" ;;
  esac
  RESULTS+=("$status|$CURRENT_SECTION|$name|$detail")
}

section() { CURRENT_SECTION="$1"; printf '\n=== %s ===\n' "$1"; }

md_escape() { printf '%s' "$1" | sed 's/|/\\|/g'; }

# ---- helpers ----------------------------------------------------------------

tfvar() { grep -E "^$1[ =]" "$TFVARS" 2>/dev/null | awk -F'"' '{print $2}'; }

tfout() { (cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null) || true; }

hcp_token() {
  "$(dirname "$0")/hcp-token.sh" "$TFVARS" 2>/dev/null
}

# Fetch HCP caller identity (org + project IDs).
hcp_ids() {
  local token="$1"
  curl -fsS -H "Authorization: Bearer $token" \
    "https://api.cloud.hashicorp.com/iam/2019-12-10/caller-identity" 2>/dev/null
}

# ---- pre-flight values ------------------------------------------------------

AR_REPO="$(tfvar artifact_registry_repo)"; AR_REPO="${AR_REPO:-vault-mcp}"
GKE_CLUSTER="$(tfvar gke_cluster_name)"
HVN_PREFIX="$(tfout name_prefix | sed 's/-dc1$//')"
VAULT_URL="$(tfout vault_public_url)"

echo "Smoke test for scenario at $TF_DIR"
echo "  project=$GCP_PROJECT region=$GCP_REGION"
echo "  AR repo=$AR_REPO  GKE cluster=${GKE_CLUSTER:-<unset>}"
echo "  Vault URL=${VAULT_URL:-<unset>}"

# ---- 1. Terraform state -----------------------------------------------------

section "Terraform state"

if (cd "$TF_DIR" && terraform output >/dev/null 2>&1); then
  record PASS "terraform output readable"
else
  record FAIL "terraform output readable" "run 'task tf:init' first"
fi

# ---- 2. Artifact Registry ---------------------------------------------------

section "Artifact Registry"

if gcloud artifacts repositories describe "$AR_REPO" \
    --project "$GCP_PROJECT" --location "$GCP_REGION" >/dev/null 2>&1; then
  record PASS "AR repo '$AR_REPO' exists"

  IMG_PATH="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT/$AR_REPO/vault-mcp-agents"
  if gcloud artifacts docker images list "$IMG_PATH" \
      --project "$GCP_PROJECT" --include-tags --limit=1 --format="value(tags)" 2>/dev/null \
      | grep -q .; then
    record PASS "image vault-mcp-agents present"
  else
    record FAIL "image vault-mcp-agents present" "run 'task docker:build && task docker:push'"
  fi
else
  record FAIL "AR repo '$AR_REPO' exists" "run 'task tf:apply' to create"
fi

# ---- 3. HCP HVN + Vault cluster ---------------------------------------------

section "HCP Vault"

if TOKEN="$(hcp_token)" && [ -n "$TOKEN" ]; then
  IDENT="$(hcp_ids "$TOKEN")"
  ORG_ID="$(echo "$IDENT" | python3 -c "import sys,json;print(json.load(sys.stdin)['principal']['service']['organization_id'])" 2>/dev/null || true)"
  PROJ_ID="$(echo "$IDENT" | python3 -c "import sys,json;print(json.load(sys.stdin)['principal']['service']['project_id'])" 2>/dev/null || true)"

  if [ -n "$HVN_PREFIX" ] && [ -n "$ORG_ID" ] && [ -n "$PROJ_ID" ]; then
    HVN_ID="${HVN_PREFIX}-hvn"
    HVN_STATE="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "https://api.cloud.hashicorp.com/network/2020-09-07/organizations/$ORG_ID/projects/$PROJ_ID/networks/$HVN_ID" \
      2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('network',{}).get('state','MISSING'))" 2>/dev/null || echo "MISSING")"
    if [ "$HVN_STATE" = "STABLE" ]; then
      record PASS "HVN '$HVN_ID' STABLE"
    else
      record FAIL "HVN '$HVN_ID' STABLE" "state=$HVN_STATE"
    fi

    CLUSTER_ID="${HVN_PREFIX}-vault"
    CLUSTER_STATE="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "https://api.cloud.hashicorp.com/vault/2020-11-25/organizations/$ORG_ID/projects/$PROJ_ID/clusters/$CLUSTER_ID" \
      2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('cluster',{}).get('state','MISSING'))" 2>/dev/null || echo "MISSING")"
    if [ "$CLUSTER_STATE" = "RUNNING" ]; then
      record PASS "Vault cluster '$CLUSTER_ID' RUNNING"
    else
      record FAIL "Vault cluster '$CLUSTER_ID' RUNNING" "state=$CLUSTER_STATE"
    fi
  else
    record SKIP "HVN/cluster status" "no name_prefix output yet (Phase 1 not run?)"
  fi
else
  record SKIP "HCP API auth" "TF_VAR_hcp_client_secret not set"
fi

# ---- 4. Vault HTTP reachable + initialised + unsealed -----------------------

if [ -n "$VAULT_URL" ]; then
  # Force 200 on standby/perf-standby/uninit so curl -f doesn't reject healthy-but-non-active states.
  HQ="?standbyok=true&perfstandbyok=true&drsecondaryok=true&uninitcode=200"
  HEALTH="$(curl -fsS --max-time 10 "$VAULT_URL/v1/sys/health$HQ" 2>/dev/null || true)"
  if [ -n "$HEALTH" ]; then
    INIT="$(echo "$HEALTH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('initialized'))" 2>/dev/null || echo "?")"
    SEAL="$(echo "$HEALTH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sealed'))" 2>/dev/null || echo "?")"
    if [ "$INIT" = "True" ] && [ "$SEAL" = "False" ]; then
      record PASS "Vault initialized + unsealed"
    else
      record FAIL "Vault initialized + unsealed" "initialized=$INIT sealed=$SEAL"
    fi
  else
    record FAIL "Vault HTTP reachable" "no response from $VAULT_URL"
  fi
else
  record SKIP "Vault HTTP" "no vault_public_url output"
fi

# ---- 5. Vault auth + secret engines (requires VAULT_TOKEN) ------------------

if [ -n "${VAULT_TOKEN:-}" ] && [ -n "$VAULT_URL" ]; then
  MOUNTS="$(curl -fsS --max-time 10 -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_URL/v1/sys/mounts" 2>/dev/null || true)"
  AUTHS="$(curl -fsS --max-time 10 -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_URL/v1/sys/auth" 2>/dev/null || true)"

  for engine in pki-consul connect-intermediate gcp secret; do
    if echo "$MOUNTS" | grep -q "\"$engine/\""; then
      record PASS "Vault mount: $engine"
    else
      record FAIL "Vault mount: $engine" "missing"
    fi
  done

  for auth in userpass kubernetes; do
    if echo "$AUTHS" | grep -q "\"$auth/\""; then
      record PASS "Vault auth: $auth"
    else
      record FAIL "Vault auth: $auth" "missing"
    fi
  done

  for kv in mcp-agents/config mcp-agents/policies consul/acl-token; do
    if curl -fsS --max-time 10 -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_URL/v1/secret/data/$kv" >/dev/null 2>&1; then
      record PASS "Vault KV: secret/$kv"
    else
      record FAIL "Vault KV: secret/$kv" "404 or auth denied"
    fi
  done
else
  record SKIP "Vault auth-required checks" "set VAULT_TOKEN to include"
fi

# ---- 6. Consul VM + agent ---------------------------------------------------

section "Consul"

VM_NAME="$(gcloud compute instances list --project "$GCP_PROJECT" \
  --filter="name~consul-server AND status=RUNNING" \
  --format="value(name)" 2>/dev/null | head -1)"

if [ -n "$VM_NAME" ]; then
  record PASS "Consul VM running" "$VM_NAME"

  CONSUL_TOKEN="$(tfvar consul_bootstrap_token)"
  if [ -n "$CONSUL_TOKEN" ]; then
    MEMBERS="$(./scripts/consul-ssh.sh "$TF_DIR" "$GCP_PROJECT" "$GCP_REGION" \
      "CONSUL_HTTP_TOKEN=$CONSUL_TOKEN consul members 2>&1" 2>/dev/null || true)"
    if echo "$MEMBERS" | grep -qE 'alive\s+server'; then
      record PASS "consul members reports alive server"
    elif echo "$MEMBERS" | grep -q "ACL system must be bootstrapped"; then
      record SKIP "consul members reports alive server" "ACLs not bootstrapped yet (Phase 2 not run)"
    else
      record FAIL "consul members reports alive server" "see 'task consul:status'"
    fi
  else
    record SKIP "consul members" "no consul_bootstrap_token in tfvars"
  fi
else
  record FAIL "Consul VM running" "no instance matching name~consul-server"
fi

# ---- 7. GKE + Kubernetes ---------------------------------------------------

section "GKE / Kubernetes"

if [ -n "$GKE_CLUSTER" ]; then
  GKE_STATUS="$(gcloud container clusters describe "$GKE_CLUSTER" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format="value(status)" 2>/dev/null || echo "MISSING")"
  if [ "$GKE_STATUS" = "RUNNING" ]; then
    record PASS "GKE cluster '$GKE_CLUSTER' RUNNING"

    if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
      record PASS "Kubernetes API reachable"

      READY_NODES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True' || echo 0)"
      if [ "$READY_NODES" -gt 0 ]; then
        record PASS "Kubernetes nodes Ready" "$READY_NODES node(s)"
      else
        record FAIL "Kubernetes nodes Ready" "0 ready"
      fi
    else
      MY_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)"
      AUTH_CIDRS="$(gcloud container clusters describe "$GKE_CLUSTER" --region "$GCP_REGION" --project "$GCP_PROJECT" \
        --format='value(masterAuthorizedNetworksConfig.cidrBlocks)' 2>/dev/null || true)"
      if [ -n "$MY_IP" ] && [ -n "$AUTH_CIDRS" ] && ! echo "$AUTH_CIDRS" | grep -q "$MY_IP"; then
        record FAIL "Kubernetes API reachable" "current IP $MY_IP not in masterAuthorizedNetworks — update gke_authorized_cidrs in tfvars + tf:apply"
      else
        record FAIL "Kubernetes API reachable" "kubectl cluster-info failed — run 'task gke:ensure-ready'"
      fi
    fi
  else
    record FAIL "GKE cluster '$GKE_CLUSTER' RUNNING" "status=$GKE_STATUS"
  fi
else
  record SKIP "GKE cluster" "gke_cluster_name not set"
fi

# ---- 8. Consul Helm (Phase 2) -----------------------------------------------

section "Consul Helm (Phase 2)"

if kubectl get ns consul >/dev/null 2>&1; then
  if kubectl get deployment consul-connect-injector -n consul >/dev/null 2>&1; then
    READY="$(kubectl get deployment consul-connect-injector -n consul -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [ -z "$READY" ] && READY=0
    if [ "$READY" -gt 0 ]; then
      record PASS "consul-connect-injector ready" "$READY replica(s)"
    else
      record FAIL "consul-connect-injector ready" "0 ready"
    fi
  else
    record FAIL "consul-connect-injector deployment" "not found"
  fi

  if kubectl get statefulset -n consul -l app=consul-server >/dev/null 2>&1; then
    record PASS "consul-server statefulset present"
  else
    # client-only deploy is also valid for dataplane mode — don't fail.
    record SKIP "consul-server statefulset" "dataplane mode (server is on GCE)"
  fi
else
  record SKIP "Consul Helm" "namespace 'consul' not found (Phase 2 not run)"
fi

# ---- 9. MCP agents (Phase 3) ------------------------------------------------

section "MCP agents (Phase 3)"

if kubectl get ns mcp-agents >/dev/null 2>&1; then
  for d in mcp-agent mcp-data-server mcp-compute-server; do
    READY="$(kubectl get deployment "$d" -n mcp-agents -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [ -z "$READY" ] && READY=0
    if [ "$READY" -gt 0 ]; then
      record PASS "$d ready" "$READY replica(s)"
    else
      record FAIL "$d ready" "0 ready"
    fi
  done

  IP="$(kubectl get svc mcp-agent -n mcp-agents -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -n "$IP" ]; then
    record PASS "mcp-agent LB has IP" "$IP"
    if curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$IP/" 2>/dev/null \
        | grep -qE '^(200|401)$'; then
      record PASS "mcp-agent web terminal reachable"
    else
      record FAIL "mcp-agent web terminal reachable" "no 200/401 from http://$IP/"
    fi
  else
    record FAIL "mcp-agent LB has IP" "still pending"
  fi
else
  record SKIP "MCP agents" "namespace 'mcp-agents' not found (Phase 3 not run)"
fi

# ---- summary ----------------------------------------------------------------

section "Summary"
TOTAL=$((PASS+FAIL+SKIP))
printf '  %s passed, %s failed, %s skipped (of %d checks)\n' \
  "$(green "$PASS")" "$(red "$FAIL")" "$(yellow "$SKIP")" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for r in "${RESULTS[@]}"; do
    case "$r" in FAIL\|*)
      IFS='|' read -r _ _ name detail <<<"$r"
      printf '  • %s — %s\n' "$name" "${detail:-no detail}"
    ;; esac
  done
fi

# ---- markdown report --------------------------------------------------------

OVERALL="PASS"
[ "$FAIL" -gt 0 ] && OVERALL="FAIL"

{
  printf '# Smoke test report — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '- **Result:** %s\n' "$OVERALL"
  printf '- **Scenario:** `%s`\n' "$TF_DIR"
  printf '- **Project / region:** `%s` / `%s`\n' "$GCP_PROJECT" "$GCP_REGION"
  printf '- **AR repo:** `%s`\n' "$AR_REPO"
  printf '- **GKE cluster:** `%s`\n' "${GKE_CLUSTER:-<unset>}"
  printf '- **Vault URL:** `%s`\n' "${VAULT_URL:-<unset>}"
  printf '- **Totals:** %d passed, %d failed, %d skipped (of %d)\n\n' "$PASS" "$FAIL" "$SKIP" "$TOTAL"

  printf '## Results\n\n'
  printf '| Section | Status | Check | Detail |\n'
  printf '|---|---|---|---|\n'
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status sec name detail <<<"$r"
    printf '| %s | %s | %s | %s |\n' \
      "$(md_escape "$sec")" "$status" "$(md_escape "$name")" "$(md_escape "${detail:-}")"
  done

  if [ "$FAIL" -gt 0 ]; then
    printf '\n## Failures\n\n'
    for r in "${RESULTS[@]}"; do
      case "$r" in FAIL\|*)
        IFS='|' read -r _ sec name detail <<<"$r"
        printf -- '- **[%s]** %s — %s\n' "$sec" "$name" "${detail:-no detail}"
      ;; esac
    done
  fi
} > "$MD_FILE"

ln -sfn "smoke-$TS.md" "$RUNS_DIR/smoke-latest.md"
echo ""
echo "Report written to $MD_FILE"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
