"""MCP resources for project info and settings."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

COMMON_SETTINGS = [
    "application/config/name",
    "application/config/description",
    "application/run/main_scene",
    "display/window/size/viewport_width",
    "display/window/size/viewport_height",
    "rendering/renderer/rendering_method",
    "physics/2d/default_gravity",
    "physics/3d/default_gravity",
]


def register_project_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://project/info", mime_type="application/json")
    async def get_project_info(ctx: Context) -> str:
        """Project name, Godot version, paths, and play state."""
        app = ctx.lifespan_context
        session = app.registry.get_active()
        if session is None:
            return json.dumps({"error": "No active Godot session", "connected": False})

        info = session.to_dict()
        info.pop("connected_at", None)
        return json.dumps(info)

    @mcp.resource("godot://project/settings", mime_type="application/json")
    async def get_project_settings(ctx: Context) -> str:
        """Common project settings subset (display, physics, rendering)."""
        app = ctx.lifespan_context
        settings = {}
        errors = []
        for key in COMMON_SETTINGS:
            try:
                result = await app.client.send("get_project_setting", {"key": key})
                settings[key] = result.get("value")
            except Exception as e:
                errors.append({"key": key, "error": str(e)})

        return json.dumps({"settings": settings, "errors": errors if errors else None})
