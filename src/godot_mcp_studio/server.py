"""FastMCP server — the main entry point for Godot MCP Studio."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

from fastmcp import FastMCP

from godot_mcp_studio.godot_client.client import GodotClient
from godot_mcp_studio.resources.sessions import register_session_resources
from godot_mcp_studio.sessions.registry import SessionRegistry
from godot_mcp_studio.tools.editor import register_editor_tools
from godot_mcp_studio.tools.node import register_node_tools
from godot_mcp_studio.tools.scene import register_scene_tools
from godot_mcp_studio.tools.session import register_session_tools
from godot_mcp_studio.transport.websocket import GodotWebSocketServer

logger = logging.getLogger(__name__)


@dataclass
class AppContext:
    registry: SessionRegistry
    ws_server: GodotWebSocketServer
    client: GodotClient


@asynccontextmanager
async def lifespan(server: FastMCP) -> AsyncIterator[AppContext]:
    registry = SessionRegistry()
    ws_server = GodotWebSocketServer(registry)
    client = GodotClient(ws_server, registry)

    # Start WebSocket server in background
    ws_task = asyncio.create_task(ws_server.start())
    logger.info("WebSocket server starting on port %d", ws_server.port)

    try:
        yield AppContext(registry=registry, ws_server=ws_server, client=client)
    finally:
        ws_task.cancel()
        try:
            await ws_task
        except asyncio.CancelledError:
            pass


def create_server() -> FastMCP:
    logging.basicConfig(level=logging.INFO, format="%(name)s | %(message)s")

    mcp = FastMCP(
        "Godot MCP Studio",
        instructions="Production-grade Godot MCP server with persistent editor integration. "
        "Use session tools to manage connections to Godot editor instances.",
        lifespan=lifespan,
    )

    register_session_tools(mcp)
    register_editor_tools(mcp)
    register_scene_tools(mcp)
    register_node_tools(mcp)
    register_session_resources(mcp)

    return mcp
