"""MCP tools for script creation, reading, and management.

Top-level: ``script_create``, ``script_attach``, ``script_patch`` (high-traffic).
Everything else (detach, read, find_symbols) collapses into ``script_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import script as script_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Script (.gd) reading, detachment, and outline.

Resource form: ``godot://script/{path}`` — prefer for active-session reads.

Ops:
  • read(path)
        Read full source, line count, file size.
  • detach(path)
        Remove the currently attached script from a node. Undoable.
  • find_symbols(path)
        Outline a .gd — class_name, extends, functions, signals, @export vars.
"""


def register_script_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def script_create(
        ctx: Context,
        path: str,
        content: str = "",
        session_id: str = "",
    ) -> dict:
        """Create a new GDScript source file (.gd) on disk.

        Writes content to a .gd file in the project. Overwrites if it exists.
        Triggers a filesystem scan. New files include ``data.cleanup.rm``
        listing the .gd + .gd.uid sidecar; overwrite omits it.

        Args:
            path: res:// path (e.g. "res://scripts/player.gd").
            content: GDScript source. Empty creates a blank file.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_create(runtime, path=path, content=content)

    @mcp.tool(meta=DEFER_META)
    async def script_patch(
        ctx: Context,
        path: str,
        old_text: str,
        new_text: str,
        replace_all: bool = False,
        session_id: str = "",
    ) -> dict:
        """Anchor-based string-replace edit on a .gd file.

        Finds an exact ``old_text`` and replaces with ``new_text``. Fails
        on multiple matches unless ``replace_all=True``; fails on zero matches.
        Exact byte match (whitespace significant). Triggers filesystem scan.
        Not undoable via Ctrl+Z.

        Args:
            path: res:// path ending in .gd.
            old_text: Exact substring to find. Must be unique unless replace_all.
            new_text: Replacement (empty deletes).
            replace_all: Replace every occurrence. Default False.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_patch(
            runtime,
            path=path,
            old_text=old_text,
            new_text=new_text,
            replace_all=replace_all,
        )

    @mcp.tool(meta=DEFER_META)
    async def script_attach(
        ctx: Context,
        path: str,
        script_path: str,
        session_id: str = "",
    ) -> dict:
        """Attach a script to a node in the scene tree.

        Replaces any existing script on the node. Undoable.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
            script_path: res:// path of the .gd (e.g. "res://scripts/player.gd").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_attach(
            runtime,
            path=path,
            script_path=script_path,
        )

    register_manage_tool(
        mcp,
        tool_name="script_manage",
        description=_DESCRIPTION,
        ops={
            "read": script_handlers.script_read,
            "detach": script_handlers.script_detach,
            "find_symbols": script_handlers.script_find_symbols,
        },
    )
