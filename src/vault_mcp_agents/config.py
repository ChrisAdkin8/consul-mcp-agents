"""Configuration loader for settings.yaml and capabilities.yaml."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass
class VaultConfig:
    address: str = "http://127.0.0.1:8200"
    namespace: str = ""
    auth_method: str = "kubernetes"
    gcp_secrets_mount: str = "gcp"
    agent_approle_mount: str = "approle"


@dataclass
class GcpConfig:
    project_id: str = ""
    region: str = "us-central1"


@dataclass
class LlmConfig:
    provider: str = "anthropic"
    model: str = "claude-sonnet-4-6"
    temperature: float = 0.0


@dataclass
class AgentDef:
    description: str = ""
    mcp_server: str = ""
    gcp_impersonated_account: str = ""


@dataclass
class McpServerDef:
    transport: str = "stdio"
    command: str = "python"
    args: list[str] = field(default_factory=list)
    url: str = ""


@dataclass
class Settings:
    vault: VaultConfig = field(default_factory=VaultConfig)
    gcp: GcpConfig = field(default_factory=GcpConfig)
    llm: LlmConfig = field(default_factory=LlmConfig)
    agents: dict[str, AgentDef] = field(default_factory=dict)
    mcp_servers: dict[str, McpServerDef] = field(default_factory=dict)


@dataclass
class AgentRolePolicy:
    allowed_tools: list[str] = field(default_factory=list)
    max_gcp_token_ttl: str = "5m"


@dataclass
class RolePolicy:
    vault_policy: str = ""
    agents: dict[str, AgentRolePolicy] = field(default_factory=dict)


@dataclass
class Policies:
    roles: dict[str, RolePolicy] = field(default_factory=dict)


def load_settings(path: Path) -> Settings:
    """Load and parse settings.yaml into a Settings dataclass."""
    raw: dict[str, Any] = yaml.safe_load(path.read_text())
    if not raw or not isinstance(raw, dict):
        raise ValueError(f"Invalid or empty settings file: {path}")

    # Validate required top-level sections
    for section in ("agents", "mcp_servers"):
        if section not in raw or not raw[section]:
            raise ValueError(f"Settings file {path} is missing required section: '{section}'")

    vault_raw = raw.get("vault", {})
    vault = VaultConfig(
        address=vault_raw.get("address", "http://127.0.0.1:8200"),
        namespace=vault_raw.get("namespace", ""),
        auth_method=vault_raw.get("auth_method", "kubernetes"),
        gcp_secrets_mount=vault_raw.get("gcp_secrets_mount", "gcp"),
        agent_approle_mount=vault_raw.get("agent_approle_mount", "approle"),
    )

    gcp_raw = raw.get("gcp", {})
    gcp = GcpConfig(
        project_id=gcp_raw.get("project_id", ""),
        region=gcp_raw.get("region", "us-central1"),
    )

    llm_raw = raw.get("llm", {})
    llm = LlmConfig(
        provider=llm_raw.get("provider", "anthropic"),
        model=llm_raw.get("model", "claude-sonnet-4-6"),
        temperature=float(llm_raw.get("temperature", 0.0)),
    )

    agents: dict[str, AgentDef] = {}
    for name, adef in raw.get("agents", {}).items():
        agents[name] = AgentDef(
            description=adef.get("description", ""),
            mcp_server=adef.get("mcp_server", ""),
            gcp_impersonated_account=adef.get("gcp_impersonated_account", ""),
        )

    mcp_servers: dict[str, McpServerDef] = {}
    for name, sdef in raw.get("mcp_servers", {}).items():
        mcp_servers[name] = McpServerDef(
            transport=sdef.get("transport", "stdio"),
            command=sdef.get("command", "python"),
            args=sdef.get("args", []),
            url=sdef.get("url", ""),
        )

    return Settings(vault=vault, gcp=gcp, llm=llm, agents=agents, mcp_servers=mcp_servers)


def load_policies(path: Path) -> Policies:
    """Load and parse capabilities.yaml into a Policies dataclass."""
    raw: dict[str, Any] = yaml.safe_load(path.read_text())
    if not raw or not isinstance(raw, dict):
        raise ValueError(f"Invalid or empty policies file: {path}")

    if "roles" not in raw or not raw["roles"]:
        raise ValueError(f"Policies file {path} is missing required section: 'roles'")

    roles: dict[str, RolePolicy] = {}
    for role_name, role_raw in raw.get("roles", {}).items():
        agent_policies: dict[str, AgentRolePolicy] = {}
        for agent_name, ap_raw in role_raw.get("agents", {}).items():
            agent_policies[agent_name] = AgentRolePolicy(
                allowed_tools=ap_raw.get("allowed_tools", []),
                max_gcp_token_ttl=ap_raw.get("max_gcp_token_ttl", "5m"),
            )
        roles[role_name] = RolePolicy(
            vault_policy=role_raw.get("vault_policy", f"{role_name}-policy"),
            agents=agent_policies,
        )

    return Policies(roles=roles)
