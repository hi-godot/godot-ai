"""MCP resources for editor state — selection and logs."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_editor_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://selection/current", mime_type="application/json")
    async def get_current_selection(ctx: Context) -> str:
        """Currently selected nodes in the Godot editor."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await editor_handlers.selection_resource_data(runtime))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})

    @mcp.resource("godot://logs/recent", mime_type="application/json")
    async def get_recent_logs(ctx: Context) -> str:
        """Last 100 log lines from the Godot editor console."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await editor_handlers.logs_resource_data(runtime))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})
