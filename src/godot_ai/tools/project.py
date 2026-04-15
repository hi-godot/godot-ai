"""MCP tools for project settings and run/stop."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import project as project_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_project_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def project_run(
        ctx: Context,
        mode: str = "main",
        scene: str = "",
        session_id: str = "",
    ) -> dict:
        """Run (play / start) the Godot project (game) from the editor.

        Starts the game in one of three modes:
        - "main": Run the project's main scene (default).
        - "current": Run the currently open scene.
        - "custom": Run a specific scene by path (requires `scene` param).

        Args:
            mode: Run mode — "main", "current", or "custom". Default "main".
            scene: Scene path (e.g. "res://levels/level1.tscn"). Required when mode is "custom".
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await project_handlers.project_run(runtime, mode=mode, scene=scene)

    @mcp.tool(meta=DEFER_META)
    async def project_stop(ctx: Context, session_id: str = "") -> dict:
        """Stop (halt / exit) the running Godot project (game).

        Stops the currently playing scene. Returns an error if the project
        is not running.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await project_handlers.project_stop(runtime)

    @mcp.tool(meta=DEFER_META)
    async def project_settings_get(ctx: Context, key: str, session_id: str = "") -> dict:
        """Get a Godot project setting by key.

        Reads from ProjectSettings (e.g. "application/config/name",
        "display/window/size/viewport_width", "physics/2d/default_gravity").

        Args:
            key: The setting key path (e.g. "application/config/name").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await project_handlers.project_settings_get(runtime, key=key)

    @mcp.tool(meta=DEFER_META)
    async def project_settings_set(
        ctx: Context,
        key: str,
        value: Any,
        session_id: str = "",
    ) -> dict:
        """Set a Godot project setting by key.

        Writes to ProjectSettings and saves to project.godot.
        Common keys: "application/config/name",
        "display/window/size/viewport_width", "physics/2d/default_gravity".

        Args:
            key: The setting key path (e.g. "application/config/name").
            value: The value to set (string, int, float, or bool).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await project_handlers.project_settings_set(runtime, key=key, value=value)
