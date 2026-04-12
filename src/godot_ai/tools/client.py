"""MCP tools for configuring AI clients to use Godot MCP Studio."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import client as client_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_client_tools(mcp: FastMCP) -> None:
    @mcp.tool()
    async def client_configure(ctx: Context, client: str) -> dict:
        """Configure an AI client to connect to the Godot MCP Studio server.

        Writes the necessary MCP server configuration so the client knows
        how to launch and connect to this server.

        Args:
            client: The client to configure. Options: "claude_code", "codex", "antigravity".
        """
        runtime = DirectRuntime.from_context(ctx)
        return await client_handlers.client_configure(runtime, client=client)

    @mcp.tool()
    async def client_status(ctx: Context) -> dict:
        """Check which AI clients are configured to use Godot MCP Studio.

        Returns the configuration status of each supported client:
        "configured", "not_configured", or "error".
        """
        runtime = DirectRuntime.from_context(ctx)
        return await client_handlers.client_status(runtime)
