"""MCP resources for scene data."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

from godot_ai.handlers import scene as scene_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_scene_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://scene/current", mime_type="application/json")
    async def get_current_scene(ctx: Context) -> str:
        """Current scene path and root node info from the active Godot editor."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await scene_handlers.current_scene_resource_data(runtime))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})

    @mcp.resource("godot://scene/hierarchy", mime_type="application/json")
    async def get_scene_hierarchy(ctx: Context) -> str:
        """Full scene tree hierarchy from the active Godot editor."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await scene_handlers.scene_hierarchy_resource_data(runtime))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})
