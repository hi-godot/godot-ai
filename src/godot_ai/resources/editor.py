"""MCP resources for editor state — selection and logs."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP


def register_editor_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://selection/current", mime_type="application/json")
    async def get_current_selection(ctx: Context) -> str:
        """Currently selected nodes in the Godot editor."""
        app = ctx.lifespan_context
        try:
            return json.dumps(await app.client.send("get_selection"))
        except Exception as e:
            return json.dumps({"error": str(e), "connected": False})

    @mcp.resource("godot://logs/recent", mime_type="application/json")
    async def get_recent_logs(ctx: Context) -> str:
        """Last 100 log lines from the Godot editor console."""
        app = ctx.lifespan_context
        try:
            return json.dumps(await app.client.send("get_logs", {"count": 100}))
        except Exception as e:
            return json.dumps({"error": str(e), "connected": False})
