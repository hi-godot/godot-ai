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
from godot_ai.tools.autoload import register_autoload_tools
from godot_ai.tools.client import register_client_tools
from godot_ai.tools.editor import register_editor_tools
from godot_ai.tools.filesystem import register_filesystem_tools
from godot_ai.tools.input_map import register_input_map_tools
from godot_ai.tools.node import register_node_tools
from godot_ai.tools.project import register_project_tools
from godot_ai.tools.resource import register_resource_tools
from godot_ai.tools.scene import register_scene_tools
from godot_ai.tools.script import register_script_tools
from godot_ai.tools.session import register_session_tools
from godot_ai.tools.signal import register_signal_tools
from godot_ai.tools.testing import register_testing_tools
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
        instructions="Production-grade Godot MCP server with persistent editor integration. "
        "Use session tools to manage connections to Godot editor instances.",
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
    register_session_resources(mcp)
    register_scene_resources(mcp)
    register_editor_resources(mcp)
    register_project_resources(mcp)

    return mcp
