"""MCP resource template for raw shader source reads."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import shader as shader_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def register_shader_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://shader/{path*}", mime_type="application/json")
    async def get_shader(ctx: Context, path: str) -> dict[str, Any]:
        """Read a .gdshader/.gdshaderinc file at the given res:// path.

        ``path`` is the res:// path with the ``res://`` prefix dropped — e.g.
        ``godot://shader/shaders/pulse.gdshader`` reads
        ``res://shaders/pulse.gdshader``.
        """
        runtime = DirectRuntime.from_context(ctx)
        full_path = f"res://{path}" if not path.startswith("res://") else path
        return await safe_payload(shader_handlers.shader_get(runtime, path=full_path))
