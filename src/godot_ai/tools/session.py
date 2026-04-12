"""MCP tools for session management."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import session as session_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_session_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    def session_list(ctx: Context) -> dict:
        """List all connected Godot editor sessions.

        Returns session metadata including Godot version, project path,
        and connection state for each connected editor instance.
        """
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_list(runtime)

    @mcp.tool()
    def session_activate(ctx: Context, session_id: str) -> dict:
        """Set the active Godot editor session.

        Subsequent tool calls that don't specify a session_id will
        target this session.

        Args:
            session_id: The ID of the session to activate.
        """
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_activate(runtime, session_id)
