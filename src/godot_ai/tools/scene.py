"""MCP tools for scene inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import scene as scene_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_scene_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def scene_get_hierarchy(
        ctx: Context,
        depth: int = 10,
        offset: int = 0,
        limit: int = 100,
        session_id: str = "",
    ) -> dict:
        """Get the scene tree hierarchy (nodes / game objects) from the open scene (level / map).

        Returns a paginated flat list of nodes with name, type, path,
        and child count. Walks the tree up to the specified depth.

        Args:
            depth: Maximum depth to walk. Default 10.
            offset: Number of nodes to skip. Default 0.
            limit: Maximum number of nodes to return. Default 100.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_get_hierarchy(
            runtime,
            depth=depth,
            offset=offset,
            limit=limit,
        )

    @mcp.tool(meta=DEFER_META)
    async def scene_get_roots(ctx: Context, session_id: str = "") -> dict:
        """Get all scenes currently open in the Godot editor.

        Returns a list of open scene file paths and which one is the
        currently edited scene.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_get_roots(runtime)

    @mcp.tool(meta=DEFER_META)
    async def scene_create(
        ctx: Context,
        path: str,
        root_type: str = "Node3D",
        root_name: str = "",
        session_id: str = "",
    ) -> dict:
        """Create a new scene file (level / map / prefab .tscn) and open it in the editor.

        Creates a scene with the specified root node type, saves it to
        disk, and opens it for editing.

        Args:
            path: File path for the new scene (e.g. "res://scenes/level.tscn").
            root_type: Godot node class for the root node. Default "Node3D".
            root_name: Custom name for the root node. Defaults to the filename
                basename when empty (e.g. "level" for level.tscn).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_create(
            runtime,
            path=path,
            root_type=root_type,
            root_name=root_name,
        )

    @mcp.tool(meta=DEFER_META)
    async def scene_open(ctx: Context, path: str, session_id: str = "") -> dict:
        """Open (load) an existing scene file (level / .tscn) in the editor.

        Args:
            path: File path of the scene to open (e.g. "res://main.tscn").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_open(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def scene_save(ctx: Context, session_id: str = "") -> dict:
        """Save the currently edited scene to disk.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_save(runtime)

    @mcp.tool(meta=DEFER_META)
    async def scene_save_as(ctx: Context, path: str, session_id: str = "") -> dict:
        """Save the currently edited scene to a new file path.

        Args:
            path: New file path for the scene (e.g. "res://scenes/level_copy.tscn").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_save_as(runtime, path=path)
