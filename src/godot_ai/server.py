"""FastMCP server — the main entry point for Godot AI."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastmcp import FastMCP

from godot_ai.godot_client.client import GodotClient
from godot_ai.resources.editor import register_editor_resources
from godot_ai.resources.project import register_project_resources
from godot_ai.resources.scenes import register_scene_resources
from godot_ai.resources.sessions import register_session_resources
from godot_ai.sessions.registry import SessionRegistry
from godot_ai.tools.animation import register_animation_tools
from godot_ai.tools.audio import register_audio_tools
from godot_ai.tools.autoload import register_autoload_tools
from godot_ai.tools.batch import register_batch_tools
from godot_ai.tools.camera import register_camera_tools
from godot_ai.tools.client import register_client_tools
from godot_ai.tools.curve import register_curve_tools
from godot_ai.tools.editor import register_editor_tools
from godot_ai.tools.environment import register_environment_tools
from godot_ai.tools.filesystem import register_filesystem_tools
from godot_ai.tools.input_map import register_input_map_tools
from godot_ai.tools.material import register_material_tools
from godot_ai.tools.node import register_node_tools
from godot_ai.tools.particle import register_particle_tools
from godot_ai.tools.physics_shape import register_physics_shape_tools
from godot_ai.tools.project import register_project_tools
from godot_ai.tools.resource import register_resource_tools
from godot_ai.tools.scene import register_scene_tools
from godot_ai.tools.script import register_script_tools
from godot_ai.tools.session import register_session_tools
from godot_ai.tools.signal import register_signal_tools
from godot_ai.tools.testing import register_testing_tools
from godot_ai.tools.texture import register_texture_tools
from godot_ai.tools.theme import register_theme_tools
from godot_ai.tools.ui import register_ui_tools
from godot_ai.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)


@dataclass
class AppContext:
    registry: SessionRegistry
    ws_server: GodotWebSocketServer
    client: GodotClient


def create_server(ws_port: int = 9500) -> FastMCP:
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
            "Tool categories (namespace prefixes — useful for tool-search queries):\n"
            "  session_*        — list and activate connected editor sessions\n"
            "  editor_*         — editor state, selection, screenshot, logs, quit, reload plugin\n"
            "  scene_*          — open/save scenes (levels/maps), inspect the scene tree\n"
            "  node_*           — create, inspect, modify, duplicate, group, reparent nodes\n"
            "  script_*         — create, read, attach, detach, outline GDScript files\n"
            "  resource_*       — search, load, assign, and CREATE built-in Resources "
            "(BoxMesh, BoxShape3D, Curve, Gradient, StyleBox*, PhysicsMaterial, etc.) "
            "inline or as .tres files — see resource_create\n"
            "  signal_*         — list, connect, disconnect node signals (events / callbacks)\n"
            "  input_map_*      — manage input actions (keybindings, keyboard/mouse/gamepad)\n"
            "  autoload_*       — manage autoload singletons (global scripts)\n"
            "  project_*        — run/stop the game, read/write project settings\n"
            "  filesystem_*     — read/write text files, search assets, reimport\n"
            "  performance_*    — FPS, memory, draw calls, and other runtime metrics\n"
            "  logs_*           — read or clear the editor log buffer\n"
            "  test_*           — run GDScript test suites and fetch results\n"
            "  batch_execute    — compose multi-step scene edits atomically\n"
            "  ui_*             — Control layout helpers "
            "(anchor presets, declarative layout builder)\n"
            "  theme_*          — author Theme resources "
            "(colors, stylebox, font sizes) — Godot's CSS-like styling\n"
            "  animation_*      — AnimationPlayer authoring "
            "(tracks, keyframes, autoplay) — hover pulses, slide-ins, shakes, fades\n"
            "  animation_preset_* — one-call canned animations "
            "(fade, slide, shake, pulse) — no tween specs needed\n"
            "  material_*       — author Materials "
            "(StandardMaterial3D, ORM, ShaderMaterial) — "
            "paint, albedo, metal, glass, emission, shader uniforms\n"
            "  particle_*       — author particle emitters "
            "(GPUParticles2D/3D, CPUParticles2D/3D) — "
            "fire, smoke, sparks, magic, rain, explosion\n"
            "  camera_*         — Camera2D/Camera3D authoring "
            "(follow, bounds, zoom, damping, smoothing, drag margins, deadzone)\n"
            "  audio_*          — author sound effects and music "
            "(AudioStreamPlayer/2D/3D) — load streams, play, stop, list audio assets\n"
            "  physics_shape_*  — size CollisionShape2D/3D to match sibling visuals "
            "(box, sphere, capsule, cylinder / rectangle, circle, capsule)\n"
            "  environment_*    — author WorldEnvironment chain "
            "(Environment + Sky + SkyMaterial) with presets: "
            "default, sunset, night, fog\n"
            "  gradient_texture_*, noise_texture_* — procedural 2D textures "
            "(gradients for Line2D/Sprite2D, FastNoiseLite + NoiseTexture2D for heightmaps)\n"
            "  curve_*          — author Curve/Curve2D/Curve3D point lists "
            "for Path3D routes, particle ramps, and easing curves\n"
            "  client_*         — configure AI clients (Claude Code, Codex, Antigravity)\n\n"
            "Always connect to an editor session first (session_list / session_activate). "
            "Write operations require session readiness; check editor_state if a call is "
            "rejected as 'not writable'."
        ),
        lifespan=_lifespan,
    )

    register_session_tools(mcp)
    register_editor_tools(mcp)
    register_scene_tools(mcp)
    register_node_tools(mcp)
    register_project_tools(mcp)
    register_script_tools(mcp)
    register_resource_tools(mcp)
    register_filesystem_tools(mcp)
    register_client_tools(mcp)
    register_signal_tools(mcp)
    register_autoload_tools(mcp)
    register_input_map_tools(mcp)
    register_testing_tools(mcp)
    register_batch_tools(mcp)
    register_ui_tools(mcp)
    register_theme_tools(mcp)
    register_animation_tools(mcp)
    register_material_tools(mcp)
    register_particle_tools(mcp)
    register_camera_tools(mcp)
    register_audio_tools(mcp)
    register_physics_shape_tools(mcp)
    register_environment_tools(mcp)
    register_texture_tools(mcp)
    register_curve_tools(mcp)
    register_session_resources(mcp)
    register_scene_resources(mcp)
    register_editor_resources(mcp)
    register_project_resources(mcp)

    return mcp
