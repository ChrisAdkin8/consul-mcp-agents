# =============================================================================
# vault-mcp-agents Dockerfile
#
# Multi-stage build (Chainguard images — zero/near-zero CVEs):
#   Stage 1 (builder): Install Python dependencies into a venv
#   Stage 2 (downloader): Fetch vault + ttyd binaries with checksum verification
#   Stage 3 (runtime): Minimal Wolfi-based runtime with venv + binaries
#
# The container runs:
#   - vault-agent (init container, renders secrets from Vault KV)
#   - mcp-app (Python CLI from vault_mcp_agents.main)
#   - ttyd (web terminal wrapping the CLI for browser-based multi-user access)
#
# vault-agent is run as a K8s init container (not in this image directly),
# but the vault binary is included here so operators can run vault commands
# from inside the container if needed.
#
# Build:
#   docker build -t vault-mcp-agents:latest -f docker/Dockerfile .
#
# Run locally (for testing):
#   docker run -it \
#     -e VAULT_ADDR=http://localhost:8200 \
#     vault-mcp-agents:latest
# =============================================================================

# ---- Stage 1: Python dependency builder ----
FROM cgr.dev/chainguard/python:latest-dev AS builder

USER root
WORKDIR /build

# Copy package metadata first — layer cache: dep install only re-runs when
# pyproject.toml changes, not when source code changes
COPY pyproject.toml README.md ./

# Create a minimal src package so pip can resolve the package
RUN mkdir -p src/vault_mcp_agents && \
    echo '__version__ = "0.0.0"' > src/vault_mcp_agents/__init__.py

# Install dependencies into a virtual environment (cached layer)
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip setuptools wheel && \
    /opt/venv/bin/pip install --no-cache-dir "."

# Now copy actual source and reinstall (only source changes bust this layer)
COPY src/ ./src/
RUN /opt/venv/bin/pip install --no-cache-dir --no-deps "."

# ---- Stage 2: Binary downloader (runs as root for curl/unzip) ----
FROM cgr.dev/chainguard/wolfi-base AS downloader

RUN apk add --no-cache curl unzip gpg gpg-agent gnupg-gpgconf gnupg-dirmngr

# ---- Install vault binary (GPG-verified checksums from HashiCorp) ----
ARG VAULT_VERSION=1.21.3
# HashiCorp GPG key — used to verify the SHA256SUMS signature
ARG VAULT_GPGKEY=C874011F0AB405110D02105534365D9472D7468F
RUN set -eux; \
    cd /tmp && \
    # Fetch HashiCorp's GPG key
    found=''; \
    for server in \
        hkps://keys.openpgp.org \
        hkps://keyserver.ubuntu.com \
        hkps://pgp.mit.edu \
    ; do \
        echo "Fetching GPG key ${VAULT_GPGKEY} from ${server}"; \
        gpg --batch --keyserver "$server" --recv-keys "${VAULT_GPGKEY}" && found=yes && break; \
    done; \
    test -z "$found" && echo "ERROR: failed to fetch HashiCorp GPG key" && exit 1; \
    # Download binary + checksums + signature
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" && \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" && \
    curl -fsSL -O "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS.sig" && \
    # Verify GPG signature on checksums, then verify binary against checksums
    gpg --batch --verify "vault_${VAULT_VERSION}_SHA256SUMS.sig" "vault_${VAULT_VERSION}_SHA256SUMS" && \
    grep "vault_${VAULT_VERSION}_linux_amd64.zip" "vault_${VAULT_VERSION}_SHA256SUMS" | sha256sum -c - && \
    unzip -q "vault_${VAULT_VERSION}_linux_amd64.zip" -d /tmp/ && \
    chmod 0755 /tmp/vault && \
    # Cleanup
    rm -f vault_${VAULT_VERSION}_* && \
    gpgconf --kill dirmngr && gpgconf --kill gpg-agent && rm -rf /root/.gnupg

# ---- Install ttyd (verified against upstream SHA256SUMS) ----
ARG TTYD_VERSION=1.7.7
RUN set -eux; \
    cd /tmp && \
    curl -fsSL -O "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/SHA256SUMS" && \
    curl -fsSL -O "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" && \
    grep "ttyd.x86_64" SHA256SUMS | sha256sum -c - && \
    mv ttyd.x86_64 ttyd && \
    chmod 0755 /tmp/ttyd && \
    rm -f SHA256SUMS

# ---- Stage 3: Runtime image ----
FROM cgr.dev/chainguard/wolfi-base AS runtime

LABEL org.opencontainers.image.title="vault-mcp-agents" \
      org.opencontainers.image.description="Vault-secured MCP AI agents for GCS, BigQuery, and GCE" \
      org.opencontainers.image.source="https://github.com/hashicorp-demos/vault-mcp-agents"

# Install only runtime dependencies (no pip, no build tools)
# NOTE: python version must match the builder (cgr.dev/chainguard/python:latest-dev)
RUN apk add --no-cache \
    python-3.14 \
    ca-certificates \
    bash \
    tini \
    libstdc++

# ---- Copy binaries from downloader ----
COPY --from=downloader /tmp/vault /usr/local/bin/vault
COPY --from=downloader /tmp/ttyd /usr/local/bin/ttyd
RUN vault version

# ---- Create application user ----
RUN adduser -D -u 1000 -h /home/mcpuser -s /bin/bash mcpuser

# ---- Copy Python venv from builder ----
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# ---- Copy application source ----
WORKDIR /app
COPY --chown=mcpuser:mcpuser src/ ./src/
COPY --chown=mcpuser:mcpuser config/ ./config/
COPY --chown=mcpuser:mcpuser policies/ ./policies/
COPY --chown=mcpuser:mcpuser docker/entrypoint.sh ./docker/entrypoint.sh

RUN chmod +x /app/docker/entrypoint.sh

# ---- Runtime directories ----
# /vault/secrets — vault-agent (K8s init container) writes rendered secrets here
# /tmp — writable scratch space
RUN mkdir -p /vault/secrets /tmp && \
    chown -R mcpuser:mcpuser /vault/secrets && \
    chown -R mcpuser:mcpuser /app

# ---- Default config paths ----
# These are overridden when vault-agent renders configs from Vault KV
ENV MCP_CONFIG_PATH="/vault/secrets/settings.yaml" \
    MCP_POLICIES_PATH="/vault/secrets/capabilities.yaml" \
    VAULT_AGENT_READY_FILE="/tmp/vault-agent-ready" \
    MCP_TRANSPORT="stdio" \
    MCP_PORT="8080" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:/usr/local/bin:$PATH"

USER mcpuser

# ttyd web terminal port
EXPOSE 7681

# Use tini as PID 1 (handles signal forwarding and zombie reaping)
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/docker/entrypoint.sh"]
