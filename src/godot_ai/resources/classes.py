"""MCP resource template for Godot ClassDB metadata."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import api as api_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def register_class_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://class/{class_name}", mime_type="application/json")
    async def get_class_info(ctx: Context, class_name: str) -> dict[str, Any]:
        """ClassDB metadata for a class in the active Godot editor."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(api_handlers.api_get_class(runtime, class_name=class_name))
