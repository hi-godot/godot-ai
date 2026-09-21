"""MCP resource template for VisualShader graph reads."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import visual_shader as visual_shader_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def register_visual_shader_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://visual_shader/{path*}", mime_type="application/json")
    async def get_visual_shader(ctx: Context, path: str) -> dict[str, Any]:
        """Read a VisualShader graph at the given res:// path.

        ``path`` is the res:// path with the ``res://`` prefix dropped — e.g.
        ``godot://visual_shader/shaders/pulse.tres`` reads
        ``res://shaders/pulse.tres``.
        """
        runtime = DirectRuntime.from_context(ctx)
        full_path = f"res://{path}" if not path.startswith("res://") else path
        return await safe_payload(visual_shader_handlers.get_graph(runtime, path=full_path))
