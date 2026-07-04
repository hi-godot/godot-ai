"""FastMCP server — the main entry point for Godot AI."""

from __future__ import annotations

import asyncio
import logging
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
from godot_ai.godot_client.client import GodotClient
from godot_ai.middleware import (
    HintOpTypoOnManage,
    ParseStringifiedParams,
    PreserveGodotCommandErrorData,
    StripClientWrapperKwargs,
)
from godot_ai.orphan_reaper import poll_seconds_from_env, should_arm_reaper, watch_owner
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


def create_server(
    ws_port: int = 9500,
    *,
    exclude_domains: Iterable[str] | None = None,
    owner_pid: int | None = None,
    allow_host_networks: Sequence[IPNetwork] | None = None,
) -> FastMCP:
    logging.basicConfig(level=logging.INFO, format="%(name)s | %(message)s")

    # Capture ws_port in the lifespan closure
    @asynccontextmanager
    async def _lifespan(server: FastMCP) -> AsyncIterator[AppContext]:
        registry = SessionRegistry()
        ## The WS server is intentionally loopback-only even under --allow-host
        ## (#421): it's the local editor↔server bridge, not a remote surface.
        ## See GodotWebSocketServer.start for the rationale (LAN exposure +
        ## Windows IPv6-only breakage).
        ws_server = GodotWebSocketServer(registry, port=ws_port)
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
                    {
                        "server_version": _SERVER_VERSION,
                        "ws_port": ws_port,
                        "lifespan_start_ms": (time.perf_counter() - start_clk) * 1000.0,
                    },
                )
                record_milestone(MilestoneType.FIRST_STARTUP)
            except Exception:  # noqa: BLE001
                logger.debug("Startup telemetry failed", exc_info=True)

        loop = asyncio.get_running_loop()
        startup_handle = loop.call_later(1.0, _emit_startup)

        try:
            yield AppContext(registry=registry, ws_server=ws_server, client=client)
        finally:
            startup_handle.cancel()
            if reaper_task is not None:
                reaper_task.cancel()
                try:
                    await reaper_task
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

    mcp = GodotAIFastMCP(
        "Godot AI",
        instructions=(
            "Production-grade Godot MCP server with persistent editor integration.\n\n"
            "Tool surface — ~18 named verbs + per-domain `<domain>_manage` rollups:\n\n"
            "Core named verbs (always loaded — common reads + high-traffic writes):\n"
            "  editor_state                      — readiness, version, current scene\n"
            "  scene_get_hierarchy               — paginated scene tree walk\n"
            "  node_get_properties               — full property snapshot\n"
            "  session_activate                  — pin commands to one editor\n"
            "  node_create / node_set_property / node_find\n"
            "  scene_open / scene_save\n"
            "  script_create / script_attach / script_patch\n"
            "  project_run, test_run, batch_execute, logs_read\n"
            "  editor_screenshot, editor_reload_plugin, animation_create\n\n"
            "Domain rollups (one tool per domain; pass `op=` + a `params` dict):\n"
            "  scene_manage     create, save_as, get_roots\n"
            "  node_manage      get_children, get_groups, delete, duplicate, rename,\n"
            "                   move, reparent, add_to_group, remove_from_group\n"
            "  script_manage    read, detach, find_symbols\n"
            "  project_manage   stop, settings_get, settings_set\n"
            "  editor_manage    state, selection_get/set, monitors_get, quit, logs_clear\n"
            "  session_manage   list\n"
            "  test_manage      results_get\n"
            "  animation_manage player_create, delete, validate, add_property_track,\n"
            "                   add_method_track, set_autoplay, play, stop, list, get,\n"
            "                   create_simple, preset_fade/slide/shake/pulse\n"
            "  material_manage  create, set_param, set_shader_param, get, list, assign,\n"
            "                   apply_to_node, apply_preset\n"
            "  audio_manage     player_create, player_set_stream, player_set_playback,\n"
            "                   play, stop, list\n"
            "  particle_manage  create, set_main, set_process, set_draw_pass, restart,\n"
            "                   get, apply_preset\n"
            "  camera_manage    create, configure, set_limits_2d, set_damping_2d,\n"
            "                   follow_2d, get, list, apply_preset\n"
            "  signal_manage    list, connect, disconnect\n"
            "  input_map_manage list, add_action, ensure_action, remove_action,\n"
            "                   bind_event, ensure_binding\n"
            "  game_manage      get_scene_tree, get_node_info, get_ui_elements,\n"
            "                   input_key, input_mouse, input_gamepad, input_action,\n"
            "                   input_state\n"
            "  autoload_manage  list, add, remove\n"
            "  filesystem_manage read_text, write_text, reimport, search\n"
            "  theme_manage     create, set_color, set_constant, set_font_size,\n"
            "                   set_stylebox_flat, apply\n"
            "  ui_manage        set_anchor_preset, set_text, build_layout, draw_recipe\n"
            "  resource_manage  search, load, assign, get_info, create,\n"
            "                   curve_set_points, environment_create,\n"
            "                   physics_shape_autofit, gradient_texture_create,\n"
            "                   noise_texture_create\n"
            "  api_manage       get_class\n"
            "  client_manage    status, configure, remove\n\n"
            "  tilemap_manage   tilemap_set_cell, tilemap_set_cells_rect,\n"
            "                   tilemap_clear, tilemap_get_cells\n"
            "  tileset_manage   tileset_get_atlas_tiles, tileset_get_atlas_image\n\n"
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
        ),
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
    ## 4. ``HintOpTypoOnManage`` — innermost on the response side. Catches
    ##    Pydantic ``ValidationError`` for ``op`` literal_error and rewrites
    ##    it with a ``difflib``-derived "Did you mean…" hint. Must be
    ##    innermost on response so it sees Pydantic's raw ``ValidationError``
    ##    before any outer middleware reshapes or wraps it. See #211.
    mcp.add_middleware(PreserveGodotCommandErrorData())
    mcp.add_middleware(StripClientWrapperKwargs())
    mcp.add_middleware(ParseStringifiedParams())
    mcp.add_middleware(HintOpTypoOnManage())

    ## Wrap ``mcp.tool`` / ``mcp.resource`` once, before any
    ## ``register_*`` call below, so every tool and resource registered
    ## downstream is automatically instrumented for telemetry without
    ## per-domain awareness. This includes the rollup ``<domain>_manage``
    ## tools registered via ``register_manage_tool`` — its inner
    ## ``manage`` closure exposes ``op`` as a parameter, which the
    ## telemetry decorator captures as ``sub_action`` automatically.
    install_fastmcp_wraps(mcp)

    exclude = set(exclude_domains or ())
    if exclude:
        logger.info("Excluding tool domains: %s", ", ".join(sorted(exclude)))

    @mcp.custom_route("/godot-ai/status", methods=["GET"], include_in_schema=False)
    async def godot_ai_status(_request: Request) -> JSONResponse:
        """Small unauthenticated probe used by the editor before reusing a port."""
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
            }
        )

    ## Core-bearing domains: always registered. ``include_non_core=False`` keeps
    ## only the core tool alive when the user excluded that domain.
    register_session_tools(mcp, include_non_core="session" not in exclude)
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
