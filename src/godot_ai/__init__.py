"""Godot AI — production-grade Godot MCP server."""

from __future__ import annotations

import argparse
import os
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
    parser.add_argument(
        "--owner-pid",
        type=int,
        default=None,
        help=(
            "PID of the Godot editor that spawned this server. When set, the "
            "server self-terminates if that editor dies (crash / hard-kill with "
            "no clean stop_server) and no other editor has adopted it, so a "
            "detached server can't orphan onto the port. Omitted for externally "
            "managed servers (CI, manual --reload)."
        ),
    )
    parser.add_argument(
        "--allow-host",
        action="append",
        metavar="CIDR",
        default=None,
        help=(
            "Expose the server to a named LAN range for remote agents (issue "
            "#421). Takes a CIDR or bare IP (repeatable, or comma-separated), "
            "e.g. --allow-host 192.168.1.0/24. When set, both transports bind "
            "off loopback and access is gated on the real socket peer address "
            "(unforgeable) falling inside these networks ONLY — the Host header "
            "is range-checked too but is not the authority, and browser Origin "
            "/ Sec-Fetch-Site checks stay on. Omit for the default loopback-only "
            "behavior. Prefer an SSH tunnel / Tailscale on untrusted networks; "
            "only name ranges you trust."
        ),
    )
    parser.add_argument(
        "--exclude-domains",
        default="",
        help=(
            "Comma-separated list of tool domains to drop from registration "
            "(e.g. 'audio,particle,theme'). Core tools (editor_state, "
            "scene_get_hierarchy, node_get_properties, session_list, "
            "session_activate) are always registered. Use this to fit under "
            "a client's hard tool-count cap (Antigravity limits to 100)."
        ),
    )
    args = parser.parse_args(argv)

    from godot_ai.tools.domains import parse_exclude_list

    try:
        exclude_domains = parse_exclude_list(args.exclude_domains)
    except ValueError as exc:
        parser.error(str(exc))

    ## #421: parse --allow-host CIDRs. A typo here fails loudly at startup
    ## rather than silently binding loopback-only (or worse, wide open).
    from godot_ai.transport.origin_guard import bind_host_for_networks, parse_allow_hosts

    try:
        allow_host_networks = parse_allow_hosts(args.allow_host or [])
    except ValueError as exc:
        parser.error(str(exc))

    ## Widen the HTTP bind off loopback only when an allowlist is named. The
    ## DNS-rebinding guard still gates every request by the CIDR(s); binding
    ## off loopback without the guard would be the footgun this flag avoids.
    if allow_host_networks and args.transport in ("sse", "streamable-http"):
        import fastmcp

        fastmcp.settings.host = bind_host_for_networks(allow_host_networks)

    from godot_ai.runtime_info import install_pid_file

    install_pid_file(args.pid_file)

    ## The plugin passes the owning editor's PID via GODOT_AI_OWNER_PID (env,
    ## not a flag, so older servers ignore it). An explicit --owner-pid wins
    ## for tests / manual use.
    owner_pid = args.owner_pid
    if owner_pid is None:
        env_owner = os.environ.get("GODOT_AI_OWNER_PID", "").strip()
        if env_owner:
            try:
                owner_pid = int(env_owner)
            except ValueError:
                owner_pid = None

    if args.reload and args.transport in ("sse", "streamable-http"):
        from godot_ai.asgi import run_with_reload

        run_with_reload(
            transport=args.transport,
            port=args.port,
            ws_port=args.ws_port,
            exclude_domains=exclude_domains,
            allow_host_networks=allow_host_networks,
        )
        return

    from godot_ai.server import create_server

    server = create_server(
        ws_port=args.ws_port,
        exclude_domains=exclude_domains,
        owner_pid=owner_pid,
        allow_host_networks=allow_host_networks,
    )

    transport_kwargs = {}
    if args.transport in ("sse", "streamable-http"):
        transport_kwargs["port"] = args.port

    server.run(transport=args.transport, **transport_kwargs)
