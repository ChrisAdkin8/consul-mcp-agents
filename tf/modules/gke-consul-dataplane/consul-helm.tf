# =============================================================================
# GKE Consul Dataplane Module — consul-helm.tf
#
# Deploys the Consul Helm chart in dataplane mode with:
#   • TLS enabled (CA cert from HCP Vault PKI)
#   • External servers pointing at Consul VMs
#   • Connect injection enabled (automatic sidecar proxies)
#   • Sync catalog enabled (K8s services → Consul catalog)
#   • Ingress gateway enabled (external traffic into the mesh)
#
# Key difference from the base gke-consul-dataplane scenario:
#   global.tls.enabled = true  (was false)
#   CA cert sourced from Vault PKI module output, stored as K8s secret
#
# These resources are gated on var.gke_endpoint != "" so that phase2 can
# first create the GKE cluster (no endpoint known), and then after updating
# terraform.tfvars with the endpoint, apply the kubernetes/helm resources.
# =============================================================================

locals {
  # Only deploy kubernetes/helm resources once the cluster endpoint is known.
  deploy_k8s = var.gke_endpoint != ""
}

# ---------------------------------------------------------------------------
# Kubernetes namespace and CA secret
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "consul" {
  count = local.deploy_k8s ? 1 : 0

  metadata {
    name = "consul"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [google_container_cluster.main, google_container_node_pool.main]
}

# CA cert chain as a K8s secret — Consul Helm reads this for TLS trust.
# Terraform seeds the initial value from Vault PKI; consul:refresh-tls updates
# it with the live CA chain from the Consul VM before each Helm deploy.
# ignore_changes prevents Terraform from reverting the Taskfile's update.
resource "kubernetes_secret" "consul_ca_cert" {
  count = local.deploy_k8s ? 1 : 0

  metadata {
    name      = "consul-ca-cert"
    namespace = kubernetes_namespace.consul[0].metadata[0].name
  }

  data = {
    "tls.crt" = var.vault_ca_chain_pem
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }
}

# Consul bootstrap ACL token as a K8s secret
resource "kubernetes_secret" "consul_bootstrap_token" {
  count = local.deploy_k8s ? 1 : 0

  metadata {
    name      = "consul-bootstrap-acl-token"
    namespace = kubernetes_namespace.consul[0].metadata[0].name
  }

  data = {
    token = var.consul_bootstrap_token
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Consul Helm release
# ---------------------------------------------------------------------------
resource "helm_release" "consul" {
  count = local.deploy_k8s ? 1 : 0

  name             = "consul"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "consul"
  version          = var.helm_chart_version
  namespace        = kubernetes_namespace.consul[0].metadata[0].name
  create_namespace = false
  wait             = true
  wait_for_jobs    = true # ensure consul-server-acl-init Job completes before Terraform returns
  timeout          = 900  # 15 min — acl-init needs time to reach external Consul server over TLS

  # ---- Global settings ----
  set {
    name  = "global.name"
    value = "consul"
  }

  set {
    name  = "global.datacenter"
    value = var.datacenter
  }

  set {
    name  = "global.logLevel"
    value = "info"
  }

  # ---- TLS: enabled with Vault PKI CA ----
  set {
    name  = "global.tls.enabled"
    value = "true"
  }

  set {
    name  = "global.tls.httpsOnly"
    value = "true"
  }

  set {
    name  = "global.tls.caCert.secretName"
    value = kubernetes_secret.consul_ca_cert[0].metadata[0].name
  }

  set {
    name  = "global.tls.caCert.secretKey"
    value = "tls.crt"
  }

  # ---- ACL management ----
  set {
    name  = "global.acls.manageSystemACLs"
    value = "true"
  }

  set {
    name  = "global.acls.bootstrapToken.secretName"
    value = kubernetes_secret.consul_bootstrap_token[0].metadata[0].name
  }

  set {
    name  = "global.acls.bootstrapToken.secretKey"
    value = "token"
  }

  # ---- External Consul servers (control plane on VMs) ----
  set {
    name  = "externalServers.enabled"
    value = "true"
  }

  set {
    name  = "externalServers.hosts[0]"
    value = var.consul_internal_address
  }

  set {
    name  = "externalServers.httpsPort"
    value = "8501" # TLS port (8500 when TLS disabled)
  }

  set {
    name  = "externalServers.grpcPort"
    value = "8503" # TLS gRPC port (8502 is non-TLS)
  }

  set {
    name  = "externalServers.tlsServerName"
    value = "server.${var.datacenter}.consul"
  }

  set {
    name  = "externalServers.k8sAuthMethodHost"
    value = "https://${var.gke_private_endpoint != "" ? var.gke_private_endpoint : var.gke_endpoint}"
  }

  set {
    name  = "externalServers.k8sAuthMethodName"
    value = "consul-k8s-component-auth-method"
  }

  # ---- No Consul server/client pods in GKE (dataplane mode) ----
  set {
    name  = "server.enabled"
    value = "false"
  }

  set {
    name  = "client.enabled"
    value = "false"
  }

  # ---- Connect inject (automatic sidecar proxy injection) ----
  set {
    name  = "connectInject.enabled"
    value = tostring(var.enable_service_mesh)
  }

  set {
    name  = "connectInject.transparentProxy.defaultEnabled"
    value = "true"
  }

  set {
    name  = "connectInject.default"
    value = "false" # Require explicit opt-in via annotation
  }

  # ---- Sync catalog: K8s services → Consul ----
  set {
    name  = "syncCatalog.enabled"
    value = "true"
  }

  set {
    name  = "syncCatalog.toConsul"
    value = "true"
  }

  set {
    name  = "syncCatalog.toK8S"
    value = "false"
  }

  set {
    name  = "syncCatalog.k8sPrefix"
    value = "k8s-"
  }

  # Exclude mcp-agents namespace — those services use connect-inject, not sync-catalog.
  # Without this, sync-catalog registers the LB service as a second Consul service on
  # the same pod, causing connect-init to fail with "multiple Consul services registered".
  set {
    name  = "syncCatalog.k8sDenyNamespaces[0]"
    value = "mcp-agents"
  }

  # ---- Ingress gateway ----
  set {
    name  = "ingressGateways.enabled"
    value = tostring(var.enable_ingress_gateway)
  }

  set {
    name  = "ingressGateways.defaults.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "ingressGateways.defaults.service.ports[0].port"
    value = "80"
  }

  set {
    name  = "ingressGateways.defaults.service.ports[1].port"
    value = "443"
  }

  # Restrict ingress gateway LB to allowed CIDRs (matches mcp-agent LB pattern).
  # Helm `set` requires escaped indices for list-of-string values.
  dynamic "set" {
    for_each = var.enable_ingress_gateway ? toset(var.ingress_gateway_source_ranges) : []
    content {
      name  = "ingressGateways.defaults.service.loadBalancerSourceRanges[${index(var.ingress_gateway_source_ranges, set.value)}]"
      value = set.value
    }
  }

  depends_on = [
    kubernetes_secret.consul_ca_cert,
    kubernetes_secret.consul_bootstrap_token,
  ]
}
