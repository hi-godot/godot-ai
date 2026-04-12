"""MCP tools for node creation and manipulation."""

from __future__ import annotations

from fastmcp import Context, FastMCP


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
            parent_path: Node path of the parent (e.g. "/root/Main"). Empty = scene root.
        """
        app = ctx.lifespan_context
        response = await app.client.send(
            "create_node",
            {"type": type, "name": name, "parent_path": parent_path},
        )
        if response.status == "error":
            error_msg = response.error.message if response.error else "Unknown error"
            return {"status": "error", "message": error_msg}
        return response.data
