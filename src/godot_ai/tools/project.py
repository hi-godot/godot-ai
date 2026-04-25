"""MCP tools for project run/stop and project settings.

Top-level: ``project_run`` (high-traffic). Everything else (stop, settings_get,
settings_set) collapses into ``project_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import project as project_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Project run/stop and project.godot settings.

Resource form: ``godot://project/info`` and ``godot://project/settings``
— prefer for active-session reads.

Ops:
  • stop()
        Stop the running project (game). Errors if not running.
  • settings_get(key)
        Read a ProjectSettings key (e.g. "application/config/name").
  • settings_set(key, value)
        Write a ProjectSettings key and persist to project.godot.
"""


def register_project_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def project_run(
        ctx: Context,
        mode: str = "main",
        scene: str = "",
        autosave: bool = True,
        session_id: str = "",
    ) -> dict:
        """Run (play) the Godot project from the editor.

        Modes:
        - "main": Run the project's main scene (default).
        - "current": Run the currently open scene.
        - "custom": Run a specific scene (requires ``scene``).

        Args:
            mode: "main" | "current" | "custom". Default "main".
            scene: Scene path (e.g. "res://levels/level1.tscn"). Required for "custom".
            autosave: When True (default), Godot persists in-memory MCP scene
                mutations to disk before running. Pass False for smoke tests
                where MCP edits should stay in memory.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await project_handlers.project_run(
            runtime, mode=mode, scene=scene, autosave=autosave
        )

    register_manage_tool(
        mcp,
        tool_name="project_manage",
        description=_DESCRIPTION,
        ops={
            "stop": project_handlers.project_stop,
            "settings_get": project_handlers.project_settings_get,
            "settings_set": project_handlers.project_settings_set,
        },
    )
