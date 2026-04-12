"""MCP resources for scene data."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP


def register_scene_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://scene/current", mime_type="application/json")
    async def get_current_scene(ctx: Context) -> str:
        """Current scene path and root node info from the active Godot editor."""
        app = ctx.lifespan_context
        try:
            state = await app.client.send("get_editor_state")
            return json.dumps({
                "current_scene": state.get("current_scene", ""),
                "project_name": state.get("project_name", ""),
                "is_playing": state.get("is_playing", False),
            })
        except Exception as e:
            return json.dumps({"error": str(e), "connected": False})

    @mcp.resource("godot://scene/hierarchy", mime_type="application/json")
    async def get_scene_hierarchy(ctx: Context) -> str:
        """Full scene tree hierarchy from the active Godot editor."""
        app = ctx.lifespan_context
        try:
            return json.dumps(await app.client.send("get_scene_tree", {"depth": 10}))
        except Exception as e:
            return json.dumps({"error": str(e), "connected": False})
