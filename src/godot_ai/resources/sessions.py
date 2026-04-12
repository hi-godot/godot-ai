"""MCP resources for session state."""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP


def register_session_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://sessions", mime_type="application/json")
    def get_sessions(ctx: Context) -> str:
        """All connected Godot editor sessions and their metadata."""
        app = ctx.lifespan_context
        sessions = app.registry.list_all()
        active_id = app.registry.active_session_id
        return json.dumps({
            "sessions": [{**s.to_dict(), "is_active": s.session_id == active_id} for s in sessions],
            "count": len(sessions),
        })
