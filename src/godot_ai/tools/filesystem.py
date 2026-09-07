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
        Create or overwrite a text file. Updates the editor filesystem
        entry for that one file (single-file update, not a full scan).
        Newly-created files include ``data.cleanup.rm`` for transient
        smoke tests; overwrite omits the field.
  • reimport(paths)
        Force-reimport the listed files via ``EditorFileSystem.update_file``.
        ``paths`` is a list of res:// paths.
        Intended for imported assets such as textures, models, and audio.
        Paths that are not imported resources (``.gd`` scripts, ``.tscn``,
        hand-written ``.tres``, or an asset the editor has not imported yet)
        report under ``skipped_non_imported`` rather than ``reimported``: their
        filesystem entry is refreshed, but no import runs, so a success there is
        not evidence that a script parsed or that diagnostics were produced. Use
        ``script_patch``/``script_create`` to save a script and receive fresh
        diagnostics, or ``scan`` for an asset awaiting its first import.
        Returns ``reimported``, ``skipped_non_imported``, ``not_found`` and their
        counts.
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
  • move(path, new_path)
        Move a file or folder to a new ``res://`` path through the editor,
        the way the FileSystem dock does it: ``.uid``/``.import`` sidecars
        travel with the file, ``uid://`` references keep resolving, dependent
        ``.tscn``/``.tres`` files get their ``path=`` references rewritten,
        autoloads and file-typed project settings are updated, and the
        editor filesystem cache is refreshed. Refuses when ``new_path``
        already exists. Scripts that name the old path as a string
        (``preload()``/``load()``) are not rewritten (the editor doesn't
        either) and are listed under ``script_references_unfixed`` — patch
        those with ``script_patch``. Not undoable.
  • rename(path, new_name)
        Rename a file or folder in place. ``new_name`` is a bare name (no
        ``/``); same fixups and response shape as ``move``.
  • remove(path, force=false, permanent=false)
        Delete a file or folder. Refuses (with ``error.data.referenced_by``)
        when another resource still references it unless ``force=true``.
        Defaults to the OS trash, like the editor's own Delete, so a mistake
        is recoverable; ``permanent=true`` deletes outright. Releases the
        file's ``uid`` and clears autoloads / project settings that pointed
        at it. Not undoable.
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
            "move": filesystem_handlers.filesystem_move,
            "rename": filesystem_handlers.filesystem_rename,
            "remove": filesystem_handlers.filesystem_remove,
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
