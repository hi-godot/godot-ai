"""MCP tool for configuring AI clients to use Godot AI."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import client as client_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Configure AI clients to use this Godot AI MCP server. Writes / removes
client config files (Claude Code, Codex, Antigravity, Cursor, Windsurf,
Zed, etc.).

Ops:
  • status()
        List every supported client with id, display_name, status
        (configured | not_configured | configured_mismatch | error),
        and installed flag.
  • configure(client)
        Write the MCP server entry into the named client's config file.
        ``client`` is one of the ids returned by status().
  • remove(client)
        Remove this server's entry from the named client's config.
"""


def register_client_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="client_manage",
        description=_DESCRIPTION,
        ops={
            "status": client_handlers.client_status,
            "configure": client_handlers.client_configure,
            "remove": client_handlers.client_remove,
        },
    )
