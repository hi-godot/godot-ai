"""MCP tools for node creation and manipulation."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import node as node_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_node_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def node_create(
        ctx: Context,
        type: str,
        name: str = "",
        parent_path: str = "",
    ) -> dict:
        """Create a new node in the scene tree.

        Creates a node of the given type and adds it as a child of the
        specified parent. If no parent is given, adds to the scene root.
        If no name is given, Godot assigns one based on the type.

        Args:
            type: The Godot node class (e.g. "Node3D", "MeshInstance3D", "Camera3D").
            name: Optional name for the node.
            parent_path: Node path of the parent (e.g. "/Main"). Empty = scene root.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await node_handlers.node_create(
            runtime,
            type=type,
            name=name,
            parent_path=parent_path,
        )

    @mcp.tool()
    async def node_find(
        ctx: Context,
        name: str = "",
        type: str = "",
        group: str = "",
        offset: int = 0,
        limit: int = 100,
    ) -> dict:
        """Find nodes in the scene tree by name, type, or group.

        At least one filter must be provided. Filters are combined with AND
        logic — a node must match all specified filters. Results are paginated.

        Args:
            name: Substring match on node name (case-insensitive).
            type: Exact Godot class name (e.g. "MeshInstance3D").
            group: Group name the node must belong to.
            offset: Number of results to skip. Default 0.
            limit: Maximum number of results to return. Default 100.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await node_handlers.node_find(
            runtime,
            name=name,
            type=type,
            group=group,
            offset=offset,
            limit=limit,
        )

    @mcp.tool()
    async def node_get_properties(ctx: Context, path: str) -> dict:
        """Get all properties of a node.

        Returns the property list with current values for the node at
        the given scene path.

        Args:
            path: Scene path of the node (e.g. "/Main/Camera3D").
        """
        runtime = DirectRuntime.from_context(ctx)
        return await node_handlers.node_get_properties(runtime, path=path)

    @mcp.tool()
    async def node_get_children(ctx: Context, path: str) -> dict:
        """Get the direct children of a node.

        Returns name, type, and path for each immediate child of the
        specified node.

        Args:
            path: Scene path of the parent node (e.g. "/Main").
        """
        runtime = DirectRuntime.from_context(ctx)
        return await node_handlers.node_get_children(runtime, path=path)

    @mcp.tool()
    async def node_get_groups(ctx: Context, path: str) -> dict:
        """Get the groups a node belongs to.

        Returns the list of group names for the node at the given path.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
        """
        runtime = DirectRuntime.from_context(ctx)
        return await node_handlers.node_get_groups(runtime, path=path)
