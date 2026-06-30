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
  • scan()
        Force a full ``EditorFileSystem.scan()`` and wait for it to settle.
        This is the headless equivalent of the editor regaining window focus:
        ``write_text``/``script_create`` register single files but do NOT
        rebuild the global ``class_name`` table, so a freshly-created
        ``class_name MyThing extends Resource`` is invisible to
        ``resource_manage``/type references until a scan runs. Call this once
        after adding ``class_name`` scripts when the editor isn't focused.
        Single-flight (awaits any in-progress scan rather than stacking another).
        Returns ``scan_completed`` and ``global_classes_registered_delta``.
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
            "scan": filesystem_handlers.filesystem_scan,
            "search": filesystem_handlers.filesystem_search,
        },
        read_resource_forms={
            ## File reads/searches are per-call queries with arbitrary path
            ## or query inputs; no fixed-URI resource shape fits.
            "read_text": None,
            "search": None,
            ## `scan` is an editor action (not require_writable — it must run
            ## while readiness is "importing" to await an in-flight scan), so
            ## the lint classes it as a read; it has no resource-URI form.
            "scan": None,
        },
    )
