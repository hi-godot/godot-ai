"""MCP tools for session management."""

from __future__ import annotations

from fastmcp import Context, FastMCP


def register_session_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    def session_list(ctx: Context) -> dict:
        """List all connected Godot editor sessions.

        Returns session metadata including Godot version, project path,
        and connection state for each connected editor instance.
        """
        app = ctx.lifespan_context
        sessions = app.registry.list_all()
        active_id = app.registry.active_session_id
        return {
            "sessions": [{**s.to_dict(), "is_active": s.session_id == active_id} for s in sessions],
            "count": len(sessions),
        }

    @mcp.tool()
    def session_activate(ctx: Context, session_id: str) -> dict:
        """Set the active Godot editor session.

        Subsequent tool calls that don't specify a session_id will
        target this session.

        Args:
            session_id: The ID of the session to activate.
        """
        app = ctx.lifespan_context
        try:
            app.registry.set_active(session_id)
            return {"status": "ok", "active_session_id": session_id}
        except KeyError:
            return {"status": "error", "message": f"Session {session_id} not found"}
