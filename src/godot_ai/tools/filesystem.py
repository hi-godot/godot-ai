"""MCP tools for reading and writing text files in the Godot project."""

from __future__ import annotations

from typing import Annotated

from fastmcp import Context, FastMCP

from godot_ai.handlers import filesystem as filesystem_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_filesystem_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def filesystem_read_text(ctx: Context, path: str, session_id: str = "") -> dict:
        """Read a text file from the Godot project.

        Returns the full file content, size, and line count.
        Works with any text file (scripts, configs, shaders, etc.).

        Args:
            path: File path starting with res:// (e.g. "res://project.godot").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await filesystem_handlers.filesystem_read_text(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def filesystem_write_text(
        ctx: Context,
        path: str,
        content: str = "",
        session_id: str = "",
    ) -> dict:
        """Write a text file to the Godot project.

        Creates or overwrites the file at the given path and triggers
        a filesystem scan so the editor picks up changes. Parent
        directories are created automatically if needed.

        Args:
            path: File path starting with res:// (e.g. "res://data/config.json").
            content: Text content to write. Empty creates a blank file.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await filesystem_handlers.filesystem_write_text(
            runtime,
            path=path,
            content=content,
        )

    @mcp.tool(meta=DEFER_META)
    async def filesystem_reimport(
        ctx: Context,
        paths: Annotated[list[str], JsonCoerced],
        session_id: str = "",
    ) -> dict:
        """Force reimport of specific files / assets in the Godot project.

        Triggers EditorFileSystem.update_file() for each path, which
        forces the editor to re-scan and reimport the files. Useful
        after modifying files outside the editor.

        Args:
            paths: List of file paths to reimport (e.g. ["res://textures/icon.png"]).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await filesystem_handlers.filesystem_reimport(runtime, paths=paths)

    @mcp.tool(meta=DEFER_META)
    async def filesystem_search(
        ctx: Context,
        name: str = "",
        type: str = "",
        path: str = "",
        offset: int = 0,
        limit: int = 100,
        session_id: str = "",
    ) -> dict:
        """Search the Godot project filesystem via EditorFileSystem.

        Finds files by name, resource type, or path pattern. At least one
        filter must be provided. Results are paginated.

        Args:
            name: Filter by filename (case-insensitive substring match).
            type: Filter by resource type (e.g. "PackedScene", "GDScript", "Texture2D").
            path: Filter by path (case-insensitive substring match).
            offset: Number of results to skip. Default 0.
            limit: Maximum number of results to return. Default 100.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await filesystem_handlers.filesystem_search(
            runtime,
            name=name,
            type=type,
            path=path,
            offset=offset,
            limit=limit,
        )
