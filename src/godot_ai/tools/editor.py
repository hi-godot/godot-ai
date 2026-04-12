"""MCP tools for editor state inspection."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_editor_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def editor_state(ctx: Context) -> dict:
        """Get the current Godot editor state.

        Returns Godot version, project name, current scene path,
        and whether the project is currently playing.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await editor_handlers.editor_state(runtime)

    @mcp.tool()
    async def editor_selection_get(ctx: Context) -> dict:
        """Get the currently selected nodes in the Godot editor.

        Returns a list of selected node paths.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await editor_handlers.editor_selection_get(runtime)

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
        runtime = DirectRuntime.from_context(ctx)
        return await editor_handlers.logs_read(runtime, count=count, offset=offset)

    @mcp.tool()
    async def reload_plugin(ctx: Context) -> dict:
        """Reload the Godot editor plugin and wait for it to reconnect.

        Sends a reload command to the plugin, which disables and re-enables
        itself on the next frame. The tool then waits for the new session
        to connect before returning.

        Requires the MCP server to be running externally (not started by
        the plugin), otherwise the reload will kill the server process.
        Start with: python -m godot_ai --transport streamable-http --port 8000 --reload
        """
        runtime = DirectRuntime.from_context(ctx)
        return await editor_handlers.reload_plugin(runtime)
