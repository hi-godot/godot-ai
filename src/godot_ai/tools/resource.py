"""MCP tools for resource search, inspection, and assignment."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import resource as resource_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_resource_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def resource_search(
        ctx: Context,
        type: str = "",
        path: str = "",
        offset: int = 0,
        limit: int = 100,
        session_id: str = "",
    ) -> dict:
        """Search for resources (assets: meshes, textures, materials, scenes) by type or path.

        At least one filter must be provided. Results are paginated.
        Type matching includes subclasses (e.g. type="Texture2D" finds
        CompressedTexture2D, ImageTexture, etc.).

        Args:
            type: Resource type to filter by (e.g. "PackedScene", "Texture2D", "Material").
            path: Substring match on the resource file path (case-insensitive).
            offset: Number of results to skip. Default 0.
            limit: Maximum number of results to return. Default 100.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await resource_handlers.resource_search(
            runtime,
            type=type,
            path=path,
            offset=offset,
            limit=limit,
        )

    @mcp.tool(meta=DEFER_META)
    async def resource_load(ctx: Context, path: str, session_id: str = "") -> dict:
        """Inspect a resource's (asset's) properties — materials, meshes, textures, .tres files.

        Loads the resource at the given path and returns its type and
        all editor-visible properties with their current values.

        Args:
            path: File path starting with res:// (e.g. "res://materials/ground.tres").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await resource_handlers.resource_load(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def resource_assign(
        ctx: Context,
        path: str,
        property: str,
        resource_path: str,
        session_id: str = "",
    ) -> dict:
        """Assign a resource (asset — mesh, texture, material, etc.) to a node property.

        Loads the resource at resource_path and sets it on the specified
        property of the node at path. This operation is undoable via
        Ctrl+Z in the Godot editor.

        Args:
            path: Scene path of the node (e.g. "/Main/Ground").
            property: Property name that accepts a resource (e.g. "mesh", "material_override").
            resource_path: File path of the resource (e.g. "res://meshes/cube.tres").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await resource_handlers.resource_assign(
            runtime,
            path=path,
            property=property,
            resource_path=resource_path,
        )
