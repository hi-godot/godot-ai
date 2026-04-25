"""FastMCP server — the main entry point for Godot AI."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator, Iterable
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastmcp import FastMCP

from godot_ai.godot_client.client import GodotClient
from godot_ai.resources.editor import register_editor_resources
from godot_ai.resources.library import register_library_resources
from godot_ai.resources.nodes import register_node_resources
from godot_ai.resources.project import register_project_resources
from godot_ai.resources.scenes import register_scene_resources
from godot_ai.resources.scripts import register_script_resources
from godot_ai.resources.sessions import register_session_resources
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.tools.animation import register_animation_tools
from godot_ai.tools.audio import register_audio_tools
from godot_ai.tools.autoload import register_autoload_tools
from godot_ai.tools.batch import register_batch_tools
from godot_ai.tools.camera import register_camera_tools
from godot_ai.tools.client import register_client_tools
from godot_ai.tools.editor import register_editor_tools
from godot_ai.tools.filesystem import register_filesystem_tools
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
from godot_ai.tools.ui import register_ui_tools
from godot_ai.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)


@dataclass
class AppContext:
    registry: SessionRegistry
    ws_server: GodotWebSocketServer
    client: GodotClient


def create_server(
    ws_port: int = 9500,
    *,
    exclude_domains: Iterable[str] | None = None,
) -> FastMCP:
    logging.basicConfig(level=logging.INFO, format="%(name)s | %(message)s")

    # Capture ws_port in the lifespan closure
    @asynccontextmanager
    async def _lifespan(server: FastMCP) -> AsyncIterator[AppContext]:
        registry = SessionRegistry()
        ws_server = GodotWebSocketServer(registry, port=ws_port)
        client = GodotClient(ws_server, registry)

        ws_task = asyncio.create_task(ws_server.start())
        logger.info("WebSocket server starting on port %d", ws_server.port)

        try:
            yield AppContext(registry=registry, ws_server=ws_server, client=client)
        finally:
            ws_task.cancel()
            try:
                await ws_task
            except (asyncio.CancelledError, OSError):
                pass

    mcp = FastMCP(
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
            "  input_map_manage list, add_action, remove_action, bind_event\n"
            "  autoload_manage  list, add, remove\n"
            "  filesystem_manage read_text, write_text, reimport, search\n"
            "  theme_manage     create, set_color, set_constant, set_font_size,\n"
            "                   set_stylebox_flat, apply\n"
            "  ui_manage        set_anchor_preset, set_text, build_layout, draw_recipe\n"
            "  resource_manage  search, load, assign, get_info, create,\n"
            "                   curve_set_points, environment_create,\n"
            "                   physics_shape_autofit, gradient_texture_create,\n"
            "                   noise_texture_create\n"
            "  client_manage    status, configure, remove\n\n"
            "Resources (read-only URIs, no tool-count cost — prefer for active-session "
            "reads when the client surfaces them):\n"
            "  godot://sessions, godot://editor/state, godot://selection/current,\n"
            "  godot://logs/recent, godot://scene/current, godot://scene/hierarchy,\n"
            "  godot://node/{path}/properties|children|groups,\n"
            "  godot://script/{path}, godot://project/info, godot://project/settings,\n"
            "  godot://materials, godot://input_map, godot://performance,\n"
            "  godot://test/results\n\n"
            "Always connect to an editor session first (session_activate or "
            'session_manage(op="list")). Write operations require session readiness; '
            "check editor_state if a call is rejected as 'not writable'."
        ),
        lifespan=_lifespan,
    )

    exclude = set(exclude_domains or ())
    if exclude:
        logger.info("Excluding tool domains: %s", ", ".join(sorted(exclude)))

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

    register_session_resources(mcp)
    register_scene_resources(mcp)
    register_editor_resources(mcp)
    register_project_resources(mcp)
    register_node_resources(mcp)
    register_script_resources(mcp)
    register_library_resources(mcp)

    return mcp
