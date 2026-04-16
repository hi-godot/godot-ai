"""Godot AI — production-grade Godot MCP server."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _pkg_version

try:
    __version__ = _pkg_version("godot-ai")
except PackageNotFoundError:
    # In-tree / unbuilt source tree (e.g. running pytest from a checkout
    # without an editable install). Package metadata is only available after
    # install, so fall back to a placeholder rather than crashing.
    __version__ = "0+unknown"


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Godot AI server")
    parser.add_argument(
        "--version",
        action="version",
        version=f"godot-ai {__version__}",
    )
    parser.add_argument(
        "--transport",
        choices=["stdio", "sse", "streamable-http"],
        default="stdio",
        help="MCP transport (default: stdio)",
    )
    parser.add_argument(
        "--port", type=int, default=8000, help="HTTP port for sse/streamable-http (default: 8000)"
    )
    parser.add_argument(
        "--ws-port", type=int, default=9500, help="WebSocket port for Godot plugin (default: 9500)"
    )
    parser.add_argument(
        "--reload",
        action="store_true",
        help="Auto-restart on source changes (dev mode, HTTP transports only)",
    )
    args = parser.parse_args(argv)

    if args.reload and args.transport in ("sse", "streamable-http"):
        from godot_ai.asgi import run_with_reload

        run_with_reload(transport=args.transport, port=args.port, ws_port=args.ws_port)
        return

    from godot_ai.server import create_server

    server = create_server(ws_port=args.ws_port)

    transport_kwargs = {}
    if args.transport in ("sse", "streamable-http"):
        transport_kwargs["port"] = args.port

    server.run(transport=args.transport, **transport_kwargs)
