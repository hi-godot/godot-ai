"""Godot AI — production-grade Godot MCP server."""

from __future__ import annotations

import argparse
import errno
import os
import socket
import sys
import time
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


## #647: distinctive exit code for "a port we need is held by another
## process" — mirrors Linux's EADDRINUSE errno so it reads naturally in
## logs, and is distinguishable from uvicorn's generic exit(1) so the Godot
## plugin (and CI) can recognize a port conflict from the exit alone.
EXIT_PORT_IN_USE = 98


def _is_eaddrinuse(exc: OSError) -> bool:
    ## #647: POSIX raises errno.EADDRINUSE (48 macOS / 98 Linux). Windows
    ## surfaces WSAEADDRINUSE 10048 — usually mapped onto errno.EADDRINUSE
    ## by CPython, but check winerror and the raw value too so no platform
    ## variant slips through to a generic traceback.
    return (
        exc.errno == errno.EADDRINUSE
        or exc.errno == 10048
        or getattr(exc, "winerror", None) == 10048
    )


def preflight_check_port(
    port: int, *, label: str, setting: str, host: str = "127.0.0.1"
) -> socket.socket | None:
    """Exit with a distinctive stderr message + exit code when `port` is taken.

    Returns the bound, listening socket when the plugin asked this launch to
    wait for the port (see below): the caller hands it to the real server so
    the port is never free between the wait ending and the server listening.
    Returns ``None`` on the ordinary fail-fast path.

    #647: when a foreign process (e.g. a docker container) already owns the
    HTTP or WebSocket port, uvicorn/websockets fail with an opaque bind error
    (or, for the WS port, a warning that leaves the server half-alive). Probe
    the bind up front and fail fast with a message humans can act on and an
    exit code (EXIT_PORT_IN_USE) the Godot plugin can recognize.

    Ports that fail to bind for other reasons (EACCES, Windows winnat
    exclusion ranges) keep their existing downstream failure modes.
    """
    ## --allow-host can resolve an IPv6 bind host ("::") via
    ## bind_host_for_networks(); an AF_INET socket can't bind those, so pick
    ## the family from the host (Copilot review on #647's PR).
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    ## The plugin sets this only when it launches this server to replace a
    ## godot-ai backend that still holds the port and kills that backend
    ## right after: the port then goes from the old backend to this process
    ## within one retry, before an attach bridge that is polling for a free
    ## port can spawn another backend of its own. Every other launch keeps
    ## the fail-fast contract below (#647).
    wait_seconds = _wait_for_port_seconds()
    wait_deadline = time.monotonic() + wait_seconds
    while True:
        sock = socket.socket(family, socket.SOCK_STREAM)
        keep = False
        try:
            if os.name != "nt":
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind((host, port))
                if wait_seconds <= 0:
                    return None
                ## Hold the port from this instant: a bridge polling for a
                ## free port to spawn its own backend never sees one.
                sock.listen(128)
                keep = True
                return sock
            except OSError as exc:
                if _is_eaddrinuse(exc) and time.monotonic() < wait_deadline:
                    continue
                raise
        except OSError as exc:
            if not _is_eaddrinuse(exc):
                ## Any other bind failure (EACCES, EADDRNOTAVAIL, winnat
                ## exclusion ranges, exotic address families) is NOT the
                ## condition this preflight exists to catch: let the real
                ## server startup produce its existing failure mode.
                return
            print(
                    f"godot-ai: {label} port {port} is already in use by another "
                    f"process. Stop it or change the port ({setting} in Godot "
                    "Editor Settings).",
                    file=sys.stderr,
                )
            raise SystemExit(EXIT_PORT_IN_USE) from exc
        finally:
            if not keep:
                sock.close()
                if time.monotonic() < wait_deadline:
                    time.sleep(WAIT_FOR_PORT_RETRY_SECONDS)


WAIT_FOR_PORT_ENV = "GODOT_AI_WAIT_FOR_PORT_MS"
WAIT_FOR_PORT_RETRY_SECONDS = 0.05
WAIT_FOR_PORT_MAX_SECONDS = 30.0


def _wait_for_port_seconds() -> float:
    raw = os.environ.get(WAIT_FOR_PORT_ENV, "").strip()
    if not raw:
        return 0.0
    try:
        return min(max(int(raw), 0) / 1000.0, WAIT_FOR_PORT_MAX_SECONDS)
    except ValueError:
        return 0.0


def main(argv: Sequence[str] | None = None) -> None:
    from godot_ai.runtime_dependencies import verify_runtime_dependencies

    verify_runtime_dependencies()
    effective_argv = list(sys.argv[1:] if argv is None else argv)
    if effective_argv[:1] == ["attach"]:
        from godot_ai.attach.main import main as attach_main

        attach_main(effective_argv[1:])
        return

    parser = argparse.ArgumentParser(
        description="Godot AI server",
        epilog=(
            "Client-owned bridge: godot-ai attach [--port PORT] [--ws-port PORT] "
            "[--exclude-domains LIST]. Run 'godot-ai attach --help' for details."
        ),
    )
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
            "managed servers (CI, manual --reload, attach-owned backends). "
            "Compatible external servers are adopted without managed process "
            "ownership and are not killed on normal editor exit."
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
            "scene_get_hierarchy, node_get_properties, "
            "session_activate) are always registered. Use this to fit under "
            "a client's hard tool-count cap (Antigravity limits to 100)."
        ),
    )
    args = parser.parse_args(effective_argv)

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

    ## v4 has one stdio architecture: the client-owned attach bridge talks to
    ## the shared authenticated HTTP backend. It never constructs an in-process
    ## WebSocket server with an unpublishable HTTP identity.
    if args.transport == "stdio":
        if args.reload:
            parser.error("--reload requires an HTTP transport")
        if allow_host_networks:
            parser.error("--allow-host requires an HTTP transport")
        if args.owner_pid is not None:
            parser.error("--owner-pid requires an HTTP transport")
        if args.pid_file is not None:
            parser.error("--pid-file requires an HTTP transport")
        from godot_ai.attach.main import main as attach_main

        attach_args = ["--port", str(args.port), "--ws-port", str(args.ws_port)]
        if exclude_domains:
            attach_args.extend(("--exclude-domains", ",".join(sorted(exclude_domains))))
        attach_main(attach_args)
        return

    from godot_ai.transport.capability import launch_capabilities_from_env

    try:
        capabilities = launch_capabilities_from_env()
    except ValueError as exc:
        parser.error(str(exc))

    ## Widen the HTTP bind off loopback only when an allowlist is named. The
    ## DNS-rebinding guard still gates every request by the CIDR(s); binding
    ## off loopback without the guard would be the footgun this flag avoids.
    if allow_host_networks and args.transport in ("sse", "streamable-http"):
        import fastmcp

        fastmcp.settings.host = bind_host_for_networks(allow_host_networks)

    ## #647: fail fast — with a recognizable message and exit code — when a
    ## foreign process holds a port we need, instead of uvicorn's opaque bind
    ## error (HTTP) or a half-ready HTTP process without its editor bridge.
    held_http = held_ws = None
    if args.transport in ("sse", "streamable-http"):
        http_host = (
            bind_host_for_networks(allow_host_networks) if allow_host_networks else "127.0.0.1"
        )
        held_http = preflight_check_port(
            args.port, label="HTTP", setting="godot_ai/http_port", host=http_host
        )
        held_ws = preflight_check_port(args.ws_port, label="WebSocket", setting="godot_ai/ws_port")

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
            capabilities=capabilities,
        )
        return

    from godot_ai.server import create_server

    server = create_server(
        capabilities=capabilities,
        http_port=args.port,
        ws_port=args.ws_port,
        exclude_domains=exclude_domains,
        owner_pid=owner_pid,
        allow_host_networks=allow_host_networks,
        ws_socket=held_ws,
    )

    transport_kwargs = {}
    if held_http is not None:
        transport_kwargs["sockets"] = [held_http]
    if args.transport in ("sse", "streamable-http"):
        from godot_ai.asgi import hardened_uvicorn_config, http_access_log_enabled

        transport_kwargs["port"] = args.port
        ## Per-request access-log lines are opt-in (GODOT_AI_HTTP_ACCESS_LOG);
        ## see the rationale on HTTP_ACCESS_LOG_ENV in asgi.py. FastMCP still
        ## sets uvicorn's log_level itself — this dict carries neither
        ## `log_level` nor `log_config`, which would suppress that default.
        transport_kwargs["uvicorn_config"] = hardened_uvicorn_config(
            access_log=http_access_log_enabled()
        )

    server.run(transport=args.transport, **transport_kwargs)
