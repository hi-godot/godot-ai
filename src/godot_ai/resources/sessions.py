"""MCP resources for session state."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import session as session_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_session_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://sessions", mime_type="application/json")
    def get_sessions(ctx: Context) -> dict[str, Any]:
        """All connected Godot editor sessions and their metadata."""
        runtime = DirectRuntime.from_context(ctx)
        return session_handlers.session_resource_data(runtime)
