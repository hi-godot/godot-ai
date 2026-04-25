"""MCP resources for editor state — selection and logs."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.resources import safe_json
from godot_ai.runtime.direct import DirectRuntime


def register_editor_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://selection/current", mime_type="application/json")
    async def get_current_selection(ctx: Context) -> str:
        """Currently selected nodes in the Godot editor."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_json(editor_handlers.selection_resource_data(runtime))

    @mcp.resource("godot://logs/recent", mime_type="application/json")
    async def get_recent_logs(ctx: Context) -> str:
        """Last 100 log lines from the Godot editor console."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_json(editor_handlers.logs_resource_data(runtime))
