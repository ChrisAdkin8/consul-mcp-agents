"""MCP server exposing GCE instance management tools.

Run as:
    python -m vault_mcp_agents.mcp.compute_server
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import threading
from typing import Any

import mcp.types as types
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.server.sse import SseServerTransport

try:
    from google.cloud import compute_v1
    from google.oauth2.credentials import Credentials as OAuthCredentials

    _GCP_AVAILABLE = True
except ImportError:
    _GCP_AVAILABLE = False

logger = logging.getLogger(__name__)

import re

_ZONE_PATTERN = re.compile(r"^[a-z]+-[a-z]+\d+-[a-z]$")


def _gcp_project() -> str:
    """Read GCP project ID from environment at call time, not import time."""
    return os.environ.get("GCP_PROJECT_ID", "")


def _gcp_zone() -> str:
    """Read GCP zone from environment at call time, not import time."""
    return os.environ.get("GCP_ZONE", "us-central1-a")

# Machine types allowed for instance creation (cost guardrail).
# Override via ALLOWED_MACHINE_TYPES env var (comma-separated).
ALLOWED_MACHINE_TYPES = set(
    os.environ.get(
        "ALLOWED_MACHINE_TYPES",
        "e2-micro,e2-small,e2-medium,e2-standard-2,e2-standard-4,n2-standard-2,n2-standard-4",
    ).split(",")
)

server = Server("compute-server")

# ---------------------------------------------------------------------------
# Auto-refreshing GCP client.
# vault-agent sidecar re-renders /vault/secrets/gcp-token when the Vault
# lease expires. TokenRefresher watches the file mtime and we recreate
# the client when the token changes. Thread-safe for asyncio.to_thread().
# ---------------------------------------------------------------------------

from vault_mcp_agents.mcp._token_refresh import TokenRefresher

_refresher = TokenRefresher()
_instance_client_cached = None
_active_token: str | None = None
_client_lock = threading.Lock()


def _validate_required(arguments: dict[str, Any], *keys: str) -> str | None:
    """Return an error message if any required key is missing, else None."""
    missing = [k for k in keys if not arguments.get(k)]
    if missing:
        return f"Missing required arguments: {', '.join(missing)}"
    return None


def _instance_client():
    """Return a GCE InstancesClient, refreshing if the token file changed."""
    global _instance_client_cached, _active_token
    with _client_lock:
        token = _refresher.get_token()
        if token != _active_token:
            if token and _GCP_AVAILABLE:
                creds = OAuthCredentials(token=token)
                _instance_client_cached = compute_v1.InstancesClient(credentials=creds)
            else:
                _instance_client_cached = compute_v1.InstancesClient()
            _active_token = token
            logger.info("GCP client refreshed (token changed)")
        return _instance_client_cached


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_instances",
            description="List all GCE VM instances in the project and zone.",
            inputSchema={
                "type": "object",
                "properties": {
                    "zone": {
                        "type": "string",
                        "description": "GCP zone (defaults to GCP_ZONE env var or us-central1-a)",
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="get_instance",
            description="Get details for a specific GCE VM instance.",
            inputSchema={
                "type": "object",
                "properties": {
                    "instance": {"type": "string", "description": "Instance name"},
                    "zone": {"type": "string", "description": "GCP zone"},
                },
                "required": ["instance"],
            },
        ),
        types.Tool(
            name="start_instance",
            description="Start a stopped GCE VM instance.",
            inputSchema={
                "type": "object",
                "properties": {
                    "instance": {"type": "string", "description": "Instance name"},
                    "zone": {"type": "string", "description": "GCP zone"},
                },
                "required": ["instance"],
            },
        ),
        types.Tool(
            name="stop_instance",
            description="Stop a running GCE VM instance.",
            inputSchema={
                "type": "object",
                "properties": {
                    "instance": {"type": "string", "description": "Instance name"},
                    "zone": {"type": "string", "description": "GCP zone"},
                },
                "required": ["instance"],
            },
        ),
        types.Tool(
            name="create_instance",
            description=(
                f"Create a new GCE VM instance with a Debian disk image. "
                f"Allowed machine types: {', '.join(sorted(ALLOWED_MACHINE_TYPES))}."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "instance": {"type": "string", "description": "Instance name"},
                    "machine_type": {
                        "type": "string",
                        "description": "Machine type (default: e2-micro)",
                        "default": "e2-micro",
                    },
                    "zone": {"type": "string", "description": "GCP zone"},
                },
                "required": ["instance"],
            },
        ),
        types.Tool(
            name="delete_instance",
            description="Delete a GCE VM instance.",
            inputSchema={
                "type": "object",
                "properties": {
                    "instance": {"type": "string", "description": "Instance name"},
                    "zone": {"type": "string", "description": "GCP zone"},
                },
                "required": ["instance"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[types.TextContent]:
    zone = arguments.get("zone") or _gcp_zone()
    project = _gcp_project()

    # Validate zone format (e.g. us-central1-a)
    if not _ZONE_PATTERN.match(zone):
        return [types.TextContent(type="text", text=f"Error: invalid zone format '{zone}'. Expected format: region-zone (e.g. us-central1-a)")]

    logger.info("Tool called: %s", name)
    try:
        if name == "list_instances":
            return await _list_instances(project, zone)
        if name == "get_instance":
            if err := _validate_required(arguments, "instance"):
                return [types.TextContent(type="text", text=err)]
            return await _get_instance(project, zone, arguments["instance"])
        if name == "start_instance":
            if err := _validate_required(arguments, "instance"):
                return [types.TextContent(type="text", text=err)]
            return await _start_instance(project, zone, arguments["instance"])
        if name == "stop_instance":
            if err := _validate_required(arguments, "instance"):
                return [types.TextContent(type="text", text=err)]
            return await _stop_instance(project, zone, arguments["instance"])
        if name == "create_instance":
            if err := _validate_required(arguments, "instance"):
                return [types.TextContent(type="text", text=err)]
            return await _create_instance(
                project,
                zone,
                arguments["instance"],
                arguments.get("machine_type", "e2-micro"),
            )
        if name == "delete_instance":
            if err := _validate_required(arguments, "instance"):
                return [types.TextContent(type="text", text=err)]
            return await _delete_instance(project, zone, arguments["instance"])
        return [types.TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as exc:
        logger.exception("Tool %s failed", name)
        return [types.TextContent(type="text", text=f"Error: operation failed ({type(exc).__name__})")]


def _instance_summary(inst: Any) -> dict:
    return {
        "name": inst.name,
        "status": inst.status,
        "machine_type": inst.machine_type.split("/")[-1] if inst.machine_type else "",
        "zone": inst.zone.split("/")[-1] if inst.zone else "",
        "network_ip": (
            inst.network_interfaces[0].network_i_p
            if inst.network_interfaces
            else ""
        ),
        "creation_timestamp": inst.creation_timestamp,
    }


async def _list_instances(project: str, zone: str) -> list[types.TextContent]:
    client = _instance_client()
    instances = await asyncio.to_thread(lambda: list(client.list(project=project, zone=zone)))
    summary = [_instance_summary(i) for i in instances]
    return [types.TextContent(type="text", text=json.dumps(summary, indent=2, default=str))]


async def _get_instance(project: str, zone: str, instance: str) -> list[types.TextContent]:
    client = _instance_client()
    inst = await asyncio.to_thread(client.get, project=project, zone=zone, instance=instance)
    return [types.TextContent(type="text", text=json.dumps(_instance_summary(inst), indent=2, default=str))]


async def _start_instance(project: str, zone: str, instance: str) -> list[types.TextContent]:
    client = _instance_client()
    op = await asyncio.to_thread(client.start, project=project, zone=zone, instance=instance)
    return [types.TextContent(type="text", text=f"Start operation submitted: {op.name}")]


async def _stop_instance(project: str, zone: str, instance: str) -> list[types.TextContent]:
    client = _instance_client()
    op = await asyncio.to_thread(client.stop, project=project, zone=zone, instance=instance)
    return [types.TextContent(type="text", text=f"Stop operation submitted: {op.name}")]


async def _create_instance(
    project: str, zone: str, instance: str, machine_type: str
) -> list[types.TextContent]:
    if machine_type not in ALLOWED_MACHINE_TYPES:
        return [types.TextContent(
            type="text",
            text=f"Error: machine type '{machine_type}' is not allowed. "
                 f"Permitted types: {', '.join(sorted(ALLOWED_MACHINE_TYPES))}",
        )]

    client = _instance_client()
    machine_type_url = f"zones/{zone}/machineTypes/{machine_type}"
    disk = compute_v1.AttachedDisk(
        boot=True,
        auto_delete=True,
        initialize_params=compute_v1.AttachedDiskInitializeParams(
            source_image="projects/debian-cloud/global/images/family/debian-12"
        ),
    )
    network_interface = compute_v1.NetworkInterface(name="global/networks/default")
    instance_resource = compute_v1.Instance(
        name=instance,
        machine_type=machine_type_url,
        disks=[disk],
        network_interfaces=[network_interface],
    )
    op = await asyncio.to_thread(client.insert, project=project, zone=zone, instance_resource=instance_resource)
    return [types.TextContent(type="text", text=f"Create operation submitted: {op.name}")]


async def _delete_instance(project: str, zone: str, instance: str) -> list[types.TextContent]:
    client = _instance_client()
    op = await asyncio.to_thread(client.delete, project=project, zone=zone, instance=instance)
    return [types.TextContent(type="text", text=f"Delete operation submitted: {op.name}")]


async def _run_stdio() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


def _run_sse() -> None:
    from starlette.applications import Starlette
    from starlette.routing import Mount, Route
    import uvicorn

    sse_transport = SseServerTransport("/messages/")

    async def handle_sse(request):
        async with sse_transport.connect_sse(
            request.scope, request.receive, request._send
        ) as (read_stream, write_stream):
            await server.run(
                read_stream,
                write_stream,
                server.create_initialization_options(),
            )

    app = Starlette(
        routes=[
            Route("/sse", endpoint=handle_sse),
            Mount("/messages/", app=sse_transport.handle_post_message),
        ],
    )

    port = int(os.environ.get("MCP_PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    if not _gcp_project():
        logger.error("GCP_PROJECT_ID environment variable is required")
        sys.exit(1)

    transport = os.environ.get("MCP_TRANSPORT", "stdio")
    if transport == "sse":
        _run_sse()
    else:
        asyncio.run(_run_stdio())
