"""MCP tools for scene authoring.

Top-level: ``scene_get_hierarchy`` (core read), ``scene_open``, ``scene_save``.
Everything else (create, save_as, get_roots) collapses into ``scene_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import scene as scene_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Scene authoring (create, save_as, list open roots).

Resource form: ``godot://scene/current`` and ``godot://scene/hierarchy``
— prefer for active-session reads.

Ops:
  • create(path, root_type="Node3D", root_name="")
        Create a new .tscn with the given root and open it. root_name
        defaults to filename basename when empty.
  • save_as(path)
        Save the currently edited scene to a new file path.
  • get_roots()
        List scenes currently open in the editor; flag the edited one.
"""


def register_scene_tools(mcp: FastMCP, *, include_non_core: bool = True) -> None:
    @mcp.tool()
    async def scene_get_hierarchy(
        ctx: Context,
        depth: int = 10,
        offset: int = 0,
        limit: int = 100,
        session_id: str = "",
    ) -> dict:
        """Get the scene tree hierarchy from the open scene.

        Returns a paginated flat list of nodes with name, type, path, and
        child count. Walks up to the specified depth.

        Resource form: ``godot://scene/hierarchy`` — prefer for active-session
        reads.

        Args:
            depth: Maximum walk depth. Default 10.
            offset: Number of nodes to skip. Default 0.
            limit: Max number of nodes to return. Default 100.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_get_hierarchy(
            runtime,
            depth=depth,
            offset=offset,
            limit=limit,
        )

    if not include_non_core:
        return

    @mcp.tool(meta=DEFER_META)
    async def scene_open(ctx: Context, path: str, session_id: str = "") -> dict:
        """Open an existing scene file (.tscn) in the editor.

        If ``path`` is already the currently edited scene this is a no-op
        — the in-memory state (including any unsaved MCP mutations) is
        preserved. To force a re-read from disk, ``scene_open`` a different
        scene first or save & reload manually.

        Args:
            path: File path of the scene to open (e.g. "res://main.tscn").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_open(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def scene_save(ctx: Context, session_id: str = "") -> dict:
        """Save the currently edited scene to disk.

        Args:
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await scene_handlers.scene_save(runtime)

    register_manage_tool(
        mcp,
        tool_name="scene_manage",
        description=_DESCRIPTION,
        ops={
            "create": scene_handlers.scene_create,
            "save_as": scene_handlers.scene_save_as,
            "get_roots": scene_handlers.scene_get_roots,
        },
    )
