"""
generate_diagrams.py — Architecture diagrams for consul-mcp-agents

Four high-resolution PNGs at 300 DPI:
  1. overall-architecture.png
  2. vault-pki-chain.png
  3. credential-flow.png
  4. deployment-sequence.png
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
import os

# ── Palette ───────────────────────────────────────────────────────────────────
C = {
    "vault_purple":    "#6C4A99",
    "vault_purple_lt": "#B09FD0",
    "hcp_teal":        "#00A5A5",
    "hcp_teal_lt":     "#5CDBDB",
    "consul_pink":     "#CA2171",
    "consul_pink_lt":  "#F07DB8",
    "gcp_blue":        "#1A73E8",
    "gcp_blue_lt":     "#7CB3F5",
    "gke_green":       "#137333",
    "gke_green_lt":    "#57BB7C",
    "mcp_orange":      "#E65100",
    "mcp_orange_lt":   "#FFB07C",
    "user_gold":       "#F9AB00",
    "user_gold_lt":    "#FBDB6A",
    "bg_dark":         "#0D1117",
    "bg_card":         "#21262D",
    "text_white":      "#F0F6FC",
    "text_dim":        "#9BA5AF",
    "arrow_white":     "#E8EDF2",
}

DPI     = 300
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

plt.rcParams.update({
    "font.family":      "DejaVu Sans",
    "text.color":       C["text_white"],
    "axes.facecolor":   C["bg_dark"],
    "figure.facecolor": C["bg_dark"],
})


# ── Helpers ───────────────────────────────────────────────────────────────────

def save(fig, name):
    path = os.path.join(OUT_DIR, name)
    fig.savefig(path, dpi=DPI, bbox_inches="tight",
                facecolor=fig.get_facecolor())
    print(f"  saved  {name}")
    plt.close(fig)


def box(ax, x, y, w, h, fill, border, title, body="",
        title_size=14, body_size=12, radius=0.05, lw=2.2, alpha=0.93,
        title_color=None, body_color=None):
    """Rounded box with a bold title and optional body lines."""
    patch = FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0,rounding_size={radius}",
        linewidth=lw, edgecolor=border,
        facecolor=fill, alpha=alpha, zorder=3,
    )
    ax.add_patch(patch)
    tc = title_color or C["text_white"]
    bc = body_color  or C["text_dim"]
    cx = x + w / 2
    if body:
        # title sits in upper third, body in lower two-thirds
        ax.text(cx, y + h * 0.68, title, ha="center", va="center",
                fontsize=title_size, fontweight="bold", color=tc, zorder=4)
        ax.text(cx, y + h * 0.30, body, ha="center", va="center",
                fontsize=body_size, color=bc, zorder=4, linespacing=1.45)
    else:
        ax.text(cx, y + h / 2, title, ha="center", va="center",
                fontsize=title_size, fontweight="bold", color=tc, zorder=4)


def band(ax, x, y, w, h, fill, border, label, label_color=None, lw=1.5):
    """Translucent rectangular band with a corner label."""
    patch = FancyBboxPatch(
        (x, y), w, h,
        boxstyle="round,pad=0.05",
        linewidth=lw, edgecolor=border,
        facecolor=fill, alpha=0.45, zorder=1,
    )
    ax.add_patch(patch)
    lc = label_color or border
    ax.text(x + 0.25, y + h - 0.18, label,
            fontsize=9.5, fontweight="bold", color=lc,
            va="top", zorder=2, alpha=0.85)


def arr(ax, x1, y1, x2, y2, color=C["arrow_white"], lw=1.8,
        label="", label_side="right"):
    """Arrow with optional midpoint label."""
    ax.annotate(
        "", xy=(x2, y2), xytext=(x1, y1),
        arrowprops=dict(arrowstyle="-|>", color=color,
                        lw=lw, mutation_scale=14),
        zorder=5,
    )
    if label:
        mx = (x1 + x2) / 2
        my = (y1 + y2) / 2
        dx = 0.12 if label_side == "right" else -0.12
        ax.text(mx + dx, my, label, fontsize=8, color=color,
                va="center", ha="left" if label_side == "right" else "right",
                bbox=dict(boxstyle="round,pad=0.18", facecolor=C["bg_dark"],
                          edgecolor="none", alpha=0.82),
                zorder=6)


def setup(fw, fh):
    fig, ax = plt.subplots(figsize=(fw, fh))
    ax.set_xlim(0, fw)
    ax.set_ylim(0, fh)
    ax.axis("off")
    fig.patch.set_facecolor(C["bg_dark"])
    ax.set_facecolor(C["bg_dark"])
    return fig, ax


def title_block(ax, fw, fh, t1, t2):
    ax.text(fw / 2, fh - 0.35, t1, ha="center", va="top",
            fontsize=20, fontweight="bold", color=C["text_white"])
    ax.text(fw / 2, fh - 1.05, t2, ha="center", va="top",
            fontsize=12, color=C["text_dim"])


# ─────────────────────────────────────────────────────────────────────────────
# DIAGRAM 1 — Overall Architecture
# Canvas: 32 × 22
# ─────────────────────────────────────────────────────────────────────────────

def diagram_overall():
    FW, FH = 32, 22
    fig, ax = setup(FW, FH)
    title_block(ax, FW, FH,
                "consul-mcp-agents — Full Stack Architecture",
                "GKE + Consul Dataplane  •  HCP Vault Dedicated CA  •  5-Minute GCP Credentials  •  MCP AI Agents")

    # ── Layer bands ───────────────────────────────────────────────────────────

    # HCP band  (top)
    band(ax, 0.4, 16.8, 31.2, 4.5, "#1C0A3A", C["vault_purple_lt"],
         "HashiCorp Cloud Platform (HCP)", C["vault_purple_lt"])

    # GCP outer band
    band(ax, 0.4, 0.4, 31.2, 16.2, "#001633", C["gcp_blue"],
         "Google Cloud Platform (GCP)", C["gcp_blue_lt"])

    # GKE cluster band (right column inside GCP)
    band(ax, 10.6, 0.8, 20.6, 12.2, "#001A0D", C["gke_green_lt"],
         "GKE Cluster  (Consul Dataplane Mode)", C["gke_green_lt"])

    # ── HCP Vault boxes — 5 boxes spread across top ───────────────────────────
    # widths chosen so they fill 0.7 → 31.3 with 0.5 gaps
    # total inner width = 30.6, 5 boxes → each ~5.5, gaps 0.5
    hcp_y, hcp_h = 17.3, 2.9
    hcp_boxes = [
        (0.7,  5.5, C["vault_purple"],    C["vault_purple_lt"],
         "HCP Vault Dedicated",
         "PKI Root CA  +  Intermediate CA\nGCP Secrets Engine  (5-min TTL)\nKV v2 config store"),
        (6.7,  5.5, "#2A1650",            C["vault_purple_lt"],
         "Vault Auth Methods",
         "auth/gcp  —  Consul VMs\nauth/kubernetes  —  GKE pods\nauth/userpass  —  humans"),
        (12.7, 5.5, "#1A2650",            C["hcp_teal_lt"],
         "Vault KV v2",
         "secret/mcp-agents/config\nsecret/mcp-agents/policies\nsecret/mcp-agents/llm-keys"),
        (18.7, 5.5, "#2A1650",            C["vault_purple_lt"],
         "HCP HVN",
         "VPC Peering  →  GCP\nPrivate Endpoint\nPublic Endpoint"),
        (24.7, 6.3, "#1A1650",            C["vault_purple_lt"],
         "Vault PKI",
         "connect-root  (10 yr)\nconnect-intermediate  (5 yr)\nLeaf certs  (72 h, auto-rotated)"),
    ]
    for x, w, fill, border, ttl, bod in hcp_boxes:
        box(ax, x, hcp_y, w, hcp_h, fill, border, ttl, bod,
            title_size=14, body_size=11.5, radius=0.07)

    # ── Left GCP column ───────────────────────────────────────────────────────

    # Consul External Control Plane
    box(ax, 0.7, 12.8, 9.5, 2.9,
        C["consul_pink"], C["consul_pink_lt"],
        "Consul External Control Plane  (GCE VMs)",
        "server.dc1.consul  •  8300 RPC  •  8301 Serf  •  8501 HTTPS  •  8502 gRPC\n"
        "vault-agent  →  GCP IAM auth  →  Vault PKI leaf certs  →  Connect CA config",
        title_size=14, body_size=11.5, radius=0.07)

    # GCP Dynamic Credentials
    box(ax, 0.7, 9.5, 9.5, 2.3,
        "#122600", C["gcp_blue_lt"],
        "GCP Dynamic Credentials  —  5-Minute TTL",
        "Vault GCP Secrets Engine  →  generateAccessToken API\n"
        "data-agent-gcp  (storage.admin, bigquery.admin)\n"
        "compute-agent-gcp  (compute.admin)",
        title_size=13, body_size=11.5, radius=0.07)

    # GCP API boxes
    api_y, api_h = 6.6, 1.9
    for i, (ttl, bod, col) in enumerate([
        ("Google Cloud\nStorage  (GCS)",  "list / read\nwrite / delete",   C["gcp_blue"]),
        ("BigQuery",                      "query / list\ncreate dataset",   C["gcp_blue"]),
        ("Compute Engine",                "list / get\nstart / stop / create", C["gcp_blue"]),
    ]):
        bx = 0.7 + i * 3.25
        box(ax, bx, api_y, 2.9, api_h, "#00112B", col,
            ttl, bod, title_size=12.5, body_size=11, radius=0.06)

    # ── GKE interior ──────────────────────────────────────────────────────────

    # Consul Dataplane bar
    box(ax, 10.9, 12.3, 19.9, 0.9,
        "#0A2010", C["consul_pink_lt"],
        "Consul Dataplane  (Envoy sidecar proxies — TLS via Vault PKI CA)",
        "", title_size=13, radius=0.05)

    # MCP Agent Pod boundary
    band(ax, 11.0, 1.0, 19.7, 11.0, "#1A0800", C["mcp_orange"],
         "MCP Agent Pod  (K8s Deployment — 2 replicas)", C["mcp_orange"], lw=1.8)

    # Upper containers row
    ctr_y, ctr_h = 8.8, 2.3
    ctr_boxes = [
        (11.3, 6.0, "#2A0E00", C["mcp_orange"],
         "vault-agent",
         "init container\nK8s auth  →  Vault\nrenders config + secrets"),
        (17.8, 6.2, "#2A0E00", C["mcp_orange"],
         "mcp-app",
         "Python CLI\nLangChain agents\nMCP servers (stdio)"),
        (24.5, 6.0, "#2A1600", C["user_gold"],
         "ttyd",
         "Web terminal\nport 7681\nbrowser access"),
    ]
    for x, w, fill, border, ttl, bod in ctr_boxes:
        box(ax, x, ctr_y, w, ctr_h, fill, border, ttl, bod,
            title_size=13.5, body_size=11.5, radius=0.06)

    # Lower MCP server row
    srv_y, srv_h = 4.8, 2.9
    box(ax, 11.3, srv_y, 7.2, srv_h,
        "#0D1E00", C["gke_green_lt"],
        "data_server  MCP",
        "list_buckets  /  read_object\nwrite_object  /  delete_object\nquery_bigquery  /  create_dataset",
        title_size=13.5, body_size=11.5, radius=0.06)

    box(ax, 19.1, srv_y, 7.2, srv_h,
        "#0D1E00", C["gke_green_lt"],
        "compute_server  MCP",
        "list_instances  /  get_instance\nstart_instance  /  stop_instance\ncreate_instance  /  delete_instance",
        title_size=13.5, body_size=11.5, radius=0.06)

    # Users
    box(ax, 26.8, srv_y, 3.7, srv_h,
        "#1A1200", C["user_gold"],
        "Users",
        "alice  (operator)\nbob     (analyst)\ncarol  (viewer)",
        title_size=13.5, body_size=11.5, radius=0.06)

    # ── Arrows ────────────────────────────────────────────────────────────────

    # HCP HVN → VPC peering (down into GCP band)
    arr(ax, 21.45, 16.8, 21.45, 15.9, C["vault_purple_lt"],
        label="VPC peering", label_side="right")

    # Vault PKI → Consul VM (issues leaf certs) — diagonal
    arr(ax, 27.85, 16.8, 5.45, 15.7, C["vault_purple_lt"],
        label="leaf certs (72 h)", label_side="right")

    # Vault Auth → Consul VM (GCP IAM auth for vault-agent)
    arr(ax, 9.45, 17.3, 5.45, 15.7, C["vault_purple_lt"],
        label="GCP IAM auth", label_side="right")

    # Consul VM → GKE dataplane (control plane connection)
    arr(ax, 10.2, 14.2, 10.9, 13.2, C["consul_pink_lt"],
        label="control plane", label_side="right")

    # GCP Creds → GCS/BigQuery/GCE (down)
    arr(ax, 2.1, 9.5, 2.1, 8.5, C["gcp_blue_lt"])
    arr(ax, 5.35, 9.5, 5.35, 8.5, C["gcp_blue_lt"])
    arr(ax, 8.55, 9.5, 8.55, 8.5, C["gcp_blue_lt"])

    # Vault GCP engine → GCP Creds (down)
    arr(ax, 3.45, 17.3, 3.45, 11.8, C["gcp_blue_lt"],
        label="5-min OAuth2", label_side="right")

    # vault-agent → mcp-app (rendered config)
    arr(ax, 17.3, 10.2, 17.8, 10.2, C["user_gold"],
        label="rendered\nconfig", label_side="right")

    # Users → ttyd (browser connection)
    arr(ax, 26.8, 6.55, 24.5, 6.55, C["user_gold"],
        label="browser", label_side="right")

    # ttyd ↔ mcp-app (bidirectional — draw two arrows)
    arr(ax, 24.5, 9.8, 24.0, 9.8, C["mcp_orange"])
    arr(ax, 24.0, 9.6, 24.5, 9.6, C["mcp_orange"])

    # mcp-app → MCP servers (stdio)
    arr(ax, 14.9, 8.8, 14.9, 7.7, C["gke_green_lt"],
        label="stdio", label_side="right")
    arr(ax, 22.7, 8.8, 22.7, 7.7, C["gke_green_lt"],
        label="stdio", label_side="right")

    # MCP servers → Vault GCP engine (token request)
    # Routing: from data_server left edge, across to GCP creds box
    ax.annotate("", xy=(5.45, 11.5), xytext=(11.3, 6.8),
                arrowprops=dict(arrowstyle="-|>", color=C["gcp_blue_lt"],
                                lw=1.6, mutation_scale=13,
                                connectionstyle="arc3,rad=-0.25"),
                zorder=5)
    ax.text(8.0, 9.6, "token\nrequest", fontsize=8, color=C["gcp_blue_lt"],
            ha="center", va="center", zorder=6,
            bbox=dict(boxstyle="round,pad=0.18", facecolor=C["bg_dark"],
                      edgecolor="none", alpha=0.82))

    # ── Legend ────────────────────────────────────────────────────────────────
    legend = [
        (C["vault_purple_lt"], "Vault / HCP"),
        (C["consul_pink_lt"],  "Consul"),
        (C["gcp_blue_lt"],     "GCP / Credentials"),
        (C["gke_green_lt"],    "GKE / MCP Servers"),
        (C["mcp_orange"],      "MCP Agent Pod"),
        (C["user_gold"],       "Users / Terminal"),
    ]
    for i, (col, lbl) in enumerate(legend):
        lx = 0.7 + i * 5.2
        ax.add_patch(mpatches.Rectangle((lx, 0.5), 0.4, 0.26, color=col, zorder=5))
        ax.text(lx + 0.55, 0.63, lbl, va="center", fontsize=9.5, color=C["text_dim"])

    save(fig, "overall-architecture.png")


# ─────────────────────────────────────────────────────────────────────────────
# DIAGRAM 2 — Vault PKI Certificate Chain
# Canvas: 26 × 20
# ─────────────────────────────────────────────────────────────────────────────

def diagram_pki():
    FW, FH = 26, 20
    fig, ax = setup(FW, FH)
    title_block(ax, FW, FH,
                "Vault PKI Certificate Authority Chain",
                "HCP Vault Dedicated as the root of trust for Consul Connect mTLS")

    # ── Root CA ───────────────────────────────────────────────────────────────
    box(ax, 5.5, 15.4, 15.0, 2.7,
        "#2D1B4E", C["vault_purple_lt"],
        "Root CA   (connect-root)",
        "Type: internal   |   RSA 4096   |   TTL: 10 years   |   Private key never exported\n"
        "Vault path:  connect-root/cert/ca      CRL:  connect-root/crl",
        title_size=17, body_size=13, radius=0.07)

    # TTL annotation — right of root
    ax.text(21.2, 17.2,
            "10-year validity\nRSA 4096\nNever exported",
            fontsize=10, color=C["vault_purple_lt"], va="center",
            bbox=dict(boxstyle="round,pad=0.4", facecolor="#1A0A2E",
                      edgecolor=C["vault_purple_lt"], lw=1.3))

    # ── Intermediate CA ───────────────────────────────────────────────────────
    box(ax, 5.5, 11.2, 15.0, 2.7,
        "#1B2D4E", C["hcp_teal_lt"],
        "Intermediate CA   (connect-intermediate)",
        "Type: internal   |   RSA 4096   |   TTL: 5 years   |   Signs leaf certs on demand\n"
        "Roles:  consul-connect  (SPIFFE / any CN)     consul-server-tls  (server.dc1.consul)",
        title_size=17, body_size=13, radius=0.07)

    # TTL annotation — right of intermediate
    ax.text(21.2, 13.0,
            "5-year validity\nRSA 4096\nRotated annually",
            fontsize=10, color=C["hcp_teal_lt"], va="center",
            bbox=dict(boxstyle="round,pad=0.4", facecolor="#0A1E2E",
                      edgecolor=C["hcp_teal_lt"], lw=1.3))

    # ── Three consumer boxes ───────────────────────────────────────────────────
    con_y, con_h = 7.0, 2.9
    consumers = [
        (1.0,  7.5, "#1A2000", C["consul_pink_lt"],
         "Consul Server TLS",
         "Role: consul-server-tls\nCN: server.dc1.consul\nTTL: 72 h  |  vault-agent renews"),
        (9.25, 7.5, "#1A2000", C["consul_pink_lt"],
         "Consul Connect CA",
         "Role: consul-connect\nAllow any name  +  SPIFFE URIs\nTTL: 72 h  |  issued by Consul"),
        (17.5, 7.5, "#001A10", C["gke_green_lt"],
         "GKE TLS Trust Anchor",
         "ca_chain_pem output\nStored as K8s secret\nHelm: global.tls.caCert"),
    ]
    for x, w, fill, border, ttl, bod in consumers:
        box(ax, x, con_y, w, con_h, fill, border, ttl, bod,
            title_size=14.5, body_size=12.5, radius=0.06)

    # TTL annotation — right of consumers
    ax.text(21.2, 8.9,
            "72-hour leaf certs\nRSA 2048\nAuto-renewed",
            fontsize=10, color=C["gke_green_lt"], va="center",
            bbox=dict(boxstyle="round,pad=0.4", facecolor="#001A0D",
                      edgecolor=C["gke_green_lt"], lw=1.3))

    # ── Leaf / usage row ──────────────────────────────────────────────────────
    leaf_y, leaf_h = 2.4, 3.2
    leaves = [
        (1.0,  5.5, "#0D1A00", C["gke_green_lt"],
         "Consul Server\nRPC / HTTPS Certs",
         "Issued by Vault PKI\nvia vault-agent daemon\nRenewed before expiry"),
        (7.5,  5.5, "#0D1A00", C["gke_green_lt"],
         "Service Mesh\nLeaf Certs",
         "Consul CA provider calls\nconnect-intermediate/sign\nOne cert per service per pod"),
        (14.0, 5.5, "#0D1A00", C["gke_green_lt"],
         "mTLS: Pod to Pod",
         "Envoy sidecars present\nSPIFFE identity certs\nMutual auth required"),
        (20.5, 4.7, "#001933", C["gcp_blue_lt"],
         "Consul to GKE\nDataplane TLS",
         "Pods connect  →  port 8501\nVerify using CA chain\nfrom Vault PKI"),
    ]
    for x, w, fill, border, ttl, bod in leaves:
        box(ax, x, leaf_y, w, leaf_h, fill, border, ttl, bod,
            title_size=13.5, body_size=12, radius=0.06)

    # ── Arrows ────────────────────────────────────────────────────────────────

    # Root → Intermediate (signs CSR)
    arr(ax, 13.0, 15.4, 13.0, 13.9, C["vault_purple_lt"], lw=3)
    ax.text(13.5, 14.65, "signs CSR", fontsize=10.5, color=C["vault_purple_lt"],
            va="center", fontweight="bold")

    # Intermediate → three consumers
    arr(ax, 4.75, 11.2, 4.75, 9.9, C["hcp_teal_lt"], lw=2.2)    # → Server TLS
    arr(ax, 13.0, 11.2, 13.0, 9.9, C["hcp_teal_lt"], lw=2.2)    # → Connect CA
    arr(ax, 20.0, 11.2, 21.25, 9.9, C["hcp_teal_lt"], lw=2.2)   # → GKE Trust

    ax.text(2.5, 10.7,  "issues server TLS",    fontsize=9, color=C["hcp_teal_lt"])
    ax.text(9.5, 10.7,  "issues Connect certs",  fontsize=9, color=C["hcp_teal_lt"])
    ax.text(17.0, 10.7, "CA cert trust anchor",  fontsize=9, color=C["hcp_teal_lt"])

    # Consumers → leaf types
    arr(ax, 4.75, 7.0,  4.75, 5.6,  C["gke_green_lt"], lw=1.8)
    arr(ax, 13.0, 7.0,  10.75, 5.6, C["gke_green_lt"], lw=1.8)
    arr(ax, 13.0, 7.0,  17.25, 5.6, C["gke_green_lt"], lw=1.8)
    arr(ax, 21.25, 7.0, 22.85, 5.6, C["gcp_blue_lt"],  lw=1.8)

    save(fig, "vault-pki-chain.png")


# ─────────────────────────────────────────────────────────────────────────────
# DIAGRAM 3 — Credential & Authentication Flow
# Canvas: 30 × 22
# Top row: steps 1-5 (user login → MCP server start)
# Middle row: steps 6-8 (identity context, tool invoke, token request)
# Bottom row: steps 9-13 (Vault GCP engine → API response)
# ─────────────────────────────────────────────────────────────────────────────

def diagram_credential_flow():
    FW, FH = 30, 22
    fig, ax = setup(FW, FH)
    title_block(ax, FW, FH,
                "Credential & Authentication Flow",
                "User login  →  Vault userpass  →  LangChain agent  →  5-minute GCP OAuth2 token  →  GCS / BigQuery / GCE")

    # ── Row 1: Login and session setup  (y=17.0, h=3.5) ─────────────────────
    R1Y, R1H = 17.0, 2.9
    BW1 = 5.2   # box width for row 1
    GAP = 0.5
    r1_starts = [0.5 + i * (BW1 + GAP) for i in range(5)]

    r1 = [
        ("#1A1200", C["user_gold"],
         "1   User",
         "Browser  →  ttyd port 7681\nEnter username + password\nVault userpass credentials"),
        ("#2D1B4E", C["vault_purple_lt"],
         "2   Vault Userpass Auth",
         "POST auth/userpass/login/alice\nToken TTL: 1 hour\nPolicies: operator-policy"),
        ("#2D1B4E", C["vault_purple_lt"],
         "3   Session Created",
         "vault_token: s.xxxxxxxx\nhuman_role: operator\nSession.is_expired: False"),
        ("#1A0800", C["mcp_orange"],
         "4   Agent Selected",
         "User picks: data_agent\nPolicyEngine.resolve()\noperator x data_agent"),
        ("#0D1A00", C["gke_green_lt"],
         "5   MCP Server Started",
         "stdio subprocess launched\nMCP_IDENTITY_CONTEXT\nenv var injected"),
    ]
    for i, (fill, border, ttl, bod) in enumerate(r1):
        box(ax, r1_starts[i], R1Y, BW1, R1H, fill, border, ttl, bod,
            title_size=14, body_size=12, radius=0.06)

    # Row 1 horizontal arrows
    for i in range(4):
        arr(ax, r1_starts[i] + BW1, R1Y + R1H / 2,
            r1_starts[i + 1], R1Y + R1H / 2,
            C["arrow_white"], lw=2.2)

    # ── Row 2: Identity + tool invoke + token request  (y=11.2, h=4.4) ──────
    R2Y, R2H = 11.2, 3.8

    BW2a = 8.8  # IdentityContext (wide — lots of fields)
    BW2b = 8.8  # Tool invocation
    BW2c = 10.6 # Dual-layer TTL (widest — important detail)

    box(ax, 0.5, R2Y, BW2a, R2H,
        "#1A0800", C["mcp_orange"],
        "6   IdentityContext Built",
        "agent_id: data_agent\n"
        "human_id: alice   |   human_role: operator\n"
        "vault_token: s.xxxx\n"
        "allowed_tools: {list_buckets, read_object, ...}\n"
        "max_gcp_token_ttl: 5m",
        title_size=14, body_size=12, radius=0.06)

    box(ax, 9.8, R2Y, BW2b, R2H,
        "#0D1A00", C["gke_green_lt"],
        "7   Tool Invocation  (LangChain)",
        'AgentExecutor.ainvoke(\n'
        '    {"input": "list my buckets"})\n'
        'LangChain selects: list_buckets\n'
        'MCP call_tool("list_buckets", {})',
        title_size=14, body_size=12, radius=0.06)

    box(ax, 19.1, R2Y, BW2c, R2H,
        "#2D1B4E", C["vault_purple_lt"],
        "8   _get_gcp_token()  —  Dual-Layer TTL",
        "Cache miss  →  request new token\n"
        "hvac.secrets.gcp\n"
        "  .generate_impersonated_account_oauth2_access_token()\n"
        "Layer 1 (server): vault ttl = 300 s\n"
        "Layer 2 (policy): max_gcp_token_ttl = 300 s\n"
        "Effective TTL = min(300, 300) = 300 s",
        title_size=14, body_size=12, radius=0.06)

    # Arrows within row 2
    arr(ax, 9.3, R2Y + R2H / 2, 9.8, R2Y + R2H / 2, C["mcp_orange"], lw=2.2)
    arr(ax, 18.6, R2Y + R2H / 2, 19.1, R2Y + R2H / 2, C["vault_purple_lt"], lw=2.2)

    # ── Row 3: Vault engine → response  (y=4.2, h=5.5) ──────────────────────
    R3Y, R3H = 4.2, 4.7
    BW3 = 5.0
    r3_starts = [0.5 + i * (BW3 + 0.55) for i in range(5)]

    r3 = [
        ("#2D1B4E", C["vault_purple_lt"],
         "9\nVault GCP Engine",
         "POST gcp/impersonated-account\n/data-agent-gcp/token\nTTL capped at 300 s"),
        ("#001933", C["gcp_blue_lt"],
         "10\nGCP IAM API",
         "projects.serviceAccounts\n.generateAccessToken\nOAuth2 scope: cloud-platform"),
        (C["gcp_blue"], C["gcp_blue_lt"],
         "11\n5-Min Token Issued",
         "OAuth2 access_token\nexpires_in: 3600 s\nEffective TTL: 300 s"),
        ("#0D1A00", C["gke_green_lt"],
         "12\nGCS API Call",
         "google.cloud.storage\nClient(credentials=token)\nlist_buckets()"),
        ("#1A1200", C["user_gold"],
         "13\nResponse to User",
         "Bucket list returned\nLangChain formats output\nDisplayed in ttyd terminal"),
    ]
    for i, (fill, border, ttl, bod) in enumerate(r3):
        box(ax, r3_starts[i], R3Y, BW3, R3H, fill, border, ttl, bod,
            title_size=14, body_size=12, radius=0.06)

    # Row 3 horizontal arrows (left to right)
    for i in range(4):
        arr(ax, r3_starts[i] + BW3, R3Y + R3H / 2,
            r3_starts[i + 1], R3Y + R3H / 2,
            C["gcp_blue_lt"], lw=2.2)

    # ── Inter-row connections ─────────────────────────────────────────────────

    # Row 1 step 5 → Row 2 step 6 (down-left)
    ax.annotate("", xy=(4.9, R2Y + R2H), xytext=(r1_starts[4] + 1.0, R1Y),
                arrowprops=dict(arrowstyle="-|>", color=C["mcp_orange"],
                                lw=2, mutation_scale=14,
                                connectionstyle="arc3,rad=0.25"),
                zorder=5)

    # Row 2 step 8 → Row 3 step 9 (down, slight left)
    ax.annotate("", xy=(r3_starts[0] + BW3 / 2, R3Y + R3H),
                xytext=(21.5, R2Y),
                arrowprops=dict(arrowstyle="-|>", color=C["vault_purple_lt"],
                                lw=2, mutation_scale=14,
                                connectionstyle="arc3,rad=0.2"),
                zorder=5)
    ax.text(16.5, 10.0, "vault_token\n+ role", fontsize=9,
            color=C["vault_purple_lt"], ha="center",
            bbox=dict(boxstyle="round,pad=0.25", facecolor=C["bg_dark"],
                      edgecolor="none", alpha=0.85), zorder=6)

    # Row 3 step 13 → up to Row 1 step 1 (user sees response)
    ax.annotate("", xy=(r1_starts[0] + BW1 / 2, R1Y),
                xytext=(r3_starts[4] + BW3 / 2, R3Y + R3H),
                arrowprops=dict(arrowstyle="-|>", color=C["user_gold"],
                                lw=2, mutation_scale=14,
                                connectionstyle="arc3,rad=-0.35"),
                zorder=5)

    # ── TTL callout band ──────────────────────────────────────────────────────
    ttl_bg = FancyBboxPatch((0.5, 1.5), 29.0, 2.3,
                             boxstyle="round,pad=0.08",
                             facecolor="#100A00", edgecolor=C["user_gold"],
                             linewidth=1.5, alpha=0.7, zorder=2)
    ax.add_patch(ttl_bg)
    ax.text(15.0, 2.65,
            "Dual-Layer TTL Enforcement:   "
            "Terraform:  vault_gcp_secret_impersonated_account { ttl = \"300\" }   |   "
            "App policy:  max_gcp_token_ttl: \"5m\"   |   "
            "Effective = min(vault_ttl, policy_ttl) = 300 s",
            ha="center", va="center", fontsize=10.5,
            color=C["user_gold"], fontweight="bold", zorder=3)
    ax.text(15.0, 1.95,
            "Both layers enforce independently — either one alone is sufficient to cap the credential lifetime.",
            ha="center", va="center", fontsize=9.5, color=C["text_dim"], zorder=3)

    save(fig, "credential-flow.png")


# ─────────────────────────────────────────────────────────────────────────────
# DIAGRAM 4 — Deployment Sequence
# Canvas: 30 × 24
# ─────────────────────────────────────────────────────────────────────────────

def diagram_deployment():
    FW, FH = 30, 24
    fig, ax = setup(FW, FH)
    title_block(ax, FW, FH,
                "Deployment Sequence & Dependency Ordering",
                "Apply phases in order  —  each layer depends on the one above it")

    # Phase definitions: (y_bottom, height, fill, border, label)
    phases = [
        (19.6, 3.0, "#1C0A3A", C["vault_purple_lt"], "Phase 1a  —  Network Foundation",          "task phase1:apply"),
        (15.4, 3.0, "#2D0A1E", C["consul_pink_lt"],  "Phase 1b  —  HCP Vault Dedicated",           "HCP Portal + task phase1:apply"),
        (11.2, 3.0, "#001A2E", C["hcp_teal_lt"],     "Phase 1c  —  Vault PKI  +  Config  +  Consul VMs", "task phase1:apply"),
        (7.0,  3.0, "#001A10", C["gke_green_lt"],    "Phase 2   —  GKE Cluster  +  Consul Dataplane Helm", "task phase2:apply"),
        (3.2,  2.7, "#1A0800", C["mcp_orange"],      "Phase 3   —  Vault K8s Auth  +  Docker  +  MCP Agents", "task phase3:apply"),
        (0.4,  1.8, "#1A1400", C["user_gold"],       "Phase 4   —  Verification & Access",         "task summary"),
    ]

    # Inner task boxes per phase
    # Each entry: (relative_x, rel_width, title, body)
    # The band spans x=0.5 to x=27.5 (width=27.0)
    BAND_X, BAND_W = 0.5, 28.0
    TASK_MARGIN = 0.35   # space between task boxes and band edges
    TASK_GAP    = 0.4    # gap between task boxes
    TASK_TOP_PAD = 0.9   # space below band top label

    phase_tasks = [
        # Phase 1a
        [
            ("#2D1B4E", C["vault_purple_lt"],
             "module.network",
             "VPC + Subnets\nCloud NAT"),
            ("#2D1B4E", C["vault_purple_lt"],
             "module.network",
             "Firewall rules\nIAP SSH access"),
            ("#2D1B4E", C["vault_purple_lt"],
             "GCS State Bucket",
             "Terraform backend\ngsutil mb ..."),
            ("#2D1B4E", C["vault_purple_lt"],
             "task packer:build",
             "AlmaLinux + Consul\n+ vault-agent  →  GCP"),
        ],
        # Phase 1b
        [
            ("#4E0A2D", C["consul_pink_lt"],
             "hcp_hvn.main",
             "HCP Virtual Network\nin GCP region"),
            ("#4E0A2D", C["consul_pink_lt"],
             "hcp_vault_cluster.main",
             "Dedicated tier\nplus_small"),
            ("#4E0A2D", C["consul_pink_lt"],
             "hcp_gcp_peering\n_connection",
             "HVN  →  GCP VPC\nprivate routing"),
            ("#4E0A2D", C["consul_pink_lt"],
             "hcp_hvn_route x N",
             "Route GCP CIDRs\ninto HVN"),
        ],
        # Phase 1c
        [
            ("#0A2D4E", C["hcp_teal_lt"],
             "vault_mount\nconnect-root",
             "Root PKI CA\n10-year TTL"),
            ("#0A2D4E", C["hcp_teal_lt"],
             "vault_mount\nconnect-intermediate",
             "Intermediate CA\n5-year TTL"),
            ("#0A2D4E", C["hcp_teal_lt"],
             "vault_auth_backend\ngcp  +  kubernetes",
             "VM auth + pod auth\nGCP IAM + K8s JWT"),
            ("#0A2D4E", C["hcp_teal_lt"],
             "vault_kv_secret_v2 x4",
             "config + policies\n+ llm-keys + consul"),
            ("#0A2D4E", C["hcp_teal_lt"],
             "module.consul",
             "Consul VMs boot\nvault-agent fetches certs"),
        ],
        # Phase 2
        [
            ("#0A4E2D", C["gke_green_lt"],
             "google_container\n_cluster",
             "Private GKE cluster\nWorkload Identity"),
            ("#0A4E2D", C["gke_green_lt"],
             "google_container\n_node_pool",
             "e2-standard-4\nx node_count nodes"),
            ("#0A4E2D", C["gke_green_lt"],
             "helm_release.consul",
             "Consul dataplane\nTLS enabled"),
            ("#0A4E2D", C["gke_green_lt"],
             "Consul ingress\ngateway",
             "LoadBalancer IP\nassigned"),
        ],
        # Phase 3
        [
            ("#4E1A00", C["mcp_orange"],
             "vault:configure\n-k8s-auth",
             "GKE endpoint\n→  Vault K8s auth"),
            ("#4E1A00", C["mcp_orange"],
             "task docker:build",
             "vault-mcp-agents\ncontainer image"),
            ("#4E1A00", C["mcp_orange"],
             "task docker:push",
             "Push to\nArtifact Registry"),
            ("#4E1A00", C["mcp_orange"],
             "kubernetes\n_deployment",
             "2 replicas\nvault-agent + ttyd"),
            ("#4E1A00", C["mcp_orange"],
             "LoadBalancer\nIP exposed",
             "mcp-agents-lb\nport 80 → 7681"),
        ],
        # Phase 4
        [
            ("#4E3A00", C["user_gold"],
             "task mcp:url",
             "http://<IP>/"),
            ("#4E3A00", C["user_gold"],
             "Vault userpass login",
             "alice / bob / carol"),
            ("#4E3A00", C["user_gold"],
             "Select agent",
             "data_agent or\ncompute_agent"),
            ("#4E3A00", C["user_gold"],
             "GCP API calls",
             "5-min OAuth2 tokens\nGCS / BigQuery / GCE"),
        ],
    ]

    for (py, ph, pfill, pborder, plabel, pcmd), tasks in zip(phases, phase_tasks):
        # Draw phase band
        band(ax, BAND_X, py, BAND_W, ph, pfill, pborder, plabel, pborder, lw=1.8)

        # Command label — right-aligned inside the band
        ax.text(BAND_X + BAND_W - 0.3, py + ph - 0.15, pcmd,
                ha="right", va="top", fontsize=9, color=pborder,
                style="italic", alpha=0.9,
                bbox=dict(boxstyle="round,pad=0.2", facecolor=C["bg_dark"],
                          edgecolor=pborder, linewidth=1, alpha=0.7))

        # Task boxes within the band
        n = len(tasks)
        task_area_w = BAND_W - 2 * TASK_MARGIN
        box_w = (task_area_w - (n - 1) * TASK_GAP) / n
        box_h = ph - TASK_TOP_PAD - 0.25
        box_y = py + 0.2

        for j, (fill, border, ttl, bod) in enumerate(tasks):
            bx = BAND_X + TASK_MARGIN + j * (box_w + TASK_GAP)
            box(ax, bx, box_y, box_w, box_h, fill, border, ttl, bod,
                title_size=12, body_size=11, radius=0.05, lw=1.6)

    # ── Dependency arrows between phases ─────────────────────────────────────
    arrow_x = FW / 2
    phase_bottoms = [p[0] for p in phases]
    phase_tops    = [p[0] + p[1] for p in phases]

    for i in range(len(phases) - 1):
        arr(ax, arrow_x, phase_bottoms[i], arrow_x, phase_tops[i + 1] + 0.05,
            C["arrow_white"], lw=2.8)

    save(fig, "deployment-sequence.png")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("Generating diagrams ...")
    diagram_overall()
    diagram_pki()
    diagram_credential_flow()
    diagram_deployment()
    print("Done.")
