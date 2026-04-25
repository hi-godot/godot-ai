"""MCP tool for project filesystem read/write/search/reimport."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import filesystem as filesystem_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Project filesystem access via the Godot editor's EditorFileSystem.

Ops:
  • read_text(path)
        Read a text file at a ``res://`` path. Returns content, size,
        line_count.
  • write_text(path, content="")
        Create or overwrite a text file. Triggers an editor filesystem
        scan. Newly-created files include ``data.cleanup.rm`` for transient
        smoke tests; overwrite omits the field.
  • reimport(paths)
        Force-reimport the listed files via ``EditorFileSystem.update_file``.
        ``paths`` is a list of res:// paths.
  • search(name="", type="", path="", offset=0, limit=100)
        Find files by name, resource type, or path substring. At least one
        filter must be set. Paginated.
"""


def register_filesystem_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="filesystem_manage",
        description=_DESCRIPTION,
        ops={
            "read_text": filesystem_handlers.filesystem_read_text,
            "write_text": filesystem_handlers.filesystem_write_text,
            "reimport": filesystem_handlers.filesystem_reimport,
            "search": filesystem_handlers.filesystem_search,
        },
    )
