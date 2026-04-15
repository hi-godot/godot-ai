"""MCP tools for session management."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import session as session_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_session_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    def session_list(ctx: Context) -> dict:
        """List all connected Godot editor sessions.

        Returns session metadata for each connected editor instance:
        session_id, short name (project basename), godot_version, project_path,
        editor_pid, current_scene, play_state, readiness, connected_at,
        last_seen (heartbeat timestamp), and is_active flag.
        """
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_list(runtime)

    @mcp.tool()
    def session_activate(ctx: Context, session_id: str) -> dict:
        """Set the active Godot editor session for subsequent tool calls.

        Accepts either an exact session_id or a substring hint matched
        against the session's short name (project folder basename),
        project_path, or session_id. An exact id match always wins; a
        substring must resolve to exactly one session or the tool returns
        an error listing the candidates.

        Args:
            session_id: An exact session id (e.g. the UUID from
                session_list) OR a substring hint like a project folder
                name ("test_project", "my_game") — whichever is more
                convenient for the caller.
        """
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_activate(runtime, session_id)
