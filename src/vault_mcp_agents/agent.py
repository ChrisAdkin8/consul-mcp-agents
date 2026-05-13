"""Interactive agent REPL — connects MCP server tools to the configured LLM."""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Optional

import anthropic
import openai
from contextlib import asynccontextmanager

from mcp import ClientSession
from mcp.client.sse import sse_client
from rich.console import Console
from rich.prompt import Prompt

from vault_mcp_agents.config import Policies, Settings, load_policies, load_settings
from vault_mcp_agents.vault_client import VaultClient

console = Console()

BANNER = """
  ╔══════════════════════════════════════════════════════╗
  ║         Vault MCP Agent — Interactive CLI            ║
  ║   Log in with your Vault credentials to continue.   ║
  ╚══════════════════════════════════════════════════════╝
"""


def _prompt_login(vault: VaultClient) -> tuple[str, list[str]]:
    """Prompt for Vault credentials and return (username, policies)."""
    console.print(BANNER)
    username = Prompt.ask("[bold cyan]Vault username[/bold cyan]")
    password = Prompt.ask("[bold cyan]Password[/bold cyan]", password=True)
    try:
        auth = vault.login_userpass(username, password)
    except Exception as exc:
        console.print(f"[red]Login failed:[/red] {exc}")
        sys.exit(1)
    policies = auth.get("policies", [])
    console.print(f"[green]Authenticated as[/green] [bold]{username}[/bold]  policies={policies}")
    return username, policies


def _select_agent(settings: Settings, role: str, policies: Policies) -> tuple[str, str]:
    """Present the agent menu and return (agent_name, mcp_server_name)."""
    role_policy = policies.roles.get(role)
    available = list(settings.agents.keys())

    console.print("\n[bold]Available agents:[/bold]")
    for i, name in enumerate(available, start=1):
        agent_def = settings.agents[name]
        console.print(f"  [{i}] [cyan]{name}[/cyan] — {agent_def.description}")

    choice = Prompt.ask("Select agent", choices=[str(i) for i in range(1, len(available) + 1)])
    agent_name = available[int(choice) - 1]
    mcp_server = settings.agents[agent_name].mcp_server
    return agent_name, mcp_server


# ---------------------------------------------------------------------------
# LLM provider adapters — encapsulate API differences
# ---------------------------------------------------------------------------


class _AnthropicProvider:
    """Adapter for the Anthropic Messages API."""

    def __init__(self, api_key: str, model: str, mcp_tools: list) -> None:
        self.client = anthropic.Anthropic(api_key=api_key)
        self.model = model
        self.tools: list[dict] = [
            {
                "name": t.name,
                "description": t.description or "",
                "input_schema": t.inputSchema or {"type": "object", "properties": {}},
            }
            for t in mcp_tools
        ]

    def call(self, messages: list[dict]) -> tuple[bool, str, list[tuple[str, dict, str]]]:
        """Call the LLM. Returns (is_final, text, [(tool_name, args, call_id), ...])."""
        response = self.client.messages.create(
            model=self.model,
            max_tokens=4096,
            tools=self.tools if self.tools else anthropic.NOT_GIVEN,
            messages=messages,
        )

        if response.stop_reason == "tool_use":
            messages.append({"role": "assistant", "content": response.content})
            tool_calls = [
                (b.name, b.input, b.id)
                for b in response.content
                if b.type == "tool_use"
            ]
            return False, "", tool_calls

        # end_turn or unexpected stop reason
        text = next((b.text for b in response.content if hasattr(b, "text")), "")
        messages.append({"role": "assistant", "content": response.content})
        return True, text, []

    def append_tool_results(self, messages: list[dict], results: list[tuple[str, str]]) -> None:
        """Append tool results in Anthropic format (single user message with tool_result blocks)."""
        messages.append({
            "role": "user",
            "content": [
                {"type": "tool_result", "tool_use_id": tid, "content": text}
                for tid, text in results
            ],
        })


class _OpenAIProvider:
    """Adapter for the OpenAI Chat Completions API."""

    def __init__(self, api_key: str, model: str, mcp_tools: list) -> None:
        self.client = openai.OpenAI(api_key=api_key)
        self.model = model
        self.tools: list[dict] = [
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description or "",
                    "parameters": t.inputSchema or {"type": "object", "properties": {}},
                },
            }
            for t in mcp_tools
        ]

    def call(self, messages: list[dict]) -> tuple[bool, str, list[tuple[str, dict, str]]]:
        """Call the LLM. Returns (is_final, text, [(tool_name, args, call_id), ...])."""
        response = self.client.chat.completions.create(
            model=self.model,
            tools=self.tools if self.tools else openai.NOT_GIVEN,
            messages=messages,
        )
        choice = response.choices[0]

        if choice.finish_reason == "tool_calls":
            messages.append(choice.message)
            tool_calls = [
                (tc.function.name, json.loads(tc.function.arguments or "{}"), tc.id)
                for tc in choice.message.tool_calls or []
            ]
            return False, "", tool_calls

        # stop or unexpected finish reason
        text = choice.message.content or ""
        messages.append({"role": "assistant", "content": text})
        return True, text, []

    def append_tool_results(self, messages: list[dict], results: list[tuple[str, str]]) -> None:
        """Append tool results in OpenAI format (one tool message per result)."""
        for tid, text in results:
            messages.append({
                "role": "tool",
                "tool_call_id": tid,
                "content": text,
            })


# ---------------------------------------------------------------------------
# Unified REPL loop
# ---------------------------------------------------------------------------


async def _run_repl(
    session: ClientSession,
    model: str,
    allowed_tools: list[str],
    api_key: str,
    provider: str,
) -> None:
    """Run the interactive REPL with the configured LLM provider."""
    tools_response = await session.list_tools()
    mcp_tools = [t for t in tools_response.tools if t.name in allowed_tools]

    if provider == "anthropic":
        llm = _AnthropicProvider(api_key, model, mcp_tools)
    else:
        llm = _OpenAIProvider(api_key, model, mcp_tools)

    messages: list[dict] = []

    console.print(
        "\n[green]Agent ready.[/green] Type a natural-language command, or [bold]exit[/bold] to quit.\n"
    )
    console.print(
        f"Available tools: [cyan]{', '.join(allowed_tools)}[/cyan]\n"
    )

    while True:
        user_input = Prompt.ask("[bold green]You[/bold green]").strip()
        if user_input.lower() in ("exit", "quit", "q"):
            break
        if not user_input:
            continue

        messages.append({"role": "user", "content": user_input})

        while True:
            is_final, text, tool_calls = llm.call(messages)

            if is_final or not tool_calls:
                if text:
                    console.print(f"\n[bold blue]Agent:[/bold blue] {text}\n")
                break

            results: list[tuple[str, str]] = []
            for tc_name, tc_args, tc_id in tool_calls:
                console.print(
                    f"[dim]→ calling tool [cyan]{tc_name}[/cyan] "
                    f"with {tc_args}[/dim]"
                )
                tool_result = await session.call_tool(tc_name, tc_args)
                result_text = (
                    tool_result.content[0].text
                    if tool_result.content
                    else "(no output)"
                )
                results.append((tc_id, result_text))

            llm.append_tool_results(messages, results)


async def run_agent_session(config: Path, policies: Path) -> None:
    """Main entry point for an interactive agent session."""
    settings = load_settings(config)
    policy_set = load_policies(policies)

    vault = VaultClient(
        address=os.environ.get("VAULT_ADDR", settings.vault.address),
        namespace=settings.vault.namespace or "",
    )

    _, vault_policies = _prompt_login(vault)
    role = vault.determine_role(vault_policies)

    if role is None:
        console.print(
            "[red]No recognised role (operator/analyst/viewer) found in your Vault policies.[/red]"
        )
        console.print(f"Your policies: {vault_policies}")
        sys.exit(1)

    console.print(f"Role: [bold yellow]{role}[/bold yellow]")

    agent_name, mcp_server_name = _select_agent(settings, role, policy_set)
    mcp_server_def = settings.mcp_servers.get(mcp_server_name)

    if mcp_server_def is None:
        console.print(f"[red]MCP server '{mcp_server_name}' not found in config.[/red]")
        sys.exit(1)

    # Resolve allowed tools for this role + agent combination
    role_policy = policy_set.roles.get(role)
    allowed_tools: list[str] = []
    if role_policy and agent_name in role_policy.agents:
        allowed_tools = role_policy.agents[agent_name].allowed_tools

    console.print(
        f"\n[bold]Starting agent:[/bold] [cyan]{agent_name}[/cyan] "
        f"via MCP server [cyan]{mcp_server_name}[/cyan]"
    )
    console.print(
        f"[dim]Connecting via Consul mesh (SSE upstream): {mcp_server_def.url}[/dim]"
    )

    @asynccontextmanager
    async def _connect():
        async with sse_client(mcp_server_def.url, timeout=30) as (read, write):
            yield read, write

    async with _connect() as (read, write):
        async with ClientSession(read, write) as mcp_session:
            await mcp_session.initialize()

            provider = settings.llm.provider.lower()
            if provider not in ("anthropic", "openai"):
                console.print(f"[red]Unsupported LLM provider: '{provider}'. Valid options: anthropic, openai[/red]")
                sys.exit(1)

            env_key = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
            api_key = os.environ.get(env_key, "")
            if not api_key:
                console.print(f"[red]{env_key} is not set. Cannot start agent.[/red]")
                sys.exit(1)

            await _run_repl(
                mcp_session,
                model=settings.llm.model,
                allowed_tools=allowed_tools,
                api_key=api_key,
                provider=provider,
            )

    console.print("[bold]Session ended.[/bold]")
