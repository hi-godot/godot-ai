"""MCP resources for project info and settings."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

from godot_ai.handlers import project as project_handlers
from godot_ai.runtime.direct import DirectRuntime

COMMON_SETTINGS = project_handlers.COMMON_SETTINGS


def register_project_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://project/info", mime_type="application/json")
    async def get_project_info(ctx: Context) -> str:
        """Project name, Godot version, paths, and play state."""
        runtime = DirectRuntime.from_context(ctx)
        return json.dumps(project_handlers.project_info_resource_data(runtime))

    @mcp.resource("godot://project/settings", mime_type="application/json")
    async def get_project_settings(ctx: Context) -> str:
        """Common project settings subset (display, physics, rendering)."""
        runtime = DirectRuntime.from_context(ctx)
        return json.dumps(await project_handlers.project_settings_resource_data(runtime))
