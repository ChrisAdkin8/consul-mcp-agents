"""MCP server exposing GCS and BigQuery tools.

Run as:
    python -m vault_mcp_agents.mcp.data_server
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

# GCP imports — actual calls only happen when tools are invoked
try:
    from google.cloud import bigquery, storage
    from google.oauth2.credentials import Credentials as OAuthCredentials

    _GCP_AVAILABLE = True
except ImportError:
    _GCP_AVAILABLE = False

# SQL validation — AST-based statement type checking
try:
    import sqlglot
    import sqlglot.errors
    import sqlglot.expressions as exp

    _SQLGLOT_AVAILABLE = True
except ImportError:
    _SQLGLOT_AVAILABLE = False

logger = logging.getLogger(__name__)

def _gcp_project() -> str:
    """Read GCP project ID from environment at call time, not import time."""
    return os.environ.get("GCP_PROJECT_ID", "")

# BigQuery cost guardrail: max bytes billed per query (default 1 GB)
_MAX_BYTES_BILLED = int(os.environ.get("BQ_MAX_BYTES_BILLED", str(1 << 30)))

# Statement types allowed through the SQL filter (read-only)
_ALLOWED_SQL_TYPES = (exp.Select,) if _SQLGLOT_AVAILABLE else ()

server = Server("data-server")

# ---------------------------------------------------------------------------
# Auto-refreshing GCP clients.
# vault-agent sidecar re-renders /vault/secrets/gcp-token when the Vault
# lease expires. TokenRefresher watches the file mtime and we recreate
# clients when the token changes. Thread-safe for asyncio.to_thread().
# ---------------------------------------------------------------------------

from vault_mcp_agents.mcp._token_refresh import TokenRefresher

_refresher = TokenRefresher()
_storage_client_cached = None
_bigquery_client_cached = None
_active_token: str | None = None
_client_lock = threading.Lock()


def _validate_required(arguments: dict[str, Any], *keys: str) -> str | None:
    """Return an error message if any required key is missing, else None."""
    missing = [k for k in keys if not arguments.get(k)]
    if missing:
        return f"Missing required arguments: {', '.join(missing)}"
    return None


def _refresh_clients_if_needed() -> None:
    """Recreate GCP clients if the token has changed on disk."""
    global _storage_client_cached, _bigquery_client_cached, _active_token
    token = _refresher.get_token()
    if token != _active_token:
        creds = OAuthCredentials(token=token) if (token and _GCP_AVAILABLE) else None
        _storage_client_cached = storage.Client(project=_gcp_project(), credentials=creds)
        _bigquery_client_cached = bigquery.Client(project=_gcp_project(), credentials=creds)
        _active_token = token
        logger.info("GCP clients refreshed (token changed)")


def _storage_client():
    """Return a GCS Storage client, refreshing if the token file changed."""
    with _client_lock:
        _refresh_clients_if_needed()
        return _storage_client_cached


def _bigquery_client():
    """Return a BigQuery client, refreshing if the token file changed."""
    with _client_lock:
        _refresh_clients_if_needed()
        return _bigquery_client_cached


def _is_read_only_query(query: str) -> bool:
    """Check if a SQL query is read-only using AST parsing (sqlglot).

    Returns True only if every statement in the query is a SELECT.
    Rejects DML (INSERT, UPDATE, DELETE, MERGE) and DDL (CREATE, ALTER, DROP, TRUNCATE).

    Unlike regex, this correctly handles:
    - Keywords inside string literals: SELECT 'DROP TABLE' → allowed
    - Keywords inside comments: SELECT /* INSERT */ 1 → allowed
    - Multi-statement injection: SELECT 1; DROP TABLE t → blocked
    """
    if not _SQLGLOT_AVAILABLE:
        # Fallback: reject any query containing DML/DDL keywords (conservative)
        import re
        pattern = re.compile(
            r"\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|MERGE)\b",
            re.IGNORECASE,
        )
        return not pattern.search(query)

    try:
        statements = sqlglot.parse(query, error_level=sqlglot.ErrorLevel.RAISE)
        if not statements:
            return False
        return all(
            isinstance(stmt, _ALLOWED_SQL_TYPES)
            for stmt in statements
            if stmt is not None
        )
    except sqlglot.errors.ParseError:
        # Unparseable SQL → reject to be safe
        return False


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_buckets",
            description="List all GCS buckets in the configured GCP project.",
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
        types.Tool(
            name="read_object",
            description="Read the contents of a GCS object and return it as text.",
            inputSchema={
                "type": "object",
                "properties": {
                    "bucket": {"type": "string", "description": "GCS bucket name"},
                    "object": {"type": "string", "description": "GCS object path"},
                },
                "required": ["bucket", "object"],
            },
        ),
        types.Tool(
            name="write_object",
            description="Write text content to a GCS object.",
            inputSchema={
                "type": "object",
                "properties": {
                    "bucket": {"type": "string", "description": "GCS bucket name"},
                    "object": {"type": "string", "description": "GCS object path"},
                    "content": {"type": "string", "description": "Text content to write"},
                    "content_type": {
                        "type": "string",
                        "description": "MIME content type (default: text/plain)",
                        "default": "text/plain",
                    },
                },
                "required": ["bucket", "object", "content"],
            },
        ),
        types.Tool(
            name="delete_object",
            description="Delete a GCS object.",
            inputSchema={
                "type": "object",
                "properties": {
                    "bucket": {"type": "string", "description": "GCS bucket name"},
                    "object": {"type": "string", "description": "GCS object path"},
                },
                "required": ["bucket", "object"],
            },
        ),
        types.Tool(
            name="list_datasets",
            description="List all BigQuery datasets in the configured GCP project.",
            inputSchema={"type": "object", "properties": {}, "required": []},
        ),
        types.Tool(
            name="create_dataset",
            description="Create a new BigQuery dataset.",
            inputSchema={
                "type": "object",
                "properties": {
                    "dataset_id": {"type": "string", "description": "Dataset ID"},
                    "location": {
                        "type": "string",
                        "description": "Dataset location (default: US)",
                        "default": "US",
                    },
                },
                "required": ["dataset_id"],
            },
        ),
        types.Tool(
            name="query_bigquery",
            description="Run a read-only SQL query on BigQuery and return results as JSON. DML/DDL statements are blocked.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "SQL query to execute (SELECT only)"},
                    "max_results": {
                        "type": "integer",
                        "description": "Maximum number of rows to return (default: 100)",
                        "default": 100,
                    },
                },
                "required": ["query"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[types.TextContent]:
    logger.info("Tool called: %s", name)
    try:
        if name == "list_buckets":
            return await _list_buckets()
        if name == "read_object":
            if err := _validate_required(arguments, "bucket", "object"):
                return [types.TextContent(type="text", text=err)]
            return await _read_object(arguments["bucket"], arguments["object"])
        if name == "write_object":
            if err := _validate_required(arguments, "bucket", "object", "content"):
                return [types.TextContent(type="text", text=err)]
            return await _write_object(
                arguments["bucket"],
                arguments["object"],
                arguments["content"],
                arguments.get("content_type", "text/plain"),
            )
        if name == "delete_object":
            if err := _validate_required(arguments, "bucket", "object"):
                return [types.TextContent(type="text", text=err)]
            return await _delete_object(arguments["bucket"], arguments["object"])
        if name == "list_datasets":
            return await _list_datasets()
        if name == "create_dataset":
            if err := _validate_required(arguments, "dataset_id"):
                return [types.TextContent(type="text", text=err)]
            return await _create_dataset(
                arguments["dataset_id"],
                arguments.get("location", "US"),
            )
        if name == "query_bigquery":
            if err := _validate_required(arguments, "query"):
                return [types.TextContent(type="text", text=err)]
            return await _query_bigquery(
                arguments["query"],
                int(arguments.get("max_results", _DEFAULT_MAX_RESULTS)),
            )
        return [types.TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as exc:
        logger.exception("Tool %s failed", name)
        return [types.TextContent(type="text", text=f"Error: operation failed ({type(exc).__name__})")]


async def _list_buckets() -> list[types.TextContent]:
    client = _storage_client()
    buckets = await asyncio.to_thread(lambda: [b.name for b in client.list_buckets()])
    return [types.TextContent(type="text", text=json.dumps(buckets, indent=2))]


async def _read_object(bucket: str, obj: str) -> list[types.TextContent]:
    client = _storage_client()
    blob = client.bucket(bucket).blob(obj)
    content = await asyncio.to_thread(blob.download_as_text)
    return [types.TextContent(type="text", text=content)]


async def _write_object(
    bucket: str, obj: str, content: str, content_type: str
) -> list[types.TextContent]:
    client = _storage_client()
    blob = client.bucket(bucket).blob(obj)
    await asyncio.to_thread(blob.upload_from_string, content, content_type)
    return [
        types.TextContent(
            type="text",
            text=f"Written {len(content)} bytes to gs://{bucket}/{obj}",
        )
    ]


async def _delete_object(bucket: str, obj: str) -> list[types.TextContent]:
    client = _storage_client()
    await asyncio.to_thread(client.bucket(bucket).blob(obj).delete)
    return [types.TextContent(type="text", text=f"Deleted gs://{bucket}/{obj}")]


async def _list_datasets() -> list[types.TextContent]:
    client = _bigquery_client()
    datasets = await asyncio.to_thread(lambda: [d.dataset_id for d in client.list_datasets()])
    return [types.TextContent(type="text", text=json.dumps(datasets, indent=2))]


async def _create_dataset(dataset_id: str, location: str) -> list[types.TextContent]:
    client = _bigquery_client()
    dataset = bigquery.Dataset(f"{client.project}.{dataset_id}")
    dataset.location = location
    await asyncio.to_thread(client.create_dataset, dataset, True)
    return [types.TextContent(type="text", text=f"Dataset '{dataset_id}' created in {location}")]


_DEFAULT_MAX_RESULTS = int(os.environ.get("BQ_MAX_RESULTS", "100"))


async def _query_bigquery(query: str, max_results: int) -> list[types.TextContent]:
    # Block DML/DDL statements using AST-based validation
    if not _is_read_only_query(query):
        return [types.TextContent(type="text", text="Error: only SELECT queries are allowed. DML/DDL statements (INSERT, UPDATE, DELETE, DROP, etc.) are blocked.")]

    client = _bigquery_client()
    job_config = bigquery.QueryJobConfig(
        maximum_bytes_billed=_MAX_BYTES_BILLED,
    )
    query_job = await asyncio.to_thread(client.query, query, job_config=job_config)
    rows = await asyncio.to_thread(lambda: list(query_job.result(max_results=max_results)))
    result = [dict(row) for row in rows]
    return [types.TextContent(type="text", text=json.dumps(result, indent=2, default=str))]


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
