"""MCP tools for project settings and filesystem search."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.tools._pagination import paginate


def register_project_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def project_settings_get(ctx: Context, key: str) -> dict:
        """Get a Godot project setting by key.

        Reads from ProjectSettings (e.g. "application/config/name",
        "display/window/size/viewport_width", "physics/2d/default_gravity").

        Args:
            key: The setting key path (e.g. "application/config/name").
        """
        app = ctx.lifespan_context
        return await app.client.send("get_project_setting", {"key": key})

    @mcp.tool()
    async def filesystem_search(
        ctx: Context,
        name: str = "",
        type: str = "",
        path: str = "",
        offset: int = 0,
        limit: int = 100,
    ) -> dict:
        """Search the Godot project filesystem via EditorFileSystem.

        Finds files by name, resource type, or path pattern. At least one
        filter must be provided. Results are paginated.

        Args:
            name: Filter by filename (case-insensitive substring match).
            type: Filter by resource type (e.g. "PackedScene", "GDScript", "Texture2D").
            path: Filter by path (case-insensitive substring match).
            offset: Number of results to skip. Default 0.
            limit: Maximum number of results to return. Default 100.
        """
        app = ctx.lifespan_context
        params: dict = {}
        if name:
            params["name"] = name
        if type:
            params["type"] = type
        if path:
            params["path"] = path
        result = await app.client.send("search_filesystem", params)
        return paginate(result.get("files", []), offset, limit, key="files")
