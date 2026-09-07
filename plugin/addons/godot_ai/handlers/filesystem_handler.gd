@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")

## Handles file read/write operations and reimport within the Godot project.

## Bounds for the deferred scan wait. `write_file`/`reimport` register single
## files with `update_file()` (cheap, no global-class rebuild); `scan_filesystem`
## is the heavier, explicit "rebuild the class registry" path agents call after
## adding `class_name` scripts headlessly (no window focus to trigger it).
## Kept under the dispatcher's "scan_filesystem" deferred timeout (30s) so we
## always send a real reply before a DEFERRED_TIMEOUT is synthesised.
const _SCAN_START_GRACE_MSEC := 750
const _SCAN_SETTLE_MAX_MSEC := 28000

## Sidecar the editor writes next to every imported resource. `reimport` reads
## it to tell imported assets from files that merely have a filesystem entry
## (see `_is_imported_resource`).
const IMPORT_SIDECAR_SUFFIX := ".import"

## Shared single-flight latch for scan_filesystem. `is_scanning()` alone can't
## enforce single-flight: `EditorFileSystem.scan()` doesn't flip `is_scanning()`
## for a frame or two (hence _SCAN_START_GRACE_MSEC), so a second request landing
## in that window would observe `false` and stack another scan() — the exact
## stacked-worker SIGABRT this op exists to avoid (dsarno/godot#6). The latch is
## set before the first scan() and cleared when its settle coroutine finishes;
## concurrent requests coalesce onto the running scan instead of starting one.
## `static` so it's shared across handler instances; it resets on plugin reload
## (script re-parse), which self-heals any latch orphaned by a mid-await teardown.
static var _scan_in_flight := false

var _connection: McpConnection


func _init(connection: McpConnection = null) -> void:
	_connection = connection


func read_file(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")

	var path_err = McpPathValidator.path_error(path, "path")
	if path_err != null:
		return path_err

	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file: %s" % path)

	var content := file.get_as_text()
	file.close()

	return {
		"data": {
			"path": path,
			"content": content,
			"size": content.length(),
			"line_count": content.count("\n") + (1 if not content.is_empty() else 0),
		}
	}


func write_file(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err

	var existed_before := FileAccess.file_exists(path)

	# Shared write path (#714): parent mkdir + write/flush + explicit error
	# check live on McpResourceIO so this can't drift from create_script.
	var write_failure: Variant = McpResourceIO.write_text_to_disk(path, content)
	if write_failure != null:
		return write_failure

	# Single-file register, not a full scan() — a scan() per write stacks
	# filesystem WorkerThreadPool tasks under concurrent writes and can SIGABRT
	# in the global-class update (see dsarno/godot#6 and create_script in
	# script_handler.gd). update_file() is what reimport()/material/theme use.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	var data := {
		"path": path,
		"size": content.length(),
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	var is_gdscript := path.ends_with(".gd")
	## A .gd written through the filesystem tool used to skip the parse
	## diagnostics create_script attaches (#714) — the agent's broken
	## script reported plain success and the parse error surfaced only in
	## later editor logs. Same shared check, same response fields. A bare
	## ScriptHandler works here: the diagnostics path touches no instance
	## state (it stays an instance method only for test stubbing).
	if is_gdscript:
		ScriptHandler.new(null)._attach_gdscript_diagnostics(data, path, content)
		data["committed"] = true
		data["import_settled"] = existed_before
		data["import_settle"] = "already_known" if existed_before else "not_waited"
	McpResourceIO.attach_cleanup_hint(data, existed_before, [path])

	## Fresh `.gd` writes take create_script's import-settle deferral (#714,
	## #261): reply only once ResourceLoader can see the new resource (or the
	## bounded window elapses), so write_file -> script_attach back-to-back
	## can't 404 on the not-yet-imported script. This CHANGES write_file's
	## response timing for that case — the reply lands up to
	## McpResourceIO.IMPORT_SETTLE_MAX_MSEC later instead of immediately.
	## Scoped to .gd: ResourceLoader never learns plain text files, so an
	## unconditional wait would burn the full window on every fresh .txt.
	## Overwrites, batch_execute (no request_id) and unit-test contexts (no
	## connection) keep the synchronous reply.
	var request_id: String = params.get("_request_id", "")
	if is_gdscript and not existed_before and _connection != null and not request_id.is_empty():
		McpResourceIO.finish_text_write_deferred(_connection, request_id, path, data)
		return McpDispatcher.DEFERRED_RESPONSE

	return {"data": data}


func reimport(params: Dictionary) -> Dictionary:
	var paths: Array = params.get("paths", [])

	if paths.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: paths (non-empty array)")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

	var reimported: Array[String] = []
	var skipped_non_imported: Array[String] = []
	var not_found: Array[String] = []

	for path_variant in paths:
		var path: String = str(path_variant)
		var path_err := McpPathValidator.validate_resource_path(path)
		if not path_err.is_empty():
			not_found.append("%s (%s)" % [path, path_err])
			continue
		if not FileAccess.file_exists(path):
			not_found.append("%s (file does not exist)" % path)
			continue
		efs.update_file(path)
		if _is_imported_resource(path):
			reimported.append(path)
		else:
			skipped_non_imported.append(path)

	var data := {
		"reimported": reimported,
		"skipped_non_imported": skipped_non_imported,
		"not_found": not_found,
		"reimported_count": reimported.size(),
		"skipped_non_imported_count": skipped_non_imported.size(),
		"not_found_count": not_found.size(),
		"undoable": false,
		"reason": "Reimport is a file system operation",
	}
	## Only when it applies: a hint on every call would cost tokens on the
	## all-assets path this op is actually for.
	if not skipped_non_imported.is_empty():
		data["skipped_non_imported_hint"] = (
			"%d path(s) are not imported resources. Their editor filesystem entry was "
			+ "refreshed, but no import ran — a success here is not evidence that a "
			+ "script parsed or that diagnostics were produced. Use script_patch/"
			+ "script_create for GDScript diagnostics, or filesystem_manage(op=\"scan\") "
			+ "for an asset the editor has not imported yet."
		) % skipped_non_imported.size()
	return {"data": data}


## #778: `update_file()` registers a path with the resource pipeline; it only
## runs an *import* for files that have one. Scripts, scenes and hand-written
## `.tres` are not imported resources, so listing them under `reimported` reads
## as proof that a parse or import ran when nothing did.
##
## The `.import` sidecar is the editor's own record that a path goes through
## the import pipeline, so it decides the split. An extension allow-list was
## rejected: importers come and go with plugins, so the list would drift out of
## agreement with the editor it claims to describe.
##
## Known edge: an asset the editor has never imported (just written, no scan
## yet) has no sidecar and reports as non-imported. That is accurate at the
## moment of the call — `update_file()` did not import it either — and the
## hint names `scan` as the way through.
##
## Behaviour is unchanged for every path: `update_file()` still runs on all of
## them, because refreshing an externally-edited `.tscn`/`.tres` is a real use
## of this op. This splits the report, not the work.
static func _is_imported_resource(path: String) -> bool:
	if path.ends_with(IMPORT_SIDECAR_SUFFIX):
		return false  ## The sidecar itself is not an imported resource.
	return FileAccess.file_exists(path + IMPORT_SIDECAR_SUFFIX)


## Force a full EditorFileSystem scan and wait for it to settle. This is the
## headless equivalent of the editor regaining window focus: `update_file()`
## (used by write_file/reimport/script_create) registers a single file with the
## resource pipeline but does NOT rebuild the global `class_name` table, so a
## freshly-created `class_name MyThing extends Resource` stays invisible to
## `ClassDB`/`ProjectSettings.get_global_class_list()` until a scan runs. Agents
## driving the editor without focus call this once after a batch of script
## creates to make new types instantiable/referenceable. See issue #83.
func scan_filesystem(params: Dictionary) -> Dictionary:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

	var request_id: String = params.get("_request_id", "")
	# Async path: a scan can't be awaited on the calling frame without freezing
	# the editor, so hand control back to the dispatcher (DEFERRED_RESPONSE) and
	# push the real reply from a static coroutine once the scan settles — by
	# which point new class_names are registered.
	if _connection != null and not request_id.is_empty():
		_finish_scan_deferred(_connection, request_id, efs)
		return McpDispatcher.DEFERRED_RESPONSE

	# Synchronous fallback: batch_execute (no request_id) and unit-test contexts
	# (no connection) can't await, so kick a single-flight scan and return
	# immediately without the settle confirmation. Respect the latch so we don't
	# stack onto a deferred scan; don't set it (there's no coroutine here to
	# clear it — the brief is_scanning() window covers the rest).
	var already := _scan_in_flight or efs.is_scanning()
	if not already:
		efs.scan()
	return {
		"data": {
			"scan_completed": false,
			"scan_settle": "not_waited",
			"was_already_scanning": already,
			"global_class_count": ProjectSettings.get_global_class_list().size(),
			# Present in both paths for a consistent response shape; the sync
			# path doesn't await, so it can't measure a delta.
			"global_classes_registered_delta": 0,
			"undoable": false,
			"reason": "Filesystem scan is an editor operation",
		}
	}


## `static` is load-bearing for the same reason as ScriptHandler's deferred
## finish: the coroutine must outlive the handler RefCounted, which can be freed
## mid-await (e.g. an editor_reload_plugin fired during the scan). Parameterise
## everything; reference no instance state.
static func _finish_scan_deferred(
	connection: McpConnection,
	request_id: String,
	efs: EditorFileSystem,
) -> void:
	var work := ScriptWork.begin("scan_filesystem")
	await _settle_scan(connection, request_id, efs)
	ScriptWork.finish(work)


static func _settle_scan(
	connection: McpConnection, request_id: String, efs: EditorFileSystem,
) -> void:
	if not is_instance_valid(connection):
		return
	var tree := connection.get_tree()
	if tree == null:
		return
	var classes_before := ProjectSettings.get_global_class_list().size()
	# Single-flight via the shared `_scan_in_flight` latch (NOT is_scanning(),
	# which lags scan() by a frame or two — see the latch declaration). Only the
	# request that sets the latch calls scan(); concurrent requests coalesce and
	# just await the running scan. This is what actually prevents the stacked
	# scan() SIGABRT (dsarno/godot#6), even within the start-grace window.
	var was_already_scanning := _scan_in_flight or efs.is_scanning()
	var we_started := not was_already_scanning
	if we_started:
		_scan_in_flight = true
		efs.scan()
	# Hand back a frame so _dispatch() registers this request as deferred before
	# the coroutine can push a reply (mirrors McpResourceIO.finish_text_write_deferred).
	await tree.process_frame
	var deadline_ms := Time.get_ticks_msec() + _SCAN_SETTLE_MAX_MSEC
	var start_grace_ms := Time.get_ticks_msec() + _SCAN_START_GRACE_MSEC
	var saw_scanning := efs.is_scanning()
	while Time.get_ticks_msec() < deadline_ms:
		if efs.is_scanning():
			saw_scanning = true
		elif saw_scanning or Time.get_ticks_msec() > start_grace_ms:
			# Either the scan ran and finished, or it never flipped is_scanning()
			# within the grace window (a no-op scan because nothing changed).
			break
		await tree.process_frame
	# Clear the latch in all paths (no try/finally in GDScript): do it before the
	# is_instance_valid early-return so a freed connection can't orphan it.
	if we_started:
		_scan_in_flight = false
	if not is_instance_valid(connection):
		return
	var completed := not efs.is_scanning()
	var classes_after := ProjectSettings.get_global_class_list().size()
	connection.send_deferred_response(request_id, {
		"data": {
			"scan_completed": completed,
			"scan_settle": "settled" if completed else "timeout",
			"was_already_scanning": was_already_scanning,
			"global_class_count": classes_after,
			"global_classes_registered_delta": classes_after - classes_before,
			"undoable": false,
			"reason": "Filesystem scan is an editor operation",
		}
	})


# ----- move / rename / remove (#907) -----

## Sidecars that travel with a resource file: the editor's `.import` record
## and the `.uid` sidecar for formats that can't embed a uid (scripts,
## shaders). Neither is a move/remove target in its own right.
const _SIDECAR_SUFFIXES: Array[String] = [".import", ".uid"]

## Text resource formats whose `[ext_resource ... path="..."]` headers get
## rewritten after a move — the script-reachable stand-in for
## `ResourceFormatLoaderText::rename_dependencies`, which the FileSystemDock
## calls but the engine does not expose to GDScript.
const _TEXT_RESOURCE_EXTENSIONS: Array[String] = ["tscn", "tres"]
const _BINARY_RESOURCE_EXTENSIONS: Array[String] = ["scn", "res"]

## The loaded plugin's own tree. `McpPathValidator` already refuses paths at
## or below it; this catches an ancestor folder (`res://addons`) whose move
## or removal would take the running plugin with it.
const _PLUGIN_TREE := "res://addons/godot_ai"

const _NOT_UNDOABLE_MOVE := "File system moves cannot be undone via editor undo; move it back with another move"


## Move a file or folder inside `res://` with the same follow-up work the
## editor's FileSystemDock does (#907): sidecars travel with the file, cached
## resources and the open scene learn the new path, `ResourceUID` is
## re-pointed, dependent `.tscn`/`.tres` files are rewritten, autoloads and
## file-typed project settings are updated, and the editor filesystem cache
## is refreshed. Godot exposes none of the dock's move helpers to scripts,
## so each step is mirrored here (see `_move`).
func move_file(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var new_path: String = str(params.get("new_path", ""))
	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
	var new_path_err = McpPathValidator.path_error(new_path, "new_path", true)
	if new_path_err != null:
		return new_path_err
	return _move(_strip_trailing_slash(path), _strip_trailing_slash(new_path))


## Rename in place: `new_name` is a bare file/folder name resolved against
## the parent of `path`. Same fixups and response shape as `move_file`.
func rename_file(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var new_name: String = str(params.get("new_name", ""))
	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
	if new_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: new_name")
	if "/" in new_name or "\\" in new_name or new_name in [".", ".."]:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"new_name must be a bare name without path separators (got %s); use op=\"move\" to change folders" % new_name)
	path = _strip_trailing_slash(path)
	var new_path := path.get_base_dir().path_join(new_name)
	var new_path_err = McpPathValidator.path_error(new_path, "new_name", true)
	if new_path_err != null:
		return new_path_err
	return _move(path, new_path)


## Delete a file or folder. Refuses a target other resources still reference
## unless `force`; defaults to the OS trash (what the editor's own Delete
## does) so a mistaken removal is recoverable, `permanent` deletes outright.
func remove_file(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var force: bool = bool(params.get("force", false))
	var permanent: bool = bool(params.get("permanent", false))
	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
	path = _strip_trailing_slash(path)
	if path == "res://":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot remove the project root res://")
	if _is_sidecar(path):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"path: %s is an editor sidecar; remove the resource it belongs to and the sidecar goes with it" % path)
	var is_dir := DirAccess.dir_exists_absolute(path)
	if not is_dir and not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File or folder not found: %s" % path)
	if is_dir and _contains_plugin_tree(path):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Refusing to remove %s: it contains the loaded godot_ai plugin" % path)
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem not available", false)

	var targets := {}
	if is_dir:
		for file_path in _list_files_recursive(path):
			targets[file_path] = true
	else:
		targets[path] = true

	# Owners outside the removed tree are what makes a removal unsafe; a
	# scene inside a folder being removed vanishes with it.
	var owners := {}
	_collect_owners_on_disk("res://", targets, owners)
	for owner_key in owners.keys():
		if targets.has(owner_key):
			owners.erase(owner_key)
	var referenced_by := _owners_to_list(owners)
	if not owners.is_empty() and not force:
		var err := ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"%s is still referenced by %d resource(s); fix those references first, or pass force=true to remove it anyway" % [path, owners.size()])
		err["error"]["data"] = {"referenced_by": referenced_by}
		return err

	# Uids are read from the sidecar/header, so capture them before deleting.
	var uids := {}
	for target_key in targets:
		var uid := ResourceLoader.get_resource_uid(target_key)
		if uid != ResourceUID.INVALID_ID:
			uids[target_key] = uid

	var warnings: Array[String] = []
	var trashed := false
	if permanent:
		if is_dir:
			if not _remove_dir_recursive(path):
				return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to delete folder %s" % path)
		else:
			var rm_err := DirAccess.remove_absolute(path)
			if rm_err != OK:
				return ErrorCodes.make(
					ErrorCodes.INTERNAL_ERROR, "Failed to delete %s: %s" % [path, error_string(rm_err)])
			for suffix in _SIDECAR_SUFFIXES:
				if FileAccess.file_exists(path + suffix):
					var side_err := DirAccess.remove_absolute(path + suffix)
					if side_err != OK:
						warnings.append("Failed to delete sidecar %s: %s" % [path + suffix, error_string(side_err)])
	else:
		var trash_err := OS.move_to_trash(ProjectSettings.globalize_path(path))
		if trash_err != OK:
			return ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				"Could not move %s to the OS trash (%s); pass permanent=true to delete it outright" % [path, error_string(trash_err)])
		trashed = true
		if not is_dir:
			for suffix in _SIDECAR_SUFFIXES:
				if FileAccess.file_exists(path + suffix):
					var side_err := OS.move_to_trash(ProjectSettings.globalize_path(path + suffix))
					if side_err != OK:
						warnings.append("Failed to trash sidecar %s: %s" % [path + suffix, error_string(side_err)])

	for target_key in uids:
		var uid: int = uids[target_key]
		if ResourceUID.has_id(uid):
			ResourceUID.remove_id(uid)

	var settings_cleared := _clear_project_settings_after_remove(targets, warnings)

	for target_key in targets:
		efs.update_file(target_key)
	var scan_kicked := false
	if is_dir:
		scan_kicked = _kick_scan_if_idle(efs)

	var data := {
		"path": path,
		"kind": "directory" if is_dir else "file",
		"removed": targets.keys(),
		"removed_count": targets.size(),
		"trashed": trashed,
		"uids_released": uids.size(),
		"project_settings_cleared": settings_cleared,
		"scan_kicked": scan_kicked,
		"warnings": warnings,
		"undoable": false,
		"reason": (
			"Moved to the OS trash; restore it from there to revert" if trashed
			else "Permanently deleted; not recoverable via editor undo"
		),
	}
	if not referenced_by.is_empty():
		data["referenced_by"] = referenced_by
		data["referenced_by_hint"] = (
			"Removed with force=true while %d resource(s) still referenced it; those references are now dangling."
			% referenced_by.size()
		)
	return {"data": data}


## The shared move pipeline behind `move_file` and `rename_file`. Both
## paths are already validated (res://-confined, not a sensitive write
## target) and stripped of trailing slashes.
func _move(old_path: String, new_path: String) -> Dictionary:
	if old_path == "res://":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot move the project root res://")
	if _is_sidecar(old_path):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"path: %s is an editor sidecar; move the resource it belongs to and the sidecar follows" % old_path)
	var is_dir := DirAccess.dir_exists_absolute(old_path)
	if not is_dir and not FileAccess.file_exists(old_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File or folder not found: %s" % old_path)
	if is_dir and _contains_plugin_tree(old_path):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Refusing to move %s: it contains the loaded godot_ai plugin" % old_path)
	if old_path == new_path:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "new_path is the same as path: %s" % old_path)
	if is_dir and (new_path + "/").begins_with(old_path + "/"):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot move a folder into itself: %s -> %s" % [old_path, new_path])
	# A case-only rename on a case-insensitive filesystem "exists" already;
	# let it through the same way the dock does.
	var case_only := old_path.to_lower() == new_path.to_lower()
	if not case_only and (FileAccess.file_exists(new_path) or DirAccess.dir_exists_absolute(new_path)):
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"new_path already exists: %s (remove or move it first; overwriting is not supported)" % new_path)
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem not available", false)

	# 1. Every resource path that changes as a result of this move.
	var renames := {}
	if is_dir:
		for file_path in _list_files_recursive(old_path):
			renames[file_path] = new_path + file_path.trim_prefix(old_path)
	else:
		renames[old_path] = new_path

	# 2. Uids are read from the sidecar/header at the OLD path, so capture
	# them before anything moves.
	var uids := {}
	for old_key in renames:
		var uid := ResourceLoader.get_resource_uid(old_key)
		if uid != ResourceUID.INVALID_ID:
			uids[old_key] = uid

	# 3. Owners: every resource in the project whose dependencies name a
	# path about to change — the dock's _find_file_owners, but walking the
	# disk rather than the editor filesystem tree: EditorFileSystemDirectory
	# exposes no get_file_deps to scripts, and files an agent wrote into a
	# new folder moments ago have no tree entry until the next scan. Runs
	# BEFORE the move so the dependency files are read where they still are.
	var owners := {}
	_collect_owners_on_disk("res://", renames, owners)

	# 4. Move on disk. A folder carries its sidecars along; a single file
	# needs them renamed explicitly.
	var parent_dir := new_path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to create directory %s: %s" % [parent_dir, error_string(mkdir_err)])
	# Sidecars that will travel with a single file. Their destinations are
	# preflighted like the file's own, so a stray `foo.gd.uid` at the target
	# is refused before anything moves instead of failing halfway.
	var sidecars: Array[String] = []
	if not is_dir:
		for suffix in _SIDECAR_SUFFIXES:
			if FileAccess.file_exists(old_path + suffix):
				sidecars.append(suffix)
				var side_target := new_path + suffix
				if not case_only and (FileAccess.file_exists(side_target) or DirAccess.dir_exists_absolute(side_target)):
					return ErrorCodes.make(
						ErrorCodes.INVALID_PARAMS,
						"new_path already exists: %s (the sidecar of %s would be overwritten)" % [side_target, old_path])
	var rename_err := DirAccess.rename_absolute(old_path, new_path)
	if rename_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to move %s to %s: %s" % [old_path, new_path, error_string(rename_err)])
	# The file and its sidecars move as one unit: a sidecar rename that
	# still fails (the disk changed under us) rolls the whole move back
	# rather than leaving `foo.gd` and `foo.gd.uid` in different folders and
	# reporting success.
	var moved_sidecars: Array[String] = []
	for suffix in sidecars:
		var side_err := DirAccess.rename_absolute(old_path + suffix, new_path + suffix)
		if side_err == OK:
			moved_sidecars.append(suffix)
			continue
		var rollback: Array[String] = []
		for done in moved_sidecars:
			if DirAccess.rename_absolute(new_path + done, old_path + done) != OK:
				rollback.append(new_path + done)
		if DirAccess.rename_absolute(new_path, old_path) != OK:
			rollback.append(new_path)
		var message := "Failed to move sidecar %s: %s; the move was rolled back" % [old_path + suffix, error_string(side_err)]
		if not rollback.is_empty():
			message += " except for %s, which could not be moved back" % ", ".join(rollback)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, message)
	var warnings: Array[String] = []

	# 5. Loaded copies keep working under the new path, so an open scene
	# whose script just moved saves the new path rather than the stale one.
	var scene_root := EditorInterface.get_edited_scene_root()
	var open_scenes := EditorInterface.get_open_scenes()
	for old_key in renames:
		var old_p: String = old_key
		var new_p: String = renames[old_key]
		if ResourceLoader.has_cached(old_p):
			var cached := ResourceLoader.get_cached_ref(old_p)
			if cached != null:
				cached.take_over_path(new_p)
		if scene_root != null and scene_root.scene_file_path == old_p:
			scene_root.scene_file_path = new_p
		elif open_scenes.has(old_p):
			warnings.append("Scene tab for %s still points at the old path; reopen it from %s" % [old_p, new_p])

	# 6. uid:// references resolve through ResourceUID, not the path.
	for old_key in uids:
		var uid: int = uids[old_key]
		if ResourceUID.has_id(uid):
			ResourceUID.set_id(uid, renames[old_key])
		else:
			ResourceUID.add_id(uid, renames[old_key])

	# 7. Dependents. Text resources are rewritten in place; scripts and
	# binary resources are reported (the dock doesn't rewrite them either).
	var dependencies_updated: Array[String] = []
	var script_references: Array[Dictionary] = []
	var binary_unresolved: Array[String] = []
	for owner_key in owners:
		var owner_now: String = renames.get(owner_key, owner_key)
		var ext := owner_now.get_extension().to_lower()
		if ext in _TEXT_RESOURCE_EXTENSIONS:
			var rewrite := _rewrite_ext_resource_paths(owner_now, renames)
			if not rewrite.error.is_empty():
				warnings.append(rewrite.error)
			elif rewrite.changed:
				dependencies_updated.append(owner_now)
				efs.update_file(owner_now)
		elif ext == "gd":
			script_references.append({"script": owner_now, "references": owners[owner_key]})
		else:
			binary_unresolved.append(owner_now)

	# 8. Autoloads and file-typed project settings.
	var settings_updated := _update_project_settings_after_move(renames, warnings)

	# 9. Editor filesystem: drop the old entries, register the new ones.
	# update_file() can't register a file whose folder the tree has never
	# seen, so a move into a fresh folder gets the same scan kick as a
	# folder move.
	for old_key in renames:
		efs.update_file(old_key)
		efs.update_file(renames[old_key])
	var scan_kicked := false
	if is_dir or efs.get_filesystem_path(new_path.get_base_dir()) == null:
		scan_kicked = _kick_scan_if_idle(efs)

	var moved: Array[Dictionary] = []
	for old_key in renames:
		moved.append({"from": old_key, "to": renames[old_key]})
	var data := {
		"path": old_path,
		"new_path": new_path,
		"kind": "directory" if is_dir else "file",
		"moved": moved,
		"moved_count": moved.size(),
		"uids_updated": uids.size(),
		"dependencies_updated": dependencies_updated,
		"script_references_unfixed": script_references,
		"binary_owners_unresolved": binary_unresolved,
		"project_settings_updated": settings_updated,
		"scan_kicked": scan_kicked,
		"warnings": warnings,
		"undoable": false,
		"reason": _NOT_UNDOABLE_MOVE,
	}
	if not script_references.is_empty():
		data["script_references_hint"] = (
			"%d script(s) preload()/load() the old path by string; GDScript paths are not "
			+ "rewritten (the editor doesn't either). Patch them with script_patch, or "
			+ "reference by uid:// to make future moves free."
		) % script_references.size()
	if not binary_unresolved.is_empty():
		data["binary_owners_hint"] = (
			"%d binary .scn/.res owner(s) were not rewritten; they resolve through the "
			+ "preserved uid, and a resave from the editor updates their stored path."
		) % binary_unresolved.size()
	return {"data": data}


static func _strip_trailing_slash(path: String) -> String:
	while path.length() > "res://".length() and path.ends_with("/"):
		path = path.left(-1)
	return path


static func _is_sidecar(path: String) -> bool:
	for suffix in _SIDECAR_SUFFIXES:
		if path.ends_with(suffix):
			return true
	return false


static func _contains_plugin_tree(dir_path: String) -> bool:
	return (_PLUGIN_TREE + "/").to_lower().begins_with(dir_path.to_lower() + "/")


## Files (not sidecars) under `dir_path`, recursively, as res:// paths.
static func _list_files_recursive(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := dir_path.path_join(entry)
			if dir.current_is_dir():
				out.append_array(_list_files_recursive(child))
			elif not _is_sidecar(child):
				out.append(child)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## Resource and script files anywhere under `dir_path` (on disk) that
## reference a key of `targets`. `out` maps owner path -> the target paths
## it references. Hidden folders (`.godot`, `.git`) and `.gdignore`d trees
## are skipped, matching what the editor itself indexes.
static func _collect_owners_on_disk(dir_path: String, targets: Dictionary, out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null or dir.file_exists(".gdignore"):
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := dir_path.path_join(entry)
			if dir.current_is_dir():
				if not entry.begins_with("."):
					_collect_owners_on_disk(child, targets, out)
			elif _can_own_dependencies(child):
				var hits := _owner_hits(child, targets)
				if not hits.is_empty():
					out[child] = hits
		entry = dir.get_next()
	dir.list_dir_end()


static func _can_own_dependencies(file_path: String) -> bool:
	var ext := file_path.get_extension().to_lower()
	return ext == "gd" or ext in _TEXT_RESOURCE_EXTENSIONS or ext in _BINARY_RESOURCE_EXTENSIONS


## The target paths `file_path` references. Resources answer through the
## loader's dependency list; scripts through a literal-string search, because
## `ResourceLoader.get_dependencies` reports nothing for a `.gd` even when it
## `preload()`s a path (verified against 4.7.2).
static func _owner_hits(file_path: String, targets: Dictionary) -> Array[String]:
	if file_path.get_extension().to_lower() == "gd":
		return _script_string_references(file_path, targets)
	var hits: Array[String] = []
	for dep in ResourceLoader.get_dependencies(file_path):
		for candidate in _dependency_paths(dep):
			if targets.has(candidate) and not hits.has(candidate):
				hits.append(candidate)
	return hits


## Target paths that appear as a quoted string literal in a script — the
## `preload("res://...")` / `load("res://...")` shape. Scripts are not
## rewritten on move (the editor doesn't either); this is what lets the
## response name them, and what makes them count as owners for remove.
static func _script_string_references(script_path: String, targets: Dictionary) -> Array[String]:
	var hits: Array[String] = []
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return hits
	var text := file.get_as_text()
	file.close()
	for target_key in targets:
		var target: String = target_key
		if ("\"%s\"" % target) in text or ("'%s'" % target) in text:
			hits.append(target)
	return hits


## `get_dependencies` entries are `res://path`, `uid://id::res://path`, or
## either with a trailing `::Type`. Yield every path form the entry can
## resolve to, so a uid-only reference still finds its owner. A segment
## counts as a path only when it is a confined `res://` path (the same
## check every handler entry point applies), which also drops the type
## suffix and any `uid://` segment that no longer resolves.
static func _dependency_paths(dep: String) -> Array[String]:
	var paths: Array[String] = []
	for segment in dep.split("::"):
		if segment.begins_with("uid://"):
			var id := ResourceUID.text_to_id(segment)
			if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
				paths.append(ResourceUID.get_id_path(id))
		elif McpPathValidator.validate_resource_path(segment).is_empty():
			paths.append(segment)
	return paths


static func _owners_to_list(owners: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for owner_key in owners:
		out.append({"path": owner_key, "references": owners[owner_key]})
	return out


## Rewrite `path="old"` to `path="new"` for every rename in a text resource.
## Returns {"changed": bool, "error": String}; `error` is empty on success.
static func _rewrite_ext_resource_paths(owner_path: String, renames: Dictionary) -> Dictionary:
	var file := FileAccess.open(owner_path, FileAccess.READ)
	if file == null:
		return {
			"changed": false,
			"error": "Could not read %s to update its references: %s" % [owner_path, error_string(FileAccess.get_open_error())],
		}
	var text := file.get_as_text()
	file.close()
	var updated := text
	for old_key in renames:
		updated = updated.replace("path=\"%s\"" % old_key, "path=\"%s\"" % renames[old_key])
	if updated == text:
		return {"changed": false, "error": ""}
	var write_failure: Variant = McpResourceIO.write_text_to_disk(owner_path, updated)
	if write_failure != null:
		return {
			"changed": false,
			"error": "Could not update references in %s: %s" % [owner_path, write_failure.error.message],
		}
	return {"changed": true, "error": ""}


## Mirror of the dock's _update_project_settings_after_move: autoload
## entries (with or without the `*` singleton marker) and settings whose
## property hint is FILE (main scene, boot splash, bus layout, ...).
static func _update_project_settings_after_move(renames: Dictionary, warnings: Array[String]) -> Array[String]:
	var updated: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		var setting_name: String = prop.get("name", "")
		var value: Variant = ProjectSettings.get_setting(setting_name)
		if not (value is String):
			continue
		var text: String = value
		if setting_name.begins_with("autoload/"):
			var singleton := text.begins_with("*")
			var bare := text.trim_prefix("*")
			if renames.has(bare):
				ProjectSettings.set_setting(setting_name, ("*" if singleton else "") + str(renames[bare]))
				updated.append(setting_name)
		elif int(prop.get("hint", PROPERTY_HINT_NONE)) == PROPERTY_HINT_FILE and renames.has(text):
			ProjectSettings.set_setting(setting_name, renames[text])
			updated.append(setting_name)
	if not updated.is_empty():
		var save_err := ProjectSettings.save()
		if save_err != OK:
			warnings.append("Project settings updated in memory but not saved: %s" % error_string(save_err))
	return updated


## The removal counterpart: an autoload or FILE-hinted setting that named a
## removed file is cleared, as the editor's own remove dialog does.
static func _clear_project_settings_after_remove(targets: Dictionary, warnings: Array[String]) -> Array[String]:
	var cleared: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		var setting_name: String = prop.get("name", "")
		var value: Variant = ProjectSettings.get_setting(setting_name)
		if not (value is String):
			continue
		var text: String = value
		if setting_name.begins_with("autoload/"):
			if targets.has(text.trim_prefix("*")):
				ProjectSettings.set_setting(setting_name, null)
				cleared.append(setting_name)
		elif int(prop.get("hint", PROPERTY_HINT_NONE)) == PROPERTY_HINT_FILE and targets.has(text):
			ProjectSettings.set_setting(setting_name, "")
			cleared.append(setting_name)
	if not cleared.is_empty():
		var save_err := ProjectSettings.save()
		if save_err != OK:
			warnings.append("Project settings cleared in memory but not saved: %s" % error_string(save_err))
	return cleared


## Folder moves/removes leave stale directory entries behind — update_file()
## only maintains file entries — so kick one scan to make the dock match
## disk, honouring the single-flight latch (a stacked scan() is the
## dsarno/godot#6 SIGABRT the latch exists to prevent).
static func _kick_scan_if_idle(efs: EditorFileSystem) -> bool:
	if _scan_in_flight or efs.is_scanning():
		return false
	efs.scan()
	return true


## Recursive delete. Returns true only when the folder itself is gone.
static func _remove_dir_recursive(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		DirAccess.remove_absolute(path)
		return not DirAccess.dir_exists_absolute(path)
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := path.path_join(entry)
			if dir.current_is_dir():
				_remove_dir_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
	return not DirAccess.dir_exists_absolute(path)
