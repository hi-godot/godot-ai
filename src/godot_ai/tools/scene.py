"""MCP tools for scene inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP


def _paginate(items: list, offset: int, limit: int) -> dict:
    """Apply offset/limit pagination to a list, returning pagination metadata."""
    total_count = len(items)
    page = items[offset : offset + limit]
    return {
        "items": page,
        "total_count": total_count,
        "offset": offset,
        "limit": limit,
        "has_more": offset + limit < total_count,
    }


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
        app = ctx.lifespan_context
        result = await app.client.send("get_scene_tree", {"depth": depth})
        nodes = result.get("nodes", [])
        page = _paginate(nodes, offset, limit)
        return {
            "nodes": page["items"],
            "root": result.get("root", ""),
            "total_count": page["total_count"],
            "offset": page["offset"],
            "limit": page["limit"],
            "has_more": page["has_more"],
        }

    @mcp.tool()
    async def scene_get_roots(ctx: Context) -> dict:
        """Get all scenes currently open in the Godot editor.

        Returns a list of open scene file paths and which one is the
        currently edited scene.
        """
        app = ctx.lifespan_context
        return await app.client.send("get_open_scenes")
