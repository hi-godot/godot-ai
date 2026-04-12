"""MCP tools for editor state inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.tools._pagination import paginate


def register_editor_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def editor_state(ctx: Context) -> dict:
        """Get the current Godot editor state.

        Returns Godot version, project name, current scene path,
        and whether the project is currently playing.
        """
        app = ctx.lifespan_context
        return await app.client.send("get_editor_state")

    @mcp.tool()
    async def editor_selection_get(ctx: Context) -> dict:
        """Get the currently selected nodes in the Godot editor.

        Returns a list of selected node paths.
        """
        app = ctx.lifespan_context
        return await app.client.send("get_selection")

    @mcp.tool()
    async def logs_read(
        ctx: Context,
        count: int = 50,
        offset: int = 0,
    ) -> dict:
        """Read recent log lines from the Godot editor console.

        Returns paginated log lines captured by the MCP plugin,
        including MCP command traffic when logging is enabled.
        The buffer holds up to 500 lines; pagination windows into that.

        Args:
            count: Maximum number of lines to return. Default 50.
            offset: Number of lines to skip from the start. Default 0.
        """
        app = ctx.lifespan_context
        # Fetch the full buffer so offset/limit/total_count are accurate
        result = await app.client.send("get_logs", {"count": 500})
        lines = result.get("lines", [])
        return paginate(lines, offset, count, key="lines")
