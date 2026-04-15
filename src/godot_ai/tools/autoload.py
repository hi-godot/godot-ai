"""MCP tools for managing Godot autoload singletons."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import autoload as autoload_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_autoload_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def autoload_list(ctx: Context, session_id: str = "") -> dict:
        """List all registered autoload singletons (global scripts / scenes accessible by name).

        Returns each autoload's name, script/scene path, and whether
        it's a singleton (accessible via name globally).

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await autoload_handlers.autoload_list(runtime)

    @mcp.tool(meta=DEFER_META)
    async def autoload_add(
        ctx: Context,
        name: str,
        path: str,
        singleton: bool = True,
        session_id: str = "",
    ) -> dict:
        """Add a new autoload singleton to the project.

        Registers a GDScript or PackedScene as an autoload that loads
        automatically when the project starts. Saved to project.godot.

        Args:
            name: Name for the autoload (e.g. "GameManager", "AudioBus").
            path: Resource path to the script or scene (e.g. "res://autoloads/game_manager.gd").
            singleton: If true, accessible globally by name. Default true.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await autoload_handlers.autoload_add(
            runtime, name=name, path=path, singleton=singleton
        )

    @mcp.tool(meta=DEFER_META)
    async def autoload_remove(ctx: Context, name: str, session_id: str = "") -> dict:
        """Remove an autoload singleton from the project.

        Removes the autoload registration from project.godot.
        Does not delete the underlying script or scene file.

        Args:
            name: Name of the autoload to remove.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await autoload_handlers.autoload_remove(runtime, name=name)
