"""MCP tools for script creation, reading, and management."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import script as script_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_script_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def script_create(
        ctx: Context,
        path: str,
        content: str = "",
        session_id: str = "",
    ) -> dict:
        """Create a new GDScript source file (.gd code file) on disk.

        Writes the given content to a .gd file in the Godot project.
        If the file already exists it will be overwritten. Triggers a
        filesystem scan so the editor picks up the new file.

        Args:
            path: File path starting with res:// (e.g. "res://scripts/player.gd").
            content: GDScript source code to write. Empty creates a blank file.
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
        """Patch (partial edit / string-replace) a GDScript file in place.

        Anchor-based edit: finds an exact occurrence of `old_text` in the file
        and replaces it with `new_text`. Use this instead of `script_create`
        when you only need to change a function, add a signal, or fix a line —
        it avoids rewriting (and possibly losing) the rest of the file.

        If `old_text` matches multiple places, the call fails unless
        `replace_all=true` is passed. If it matches zero places, the call
        fails. Exact byte match — whitespace is significant.

        Triggers a filesystem scan so the editor picks up the edit. Not
        undoable via Ctrl+Z (filesystem edits bypass editor undo).

        Args:
            path: File path starting with res:// and ending with .gd (e.g. "res://scripts/player.gd").
            old_text: Exact substring to find. Must be unique unless replace_all=true.
            new_text: Replacement text. Can be empty to delete.
            replace_all: If true, replace every occurrence. Default false.
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
    async def script_read(ctx: Context, path: str, session_id: str = "") -> dict:
        """Read the contents of a GDScript file.

        Returns the full source code, line count, and file size.

        Args:
            path: File path starting with res:// (e.g. "res://scripts/player.gd").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_read(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def script_attach(
        ctx: Context,
        path: str,
        script_path: str,
        session_id: str = "",
    ) -> dict:
        """Attach a script to a node in the scene tree.

        Assigns the script at script_path to the node at path. If the
        node already has a script, it is replaced. This operation is
        undoable via Ctrl+Z in the Godot editor.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
            script_path: File path of the script (e.g. "res://scripts/player.gd").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_attach(
            runtime,
            path=path,
            script_path=script_path,
        )

    @mcp.tool(meta=DEFER_META)
    async def script_detach(ctx: Context, path: str, session_id: str = "") -> dict:
        """Remove the script from a node.

        Detaches whatever script is currently assigned to the node.
        This operation is undoable via Ctrl+Z in the Godot editor.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_detach(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def script_find_symbols(ctx: Context, path: str, session_id: str = "") -> dict:
        """Inspect (outline) a GDScript file — functions, methods, signals, class_name, exports.

        Parses the script and returns its class_name, extends base,
        function definitions, signal declarations, and @export variables.

        Args:
            path: File path starting with res:// (e.g. "res://scripts/player.gd").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await script_handlers.script_find_symbols(runtime, path=path)
