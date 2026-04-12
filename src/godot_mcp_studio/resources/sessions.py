"""MCP resources for session state."""

from __future__ import annotations

from fastmcp import Context, FastMCP


def register_session_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://sessions")
    def get_sessions(ctx: Context) -> dict:
        """All connected Godot editor sessions and their metadata."""
        app = ctx.lifespan_context
        sessions = app.registry.list_all()
        active_id = app.registry.active_session_id
        return {
            "sessions": [{**s.to_dict(), "is_active": s.session_id == active_id} for s in sessions],
            "count": len(sessions),
        }
