"""MCP tools for session management.

Top-level: ``session_activate`` (selecting which editor commands target).
``list`` collapses into ``session_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import session as session_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Session listing.

Resource form: ``godot://sessions`` — prefer for resource-aware clients.

Ops:
  • list()
        List every connected Godot editor with metadata: session_id, short
        name, godot_version, project_path, plugin_version, server_version,
        editor_pid, server_launch_mode, current_scene, play_state, readiness,
        connected_at, last_seen, is_active.
"""


def register_session_tools(mcp: FastMCP, *, include_non_core: bool = True) -> None:
    ## ``include_non_core`` is accepted for a uniform signature with other
    ## core-bearing domains. session has no core/non-core split.
    del include_non_core

    @mcp.tool()
    def session_activate(ctx: Context, session_id: str) -> dict:
        """Set the active Godot editor session for subsequent tool calls.

        Accepts either an exact session_id or a substring hint matched
        against the session's short name (project folder basename),
        project_path, or session_id. An exact id match always wins; a
        substring must resolve to exactly one session or the tool returns
        an error listing the candidates.

        Args:
            session_id: An exact session id (e.g. UUID from ``session_manage``
                with op="list") OR a substring hint like a project folder name
                ("test_project", "my_game").
        """
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_activate(runtime, session_id)

    register_manage_tool(
        mcp,
        tool_name="session_manage",
        description=_DESCRIPTION,
        ops={
            "list": session_handlers.session_list,
        },
    )
