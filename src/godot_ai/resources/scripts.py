"""MCP resource template for GDScript source reads."""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import script as script_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def register_script_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://script/{path*}", mime_type="application/json")
    async def get_script(ctx: Context, path: str) -> dict[str, Any]:
        """Read a GDScript file at the given res:// path.

        ``path`` is the res:// path with the ``res://`` prefix dropped — e.g.
        ``godot://script/scripts/player.gd`` reads ``res://scripts/player.gd``.
        """
        runtime = DirectRuntime.from_context(ctx)
        full_path = f"res://{path}" if not path.startswith("res://") else path
        return await safe_payload(script_handlers.script_read(runtime, path=full_path))
