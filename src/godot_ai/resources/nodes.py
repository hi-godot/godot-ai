"""MCP resource templates for node-level reads.

Path-keyed read resources mirror the most-used reads under
``node_get_properties`` and ``node_manage`` ops. Resource form is preferred
for active-session reads — the tool form remains available for clients
that need explicit ``session_id`` pinning.

URI shape: ``godot://node/{path*}/<verb>`` — the ``{path*}`` segment is the
RFC 6570 greedy expansion form, capturing the full slash-bearing scene path
(e.g. ``Main/Camera3D``) without the leading ``/``. The handler re-prefixes
``/`` before delegating to the shared handler so existing tool tests and
GDScript handlers see the same canonical scene path.
"""

from __future__ import annotations

from typing import Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import node as node_handlers
from godot_ai.resources import safe_payload
from godot_ai.runtime.direct import DirectRuntime


def _normalize(path: str) -> str:
    """Re-prefix the resource ``{path*}`` value with a leading ``/``."""
    return path if path.startswith("/") else f"/{path}"


def register_node_resources(mcp: FastMCP) -> None:
    @mcp.resource("godot://node/{path*}/properties", mime_type="application/json")
    async def get_node_properties(ctx: Context, path: str) -> dict[str, Any]:
        """All properties of the node at scene path ``path`` (e.g. Main/Camera3D)."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(node_handlers.node_get_properties(runtime, path=_normalize(path)))

    @mcp.resource("godot://node/{path*}/children", mime_type="application/json")
    async def get_node_children(ctx: Context, path: str) -> dict[str, Any]:
        """Direct children of the node at scene path ``path`` (name, type, path each)."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(node_handlers.node_get_children(runtime, path=_normalize(path)))

    @mcp.resource("godot://node/{path*}/groups", mime_type="application/json")
    async def get_node_groups(ctx: Context, path: str) -> dict[str, Any]:
        """Group names the node at scene path ``path`` belongs to."""
        runtime = DirectRuntime.from_context(ctx)
        return await safe_payload(node_handlers.node_get_groups(runtime, path=_normalize(path)))
