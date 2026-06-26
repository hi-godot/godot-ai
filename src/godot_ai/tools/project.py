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
        Stop the running project (game). Takes no params — call as
        ``project_manage(op="stop")`` or with ``params={}``. Idempotent:
        succeeds with ``was_running=false`` if the project isn't running.
        Do NOT pass extra fields like ``force`` or ``reason`` inside
        ``params`` — only the registered keys are accepted (here, none).
        For multi-editor setups, pass ``session_id`` as a sibling of
        ``op``/``params``, not inside ``params``.
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

        Idempotent: if the project is already running, returns success with
        ``data.was_already_running=true`` (no scene switch). To switch scenes,
        call ``project_manage(op="stop")`` first, then ``project_run`` again.

        After starting playback, waits briefly for the Godot AI game helper to
        check in. The response includes ``game_status``, ``helper_live``
        (status == "live"), ``session_active`` (status not in {"not_live",
        "stopped"}), and any ``recent_errors`` observed during the run window.
        The top-level booleans mirror the same fields inside ``game_status``.
        ``game_status.status="not_live"`` means playback launched but the game
        did not become live before the helper-ready window elapsed;
        ``"no_helper"`` means the project has no _mcp_game_helper autoload, as
        with some headless/custom-main-loop setups (helper_live=false,
        session_active=true); ``"stopped"`` means playback stopped or never
        became active before liveness could be confirmed (helper_live=false,
        session_active=false). Poll ``editor_state`` to see late transitions.

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
        read_resource_forms={
            ## stop ends a play session; not a read in the URI sense.
            "stop": None,
            "settings_get": "godot://project/settings",
        },
    )
