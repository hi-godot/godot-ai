@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles file read/write operations and reimport within the Godot project.

## Bounds for the deferred scan wait. `write_file`/`reimport` register single
## files with `update_file()` (cheap, no global-class rebuild); `scan_filesystem`
## is the heavier, explicit "rebuild the class registry" path agents call after
## adding `class_name` scripts headlessly (no window focus to trigger it).
## Kept under the dispatcher's "scan_filesystem" deferred timeout (30s) so we
## always send a real reply before a DEFERRED_TIMEOUT is synthesised.
const _SCAN_START_GRACE_MSEC := 750
const _SCAN_SETTLE_MAX_MSEC := 28000

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

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var existed_before := FileAccess.file_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)

	file.store_string(content)
	file.close()

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
	McpResourceIO.attach_cleanup_hint(data, existed_before, [path])
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
		reimported.append(path)

	return {
		"data": {
			"reimported": reimported,
			"not_found": not_found,
			"reimported_count": reimported.size(),
			"not_found_count": not_found.size(),
			"undoable": false,
			"reason": "Reimport is a file system operation",
		}
	}


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
	# the coroutine can push a reply (mirrors _finish_create_script_deferred).
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
