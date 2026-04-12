"""ASGI factory and dev runner for reloadable HTTP transports."""

from __future__ import annotations

import os
from pathlib import Path

import fastmcp
import uvicorn

DEV_TRANSPORT_ENV = "GODOT_AI_DEV_TRANSPORT"
DEV_WS_PORT_ENV = "GODOT_AI_DEV_WS_PORT"
RELOADABLE_TRANSPORTS = {"sse", "streamable-http"}


def _get_dev_transport() -> str:
    transport = os.environ.get(DEV_TRANSPORT_ENV, "streamable-http")
    if transport not in RELOADABLE_TRANSPORTS:
        raise ValueError(f"Unsupported dev transport: {transport}")
    return transport


def _get_dev_ws_port() -> int:
    raw = os.environ.get(DEV_WS_PORT_ENV, "9500")
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"Invalid {DEV_WS_PORT_ENV}: {raw}") from exc


def create_app():
    """Create the FastMCP ASGI app for uvicorn's reload supervisor."""
    from godot_ai.server import create_server

    server = create_server(ws_port=_get_dev_ws_port())
    return server.http_app(transport=_get_dev_transport())


def run_with_reload(*, transport: str, port: int, ws_port: int) -> None:
    """Run the HTTP transport through uvicorn's supported reload path."""
    if transport not in RELOADABLE_TRANSPORTS:
        raise ValueError(f"Reload is only supported for HTTP transports, got {transport}")

    os.environ[DEV_TRANSPORT_ENV] = transport
    os.environ[DEV_WS_PORT_ENV] = str(ws_port)

    src_dir = str(Path(__file__).resolve().parent.parent)
    uvicorn.run(
        "godot_ai.asgi:create_app",
        factory=True,
        host=fastmcp.settings.host,
        port=port,
        log_level=fastmcp.settings.log_level.lower(),
        timeout_graceful_shutdown=2,
        lifespan="on",
        ws="websockets-sansio",
        reload=True,
        reload_dirs=[src_dir],
    )
