"""vault-mcp-agents CLI entry point."""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path

import click

from vault_mcp_agents.agent import run_agent_session


@click.command()
@click.option(
    "--config",
    required=True,
    type=click.Path(exists=True, path_type=Path),
    help="Path to settings.yaml (rendered by vault-agent or bundled default).",
)
@click.option(
    "--policies",
    required=True,
    type=click.Path(exists=True, path_type=Path),
    help="Path to capabilities.yaml (rendered by vault-agent or bundled default).",
)
def cli(config: Path, policies: Path) -> None:
    """Vault MCP Agent — interactive terminal for GCS, BigQuery, and GCE operations.

    Authenticates to Vault using userpass credentials, selects an AI agent backed
    by MCP tools, and starts an interactive natural-language session.
    """
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    try:
        asyncio.run(run_agent_session(config=config, policies=policies))
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(0)
    except Exception as exc:
        click.echo(f"\nFatal error: {exc}", err=True)
        logging.getLogger(__name__).exception("Unhandled exception")
        sys.exit(1)
