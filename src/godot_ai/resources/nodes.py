"""MCP resource templates for node-level reads.

Path-keyed read resources mirror the most-used reads under
``node_get_properties`` and ``node_manage`` ops. Resource form is preferred
for active-session reads — the tool form remains available for clients
that need explicit ``session_id`` pinning.
"""

from __future__ import annotations

import json

from fastmcp import Context, FastMCP

from godot_ai.handlers import node as node_handlers
from godot_ai.runtime.direct import DirectRuntime


def register_node_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://node/{path}/properties", mime_type="application/json")
    async def get_node_properties(ctx: Context, path: str) -> str:
        """All properties of the node at scene path ``path`` (e.g. /Main/Camera3D)."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await node_handlers.node_get_properties(runtime, path=path))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})

    @mcp.resource("godot://node/{path}/children", mime_type="application/json")
    async def get_node_children(ctx: Context, path: str) -> str:
        """Direct children of the node at scene path ``path`` (name, type, path each)."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await node_handlers.node_get_children(runtime, path=path))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})

    @mcp.resource("godot://node/{path}/groups", mime_type="application/json")
    async def get_node_groups(ctx: Context, path: str) -> str:
        """Group names the node at scene path ``path`` belongs to."""
        runtime = DirectRuntime.from_context(ctx)
        try:
            return json.dumps(await node_handlers.node_get_groups(runtime, path=path))
        except Exception as exc:
            return json.dumps({"error": str(exc), "connected": False})
