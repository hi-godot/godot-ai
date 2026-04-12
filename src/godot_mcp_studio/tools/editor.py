"""MCP tools for editor state inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP


def register_editor_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def editor_state(ctx: Context) -> dict:
        """Get the current Godot editor state.

        Returns Godot version, project name, current scene path,
        and whether the project is currently playing.
        """
        app = ctx.lifespan_context
        response = await app.client.send("get_editor_state")
        return response.data

    @mcp.tool()
    async def editor_selection_get(ctx: Context) -> dict:
        """Get the currently selected nodes in the Godot editor.

        Returns a list of selected node paths.
        """
        app = ctx.lifespan_context
        response = await app.client.send("get_selection")
        return response.data
