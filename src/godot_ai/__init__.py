"""Godot AI — production-grade Godot MCP server."""

from __future__ import annotations

import argparse
import tomllib
from collections.abc import Sequence
from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _pkg_version
from pathlib import Path


def _resolve_version(package_file: str | Path) -> str:
    ## Try pyproject.toml first. Editable installs pin the dist-info
    ## METADATA at install time, so `importlib.metadata.version("godot-ai")`
    ## returns whatever the version was when the venv was created — e.g.
    ## "0.0.1" on a venv made before the first release bump. Reading the
    ## live pyproject keeps `godot_ai.__version__` and `session_list`'s
    ## `server_version` honest against the current source tree.
    ##
    ## Order matters: dev checkouts have both a pyproject and dist-info;
    ## wheel installs only have dist-info. Pyproject wins when both exist.
    pyproject = Path(package_file).resolve().parent.parent.parent / "pyproject.toml"
    if pyproject.is_file():
        try:
            with pyproject.open("rb") as f:
                data = tomllib.load(f)
            version = data.get("project", {}).get("version")
            if isinstance(version, str) and version:
                return version
        except (OSError, tomllib.TOMLDecodeError):
            pass
    try:
        return _pkg_version("godot-ai")
    except PackageNotFoundError:
        return "0+unknown"


__version__ = _resolve_version(__file__)


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
    parser.add_argument(
        "--pid-file",
        default=None,
        help=(
            "Write this process's PID to the given path on startup, unlink on "
            "clean exit. The Godot plugin uses this to kill the real server "
            "process when a launcher (uvx) PID would be unreliable."
        ),
    )
    args = parser.parse_args(argv)

    from godot_ai.runtime_info import install_pid_file

    install_pid_file(args.pid_file)

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
