"""MCP tools for configuring AI clients to use Godot AI."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import client as client_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_client_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def client_configure(ctx: Context, client: str) -> dict:
        """Configure an AI client to connect to the Godot AI server.

        Writes the necessary MCP server configuration so the client knows
        how to launch and connect to this server.

        Args:
            client: The client id to configure. Currently supported:
                claude_code, claude_desktop, codex, antigravity,
                cursor, windsurf, vscode, vscode_insiders, zed,
                gemini_cli, cline, kilo_code, roo_code, kiro, trae,
                cherry_studio, opencode, qwen_code.
                Call client_status to discover the live list.
        """
        runtime = DirectRuntime.from_context(ctx)
        return await client_handlers.client_configure(runtime, client=client)

    @mcp.tool(meta=DEFER_META)
    async def client_remove(ctx: Context, client: str) -> dict:
        """Remove the Godot AI MCP server entry from a client's config.

        Args:
            client: The client id to remove (same set as client_configure).
        """
        runtime = DirectRuntime.from_context(ctx)
        return await client_handlers.client_remove(runtime, client=client)

    @mcp.tool(meta=DEFER_META)
    async def client_status(ctx: Context) -> dict:
        """List every supported client and whether it's configured / installed.

        Returns a dict with a "clients" array. Each entry has:
            id            stable identifier (use with client_configure)
            display_name  human-readable name
            status        "configured" | "not_configured" | "error"
            installed     bool — true if the client appears to be present locally
        """
        runtime = DirectRuntime.from_context(ctx)
        return await client_handlers.client_status(runtime)
