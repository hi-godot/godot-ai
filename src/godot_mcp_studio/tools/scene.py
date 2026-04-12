"""MCP tools for scene inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP


def register_scene_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def scene_get_hierarchy(ctx: Context, depth: int = 10) -> dict:
        """Get the scene tree hierarchy from the currently open scene.

        Returns a flat list of nodes with name, type, path, and child count.
        Walks the tree up to the specified depth.

        Args:
            depth: Maximum depth to walk. Default 10.
        """
        app = ctx.lifespan_context
        response = await app.client.send("get_scene_tree", {"depth": depth})
        return response.data
