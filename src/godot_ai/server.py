"""FastMCP server — the main entry point for Godot AI."""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections.abc import AsyncIterator, Iterable, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

import godot_ai as _godot_ai_pkg
from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.asgi import StaleMcpSessionDiagnosticMiddleware
from godot_ai.attach.lease import LeaseInstanceMismatch, LeaseNotFound, LeaseRegistry
from godot_ai.godot_client.client import GodotClient
from godot_ai.middleware import (
    FoldFlatManageParams,
    HintOpTypoOnManage,
    ParseStringifiedParams,
    PreserveGodotCommandErrorData,
    StripClientWrapperKwargs,
)
from godot_ai.orphan_reaper import (
    boot_grace_from_env,
    idle_grace_from_env,
    poll_seconds_from_env,
    should_arm_attach_idle_exit,
    should_arm_idle_exit,
    should_arm_reaper,
    watch_idle,
    watch_owner,
)
from godot_ai.protocol.attach import (
    ATTACH_PROTOCOL_VERSION,
    SERVER_INSTANCE_ID,
    owner_type_from_env,
    tool_catalog_hash,
)
from godot_ai.resources.classes import register_class_resources
from godot_ai.resources.editor import register_editor_resources
from godot_ai.resources.library import register_library_resources
from godot_ai.resources.nodes import register_node_resources
from godot_ai.resources.project import register_project_resources
from godot_ai.resources.scenes import register_scene_resources
from godot_ai.resources.scripts import register_script_resources
from godot_ai.resources.sessions import register_session_resources
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.telemetry import (
    MilestoneType,
    RecordType,
    install_fastmcp_wraps,
    record_milestone,
    record_telemetry,
    shutdown_if_initialized,
)
from godot_ai.tools.animation import register_animation_tools
from godot_ai.tools.api import register_api_tools
from godot_ai.tools.audio import register_audio_tools
from godot_ai.tools.autoload import register_autoload_tools
from godot_ai.tools.batch import register_batch_tools
from godot_ai.tools.camera import register_camera_tools
from godot_ai.tools.client import register_client_tools
from godot_ai.tools.domains import CORE_BEARING_DOMAINS, CORE_TOOLS
from godot_ai.tools.editor import register_editor_tools
from godot_ai.tools.filesystem import register_filesystem_tools
from godot_ai.tools.game import register_game_tools
from godot_ai.tools.input_map import register_input_map_tools
from godot_ai.tools.material import register_material_tools
from godot_ai.tools.node import register_node_tools
from godot_ai.tools.particle import register_particle_tools
from godot_ai.tools.project import register_project_tools
from godot_ai.tools.resource import register_resource_tools
from godot_ai.tools.scene import register_scene_tools
from godot_ai.tools.script import register_script_tools
from godot_ai.tools.session import register_session_tools
from godot_ai.tools.signal import register_signal_tools
from godot_ai.tools.testing import register_testing_tools
from godot_ai.tools.theme import register_theme_tools
from godot_ai.tools.tilemap import register_tilemap_tools
from godot_ai.tools.tileset import register_tileset_tools
from godot_ai.tools.ui import register_ui_tools
from godot_ai.transport.origin_guard import IPNetwork, LocalhostOnlyHTTPMiddleware
from godot_ai.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)

## Filesystem location of the running `godot_ai` package — surfaced via the
## /godot-ai/status probe so the editor's "Incompatible server" diagnostic
## can tell the user *which* `src/godot_ai/` was actually loaded. In a
## multi-worktree dev setup this is the only fast way to distinguish "root
## .venv resolved to a stale branch" from "wrong PYTHONPATH" without
## walking the process tree by hand. See issue #416.
_SERVER_PACKAGE_PATH = str(Path(_godot_ai_pkg.__file__).resolve().parent)


@dataclass
class AppContext:
    registry: SessionRegistry
    ws_server: GodotWebSocketServer
    client: GodotClient
    leases: LeaseRegistry


class GodotAIFastMCP(FastMCP):
    """FastMCP server with Godot AI's ASGI diagnostics for HTTP transports."""

    def http_app(self, *args: Any, **kwargs: Any):
        app = super().http_app(*args, **kwargs)
        transport = kwargs.get("transport", "http")
        if transport in ("http", "streamable-http"):
            app = StaleMcpSessionDiagnosticMiddleware(app)
        ## Outermost wrap: refuse non-loopback Host/Origin (DNS-rebinding
        ## guard, audit-v2 finding #1). Applied to every HTTP transport
        ## including ``sse`` so ``/godot-ai/status`` and the FastMCP
        ## endpoints are guarded uniformly. ``--allow-host`` (#421) widens
        ## only the Host allowlist to named LAN CIDRs; None = loopback-only.
        return LocalhostOnlyHTTPMiddleware(app, getattr(self, "_allow_host_networks", None))


## ---------------------------------------------------------------------------
## MCP ``instructions`` — the capability map advertised to clients. Built per
## server so configured ``--exclude-domains`` are reflected in what we
## advertise (#772): an excluded tool must read as "excluded by config", not
## as a tool-search failure. Registration truth lives in ``create_server``;
## the tables below mirror it and are pinned against live registration by
## ``tests/unit/test_server_instructions.py``.

_INSTRUCTIONS_PREAMBLE = "Production-grade Godot MCP server with persistent editor integration.\n\n"

## The always-loaded core verbs (one line each). Core tools survive their
## domain's exclusion (see CORE_BEARING_DOMAINS), so these lines are
## unconditional.
_CORE_VERB_LINES: tuple[str, ...] = (
    "  editor_state                      — readiness, version, current scene\n",
    "  scene_get_hierarchy               — paginated scene tree walk\n",
    "  node_get_properties               — full property snapshot\n",
    "  session_activate                  — pin commands to one editor\n",
)

## Non-core named verbs, grouped into display lines: (separator, ((verb,
## domain), ...)). A verb drops with its domain; a line whose verbs are all
## excluded is omitted.
_NAMED_VERB_LINES: tuple[tuple[str, tuple[tuple[str, str], ...]], ...] = (
    (" / ", (("node_create", "node"), ("node_set_property", "node"), ("node_find", "node"))),
    (" / ", (("scene_open", "scene"), ("scene_save", "scene"))),
    (
        " / ",
        (("script_create", "script"), ("script_attach", "script"), ("script_patch", "script")),
    ),
    (
        ", ",
        (
            ("project_run", "project"),
            ("test_run", "testing"),
            ("batch_execute", "batch"),
            ("logs_read", "editor"),
        ),
    ),
    (
        ", ",
        (
            ("editor_screenshot", "editor"),
            ("editor_reload_plugin", "editor"),
            ("animation_create", "animation"),
        ),
    ),
)

## Rollup display blocks in advertised order: (domain, text). Excluding a
## domain drops its ``<domain>_manage`` from registration (core-bearing
## domains keep only their core verb), so the block drops here too. A
## ``None`` domain is unconditional text: ``session_manage`` stays
## registered under any exclusion set, and the bare "\n" is the historical
## blank line before the tilemap/tileset pair (kept for byte-stability of
## the no-exclusion output).
_ROLLUP_BLOCKS: tuple[tuple[str | None, str], ...] = (
    ("scene", "  scene_manage     create, save_as, get_roots\n"),
    (
        "node",
        "  node_manage      get_children, get_groups, delete, duplicate, rename,\n"
        "                   move, reparent, add_to_group, remove_from_group\n",
    ),
    ("script", "  script_manage    read, detach, find_symbols\n"),
    ("project", "  project_manage   stop, settings_get, settings_set\n"),
    (
        "editor",
        "  editor_manage    state, selection_get/set, monitors_get, quit, logs_clear,\n"
        "                   game_eval\n",
    ),
    (None, "  session_manage   list\n"),
    ("testing", "  test_manage      results_get\n"),
    (
        "animation",
        "  animation_manage player_create, delete, validate, add_property_track,\n"
        "                   add_method_track, set_autoplay, play, stop, list, get,\n"
        "                   create_simple, preset_fade/slide/shake/pulse\n",
    ),
    (
        "material",
        "  material_manage  create, set_param, set_shader_param, get, list, assign,\n"
        "                   apply_to_node, apply_preset\n",
    ),
    (
        "audio",
        "  audio_manage     player_create, player_set_stream, player_set_playback,\n"
        "                   play, stop, list\n",
    ),
    (
        "particle",
        "  particle_manage  create, set_main, set_process, set_draw_pass, restart,\n"
        "                   get, apply_preset\n",
    ),
    (
        "camera",
        "  camera_manage    create, configure, set_limits_2d, set_damping_2d,\n"
        "                   follow_2d, get, list, apply_preset\n",
    ),
    ("signal", "  signal_manage    list, connect, disconnect\n"),
    (
        "input_map",
        "  input_map_manage list, add_action, ensure_action, remove_action,\n"
        "                   bind_event, ensure_binding\n",
    ),
    (
        "game",
        "  game_manage      get_scene_tree, get_node_info, get_ui_elements,\n"
        "                   input_key, input_mouse, input_gamepad, input_action,\n"
        "                   input_state\n",
    ),
    ("autoload", "  autoload_manage  list, add, remove\n"),
    ("filesystem", "  filesystem_manage read_text, write_text, reimport, scan, search\n"),
    (
        "theme",
        "  theme_manage     create, set_color, set_constant, set_font_size,\n"
        "                   set_stylebox_flat, apply\n",
    ),
    ("ui", "  ui_manage        set_anchor_preset, set_text, build_layout, draw_recipe\n"),
    (
        "resource",
        "  resource_manage  search, load, assign, get_info, create,\n"
        "                   curve_set_points, environment_create,\n"
        "                   physics_shape_autofit, gradient_texture_create,\n"
        "                   noise_texture_create\n",
    ),
    ("api", "  api_manage       get_class\n"),
    ("client", "  client_manage    status, configure, remove\n"),
    (None, "\n"),
    (
        "tilemap",
        "  tilemap_manage   tilemap_set_cell, tilemap_set_cells_rect,\n"
        "                   tilemap_clear, tilemap_get_cells\n",
    ),
    ("tileset", "  tileset_manage   tileset_get_atlas_tiles, tileset_get_atlas_image\n"),
)

## Resources are registered unconditionally (they never count against tool
## caps), so this section and the closing guidance are static.
_INSTRUCTIONS_FOOTER = (
    "Resources (read-only URIs, no tool-count cost — prefer for active-session "
    "reads when the client surfaces them):\n"
    "  godot://sessions, godot://editor/state, godot://selection/current,\n"
    "  godot://logs/recent, godot://scene/current, godot://scene/hierarchy,\n"
    "  godot://node/{path}/properties|children|groups,\n"
    "  godot://class/{class_name},\n"
    "  godot://script/{path}, godot://project/info, godot://project/settings,\n"
    "  godot://materials, godot://input_map, godot://performance,\n"
    "  godot://test/results\n\n"
    "Always connect to an editor session first (session_activate or "
    'session_manage(op="list")). Write operations require session readiness; '
    "check editor_state if a call is rejected as 'not writable'. After driving a "
    "running game, check logs_read(source='editor' or 'game', include_details=true) "
    "before declaring a feature verified."
)


def build_instructions(exclude: set[str]) -> str:
    """Build the MCP ``instructions`` string for one exclusion set.

    Pure function of ``exclude`` so tests can pin both outputs: with no
    exclusions the result is byte-identical to the historical static text;
    with exclusions, the excluded domains' named verbs and rollup lines are
    omitted, the named-verb count reflects what is actually registered, and
    a trailing section names the exclusions (#772).
    """
    verb_lines: list[str] = list(_CORE_VERB_LINES)
    verb_count = len(_CORE_VERB_LINES)
    for separator, verbs in _NAMED_VERB_LINES:
        kept = [verb for verb, domain in verbs if domain not in exclude]
        if not kept:
            continue
        verb_count += len(kept)
        verb_lines.append("  " + separator.join(kept) + "\n")

    rollup_lines = [
        text for domain, text in _ROLLUP_BLOCKS if domain is None or domain not in exclude
    ]

    parts = [
        _INSTRUCTIONS_PREAMBLE,
        f"Tool surface — {verb_count} named verbs + per-domain `<domain>_manage` rollups:\n\n",
        "Core named verbs (always loaded — common reads + high-traffic writes):\n",
        *verb_lines,
        "\n",
        "Domain rollups (one tool per domain; pass `op=` + a `params` dict):\n",
        *rollup_lines,
        "\n",
        _INSTRUCTIONS_FOOTER,
    ]

    if exclude:
        ## Core-bearing domains keep their core verb through an exclusion —
        ## name the survivors so the caveat stays accurate as the core set
        ## evolves (derived from CORE_BEARING_DOMAINS/CORE_TOOLS, not prose).
        kept_core = [
            tool
            for tool in CORE_TOOLS
            if any(tool.startswith(f"{domain}_") for domain in exclude & CORE_BEARING_DOMAINS)
        ]
        caveat = "Core tools for core-bearing domains remain available"
        caveat += f": {', '.join(kept_core)}." if kept_core else "."
        parts.append(
            "\n\nExcluded domains (not registered on this server): "
            f"{', '.join(sorted(exclude))}. {caveat}"
        )

    return "".join(parts)


def _startup_record_data(
    client: GodotClient, ws_port: int, lifespan_start_ms: float
) -> dict[str, Any]:
    """Build the STARTUP telemetry payload (#761 follow-up).

    ``diagnostic_hints_suppressed`` reads the hint policy off the
    already-constructed client instead of re-reading
    ``GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS``: the policy is resolved once
    at client construction (env default or explicit override), so the
    client's value is the behavior the process actually runs with — a
    fresh env read could disagree with it.
    """
    return {
        "server_version": _SERVER_VERSION,
        "ws_port": ws_port,
        "lifespan_start_ms": lifespan_start_ms,
        "diagnostic_hints_suppressed": client.default_hint_policy == "discard",
    }


def create_server(
    ws_port: int = 9500,
    *,
    exclude_domains: Iterable[str] | None = None,
    owner_pid: int | None = None,
    allow_host_networks: Sequence[IPNetwork] | None = None,
) -> FastMCP:
    logging.basicConfig(level=logging.INFO, format="%(name)s | %(message)s")
    leases = LeaseRegistry(SERVER_INSTANCE_ID)

    # Capture ws_port in the lifespan closure
    @asynccontextmanager
    async def _lifespan(server: FastMCP) -> AsyncIterator[AppContext]:
        leases.clear()
        registry = SessionRegistry()
        ## The WS server is intentionally loopback-only even under --allow-host
        ## (#421): it's the local editor↔server bridge, not a remote surface.
        ## See GodotWebSocketServer.start for the rationale (LAN exposure +
        ## Windows IPv6-only breakage).
        ## #690: the spawning plugin hands us a per-launch handshake auth
        ## token via env (same channel as GODOT_AI_OWNER_PID). Absent for
        ## manually-started dev/CI servers, which then accept tokenless
        ## handshakes — see GodotWebSocketServer.__init__.
        ws_server = GodotWebSocketServer(
            registry,
            port=ws_port,
            auth_token=os.environ.get("GODOT_AI_WS_TOKEN") or None,
        )
        client = GodotClient(ws_server, registry)

        ws_task = asyncio.create_task(ws_server.start())
        logger.info("WebSocket server starting on port %d", ws_server.port)

        ## When the plugin auto-spawns us it passes --owner-pid. Reap this
        ## detached server if that editor dies without a clean stop_server and
        ## nobody has adopted us (zero sessions). Servers started without an
        ## owner pid (CI, manual --reload) skip this entirely, as does Windows
        ## (see should_arm_reaper).
        reaper_task: asyncio.Task | None = None
        if should_arm_reaper(owner_pid):
            reaper_task = asyncio.create_task(
                watch_owner(
                    owner_pid,
                    lambda: len(registry.list_all()),
                    lease_count=leases.active_count,
                    poll_seconds=poll_seconds_from_env(),
                )
            )
            logger.info("Orphan reaper armed for owner editor pid %d", owner_pid)
        elif owner_pid and owner_pid > 0:
            logger.info(
                "Owner editor pid %d supplied but orphan reaper is disabled on "
                "this platform; relying on clean editor shutdown.",
                owner_pid,
            )

        ## Idle self-terminate backstop (#498). Runs ALONGSIDE the owner-PID
        ## watchdog, not instead of it: pure session-count + monotonic-clock, so
        ## it also covers Windows (where should_arm_reaper is False — #497) and
        ## any path where the owner pid didn't survive env plumbing. Arms only
        ## for plugin-spawned servers (GODOT_AI_PLUGIN_SPAWNED marker or owner
        ## pid); manual dev servers, CI, and --reload runs are never idle-killed.
        idle_task: asyncio.Task | None = None
        if should_arm_idle_exit(owner_pid):
            idle_task = asyncio.create_task(
                watch_idle(
                    lambda: len(registry.list_all()),
                    lease_count=leases.active_count,
                    poll_seconds=poll_seconds_from_env(),
                    boot_grace_seconds=boot_grace_from_env(),
                    idle_grace_seconds=idle_grace_from_env(),
                )
            )
            logger.info("Idle self-terminate backstop armed for plugin-spawned server")
        elif should_arm_attach_idle_exit():
            idle_task = asyncio.create_task(
                watch_idle(
                    lambda: len(registry.list_all()),
                    lease_count=leases.active_count,
                    poll_seconds=poll_seconds_from_env(),
                    boot_grace_seconds=boot_grace_from_env(),
                    idle_grace_seconds=idle_grace_from_env(),
                )
            )
            logger.info("Lease-aware idle reaper armed for attach-owned server")

        ## Defer initial telemetry off the lifespan start tick — mirrors
        ## unity-mcp's 1s stdio-handshake guard so the first POST never
        ## races the MCP protocol's own startup chatter. Scheduled via
        ## the running loop (not a ``threading.Timer``) so a fast
        ## shutdown cancels the pending callback cleanly instead of
        ## leaving a non-daemon thread alive past lifespan teardown.
        start_clk = time.perf_counter()

        def _emit_startup() -> None:
            try:
                record_telemetry(
                    RecordType.STARTUP,
                    _startup_record_data(
                        client, ws_port, (time.perf_counter() - start_clk) * 1000.0
                    ),
                )
                record_milestone(MilestoneType.FIRST_STARTUP)
            except Exception:  # noqa: BLE001
                logger.debug("Startup telemetry failed", exc_info=True)

        loop = asyncio.get_running_loop()
        startup_handle = loop.call_later(1.0, _emit_startup)

        try:
            yield AppContext(
                registry=registry,
                ws_server=ws_server,
                client=client,
                leases=leases,
            )
        finally:
            startup_handle.cancel()
            if reaper_task is not None:
                reaper_task.cancel()
                try:
                    await reaper_task
                except (asyncio.CancelledError, OSError):
                    pass
            if idle_task is not None:
                idle_task.cancel()
                try:
                    await idle_task
                except (asyncio.CancelledError, OSError):
                    pass
            ws_task.cancel()
            try:
                await ws_task
            except (asyncio.CancelledError, OSError):
                pass
            ## Use ``shutdown_if_initialized`` so an opted-out server
            ## (which never created a collector) doesn't get one
            ## materialized solely to be shut down.
            try:
                shutdown_if_initialized()
            except Exception:  # noqa: BLE001
                logger.debug("Telemetry shutdown failed", exc_info=True)

    exclude = set(exclude_domains or ())
    if exclude:
        logger.info("Excluding tool domains: %s", ", ".join(sorted(exclude)))

    mcp = GodotAIFastMCP(
        "Godot AI",
        instructions=build_instructions(exclude),
        lifespan=_lifespan,
    )

    ## #421: stash the --allow-host CIDRs where http_app() reads them when it
    ## installs the rebinding guard middleware. None = loopback-only (default).
    mcp._allow_host_networks = list(allow_host_networks) if allow_host_networks else None

    ## Middleware registration order is load-bearing — do not reorder
    ## without reading the rationale below. Locked by
    ## ``tests/unit/test_server_middleware_order.py``.
    ##
    ## FastMCP composes the chain by iterating ``reversed(self.middleware)``
    ## (see ``fastmcp/server/server.py::_run_middleware``), so the
    ## **first-added** middleware is the **outermost** wrap (runs first on
    ## request, last on response) and the **last-added** is the **innermost**
    ## (runs last on request, first on response). Each layer below is placed
    ## where it is for a specific reason:
    ##
    ## 1. ``PreserveGodotCommandErrorData`` — outermost on the response
    ##    side. Catches ``GodotCommandError`` raised from any inner layer
    ##    (handlers, plugin client, validation) and packages structured
    ##    ``error.data`` (e.g. plugin-provided candidate paths) into the
    ##    MCP tool result. Must be outermost so no inner middleware can
    ##    collapse the structured payload into plain text before this
    ##    catches it.
    ##
    ## 2. ``StripClientWrapperKwargs`` — early on the request side. Removes
    ##    known client-injected wrapper kwargs (e.g. Cline's
    ##    ``task_progress``) before any inner layer or Pydantic strict-mode
    ##    schema sees them. See #193.
    ##
    ## 3. ``ParseStringifiedParams`` — request-side, after wrapper-stripping
    ##    and before Pydantic. JSON-decodes a stringified ``params`` slot on
    ##    ``<domain>_manage`` calls so the strict-mode schema sees the dict
    ##    the client meant to send. Must run before Pydantic (which lives
    ##    below all middleware in the FastMCP tool layer). See #206.
    ##
    ## 4. ``FoldFlatManageParams`` — request-side, after stringified params
    ##    are decoded. Folds transmitted top-level op params into the
    ##    canonical ``params`` object before Pydantic sees them, and rewrites
    ##    only pure top-level-extra validation failures. See #765.
    ##
    ## 5. ``HintOpTypoOnManage`` — innermost on the response side. Catches
    ##    Pydantic ``ValidationError`` for ``op`` literal_error and rewrites
    ##    it with a ``difflib``-derived "Did you mean…" hint. Must be
    ##    innermost on response so it sees Pydantic's raw ``ValidationError``
    ##    before any outer middleware reshapes or wraps it. See #211.
    mcp.add_middleware(PreserveGodotCommandErrorData())
    mcp.add_middleware(StripClientWrapperKwargs())
    mcp.add_middleware(ParseStringifiedParams())
    mcp.add_middleware(FoldFlatManageParams())
    mcp.add_middleware(HintOpTypoOnManage())

    ## Wrap ``mcp.tool`` / ``mcp.resource`` once, before any
    ## ``register_*`` call below, so every tool and resource registered
    ## downstream is automatically instrumented for telemetry without
    ## per-domain awareness. This includes the rollup ``<domain>_manage``
    ## tools registered via ``register_manage_tool`` — its inner
    ## ``manage`` closure exposes ``op`` as a parameter, which the
    ## telemetry decorator captures as ``sub_action`` automatically.
    install_fastmcp_wraps(mcp)

    catalog_digest: str | None = None

    @mcp.custom_route("/godot-ai/status", methods=["GET"], include_in_schema=False)
    async def godot_ai_status(_request: Request) -> JSONResponse:
        """Small unauthenticated probe used by the editor before reusing a port."""
        nonlocal catalog_digest
        if catalog_digest is None:
            catalog_digest = await tool_catalog_hash(mcp)
        return JSONResponse(
            {
                "name": "godot-ai",
                "server_version": _SERVER_VERSION,
                "ws_port": ws_port,
                "tool_surface": "rollup",
                "exclude_domains": sorted(exclude),
                ## `package_path` lets the editor's incompatible-server
                ## banner pinpoint the source of a version skew (e.g.
                ## "loaded from /Users/.../godot-ai-feature-branch/src" vs
                ## "loaded from /Users/.../godot-ai/src") without the
                ## user having to walk the process tree. See #416.
                "package_path": _SERVER_PACKAGE_PATH,
                ## Attach protocol compatibility fields are descriptive only.
                ## In particular, owner_type is self-reported and MUST NEVER
                ## authorize killing or replacing a process.
                "instance_id": SERVER_INSTANCE_ID,
                "owner_type": owner_type_from_env(),
                "attach_protocol_version": ATTACH_PROTOCOL_VERSION,
                "tool_catalog_hash": catalog_digest,
            }
        )

    async def _lease_body(request: Request, *required: str) -> dict[str, Any] | JSONResponse:
        try:
            payload = await request.json()
        except (TypeError, ValueError):
            return JSONResponse(
                {"error": {"code": "INVALID_LEASE_REQUEST", "message": "Expected JSON body."}},
                status_code=400,
            )
        if not isinstance(payload, dict):
            return JSONResponse(
                {"error": {"code": "INVALID_LEASE_REQUEST", "message": "Expected JSON object."}},
                status_code=400,
            )
        missing = [
            key for key in required if not isinstance(payload.get(key), str) or not payload[key]
        ]
        if missing:
            return JSONResponse(
                {
                    "error": {
                        "code": "INVALID_LEASE_REQUEST",
                        "message": f"Missing non-empty string field(s): {', '.join(missing)}.",
                    }
                },
                status_code=400,
            )
        return payload

    def _lease_error(exc: Exception) -> JSONResponse:
        if isinstance(exc, LeaseInstanceMismatch):
            return JSONResponse(
                {
                    "error": {
                        "code": "BACKEND_INSTANCE_CHANGED",
                        "message": str(exc),
                        "instance_id": SERVER_INSTANCE_ID,
                    }
                },
                status_code=409,
            )
        return JSONResponse(
            {
                "error": {
                    "code": "LEASE_NOT_FOUND",
                    "message": "Lease does not exist or has expired; register a new lease.",
                    "instance_id": SERVER_INSTANCE_ID,
                }
            },
            status_code=404,
        )

    @mcp.custom_route("/godot-ai/lease/register", methods=["POST"], include_in_schema=False)
    async def godot_ai_lease_register(request: Request) -> JSONResponse:
        payload = await _lease_body(request, "instance_id")
        if isinstance(payload, JSONResponse):
            return payload
        try:
            registration = leases.register(str(payload["instance_id"]))
        except LeaseInstanceMismatch as exc:
            return _lease_error(exc)
        return JSONResponse(registration.to_dict())

    @mcp.custom_route("/godot-ai/lease/heartbeat", methods=["POST"], include_in_schema=False)
    async def godot_ai_lease_heartbeat(request: Request) -> JSONResponse:
        payload = await _lease_body(request, "instance_id", "lease_id")
        if isinstance(payload, JSONResponse):
            return payload
        try:
            registration = leases.heartbeat(
                str(payload["instance_id"]),
                str(payload["lease_id"]),
            )
        except (LeaseInstanceMismatch, LeaseNotFound) as exc:
            return _lease_error(exc)
        return JSONResponse(registration.to_dict())

    @mcp.custom_route("/godot-ai/lease/release", methods=["POST"], include_in_schema=False)
    async def godot_ai_lease_release(request: Request) -> JSONResponse:
        payload = await _lease_body(request, "instance_id", "lease_id")
        if isinstance(payload, JSONResponse):
            return payload
        try:
            released = leases.release(str(payload["instance_id"]), str(payload["lease_id"]))
        except LeaseInstanceMismatch as exc:
            return _lease_error(exc)
        if not released:
            return _lease_error(LeaseNotFound(str(payload["lease_id"])))
        return JSONResponse({"released": True, "instance_id": SERVER_INSTANCE_ID})

    ## Core-bearing domains: always registered. ``include_non_core=False`` keeps
    ## only the core tool alive when the user excluded that domain.
    register_session_tools(mcp, include_non_core="session" not in exclude, exclude_domains=exclude)
    register_editor_tools(mcp, include_non_core="editor" not in exclude)
    register_scene_tools(mcp, include_non_core="scene" not in exclude)
    register_node_tools(mcp, include_non_core="node" not in exclude)

    ## Non-core-bearing domains: dropped wholesale when excluded.
    if "project" not in exclude:
        register_project_tools(mcp)
    if "script" not in exclude:
        register_script_tools(mcp)
    if "resource" not in exclude:
        register_resource_tools(mcp)
    if "api" not in exclude:
        register_api_tools(mcp)
    if "filesystem" not in exclude:
        register_filesystem_tools(mcp)
    if "client" not in exclude:
        register_client_tools(mcp)
    if "signal" not in exclude:
        register_signal_tools(mcp)
    if "autoload" not in exclude:
        register_autoload_tools(mcp)
    if "input_map" not in exclude:
        register_input_map_tools(mcp)
    if "game" not in exclude:
        register_game_tools(mcp)
    if "testing" not in exclude:
        register_testing_tools(mcp)
    if "batch" not in exclude:
        register_batch_tools(mcp)
    if "ui" not in exclude:
        register_ui_tools(mcp)
    if "theme" not in exclude:
        register_theme_tools(mcp)
    if "animation" not in exclude:
        register_animation_tools(mcp)
    if "material" not in exclude:
        register_material_tools(mcp)
    if "particle" not in exclude:
        register_particle_tools(mcp)
    if "camera" not in exclude:
        register_camera_tools(mcp)
    if "audio" not in exclude:
        register_audio_tools(mcp)
    if "tilemap" not in exclude:
        register_tilemap_tools(mcp)
    if "tileset" not in exclude:
        register_tileset_tools(mcp)

    register_session_resources(mcp)
    register_scene_resources(mcp)
    register_editor_resources(mcp)
    register_project_resources(mcp)
    register_node_resources(mcp)
    register_script_resources(mcp)
    register_library_resources(mcp)
    register_class_resources(mcp)

    return mcp
