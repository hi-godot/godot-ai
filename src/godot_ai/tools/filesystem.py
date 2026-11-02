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
  • import_get(path)
        Read an already-imported asset's importer, options, Variant types,
        writable_options, revision and native import_valid status. Validation
        uses stored config types, not a full importer enum/range schema.
  • import_set(path, options, reimport=True, expected_revision="")
        Patch existing scalar import options for one asset. Unknown keys,
        importer switching and _subresources edits are unsupported. Pass the
        revision from import_get to reject stale edits. Busy scans/imports
        refuse before writing. Staged replacement preserves recovery paths
        on failure; file edits are non-undoable. Returns settings_committed,
        import_attempted, import_pending, import_valid, import_succeeded and revision. Native
        import failure after commit returns these outcomes in error data.
        Native validity alone can be stale; import_succeeded also requires
        no captured errors. import_diagnostics describes editor errors during
        the synchronous import, not guaranteed per-asset attribution.
        reimport=False saves settings only. Native import can exceed the
        120-second command budget: inspect current status before retrying.
  • reimport(paths)
        Force-reimport imported assets via ``EditorFileSystem.reimport_files``.
        ``paths`` is a list of res:// paths.
        Intended for imported assets such as textures, models, and audio.
        Paths that are not imported resources (``.gd`` scripts, ``.tscn``,
        hand-written ``.tres``, or an asset the editor has not imported yet)
        report under ``skipped_non_imported`` rather than ``reimported``: their
        filesystem entry is refreshed with ``update_file``, but no import runs,
        so a success there is not evidence that a script parsed or that
        diagnostics were produced. Use
        ``script_patch``/``script_create`` to save a script and receive fresh
        diagnostics, or ``scan`` for an asset awaiting its first import.
        Returns ``reimported``, ``skipped_non_imported``, ``not_found`` and their
        counts. Failed native validity goes under failed_imports; valid paths
        with captured editor errors go under unconfirmed_imports. Responses
        include per-path import_status and bounded import_diagnostics.
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
  • move(path, new_path), rename(path, new_name)
        Move a resource group with .uid/.import sidecars and preserve proven
        UID references. Destination parent must exist. Literal-path owners,
        project settings, open scene tabs, links and incomplete discovery are
        refused before mutation; dependency rewriting is unsupported.
  • remove(path, force=False, permanent=False)
        Default: OS trash. Known references block unless force=True; force
        never overrides incomplete discovery or protected paths. Permanent
        deletion supports files only. Directory deletion uses trash.

move/rename/remove contract:
  Mutations require a direct call, not batch_execute. Directory results set
  scan_required: call scan afterward. All mutations are non-undoable. Errors
  report outcome unchanged/rolled_back/partial and actual affected paths.
  Never blindly retry a partial result.
"""


def register_filesystem_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="filesystem_manage",
        description=_DESCRIPTION,
        ops={
            "read_text": filesystem_handlers.filesystem_read_text,
            "write_text": filesystem_handlers.filesystem_write_text,
            "import_get": filesystem_handlers.filesystem_import_get,
            "import_set": filesystem_handlers.filesystem_import_set,
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
            "import_get": None,
            "search": None,
            ## `scan` is an editor action (not require_writable — it must run
            ## while readiness is "importing" to await an in-flight scan), so
            ## the lint classes it as a read; it has no resource-URI form.
            "scan": None,
        },
    )
