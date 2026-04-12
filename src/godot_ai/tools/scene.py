"""MCP tools for scene inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import scene as scene_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_scene_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def scene_get_hierarchy(
        ctx: Context,
        depth: int = 10,
        offset: int = 0,
        limit: int = 100,
    ) -> dict:
        """Get the scene tree hierarchy from the currently open scene.

        Returns a paginated flat list of nodes with name, type, path,
        and child count. Walks the tree up to the specified depth.

        Args:
            depth: Maximum depth to walk. Default 10.
            offset: Number of nodes to skip. Default 0.
            limit: Maximum number of nodes to return. Default 100.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await scene_handlers.scene_get_hierarchy(
            runtime,
            depth=depth,
            offset=offset,
            limit=limit,
        )

    @mcp.tool()
    async def scene_get_roots(ctx: Context) -> dict:
        """Get all scenes currently open in the Godot editor.

        Returns a list of open scene file paths and which one is the
        currently edited scene.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await scene_handlers.scene_get_roots(runtime)
