@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const WORK_LABEL := "inherit_scene"
const STAGE_PREFIX := ".godot-ai-inherit-"
const STAGE_FILE := "scene.tscn"
## Leave headroom within the dispatcher's default 4500 ms deferred budget.
const SETTLE_MAX_MSEC := 3000


static func start(connection: McpConnection, params: Dictionary, prepare: bool) -> Dictionary:
	var validated := _validate_paths(params, prepare)
	if validated.has("error"):
		return validated
	var request_id: String = params.get("_request_id", "")
	if connection == null or request_id.is_empty() or not connection.is_inside_tree():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Call scene_manage(op='inherit') directly")
	if ScriptWork.active_count(WORK_LABEL) > 0:
		var busy := ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "Another inherited scene operation is running. Retry shortly.")
		busy["error"]["data"] = {"retryable": true}
		return busy
	_finish(connection, request_id, validated, prepare)
	return McpDispatcher.DEFERRED_RESPONSE


static func _validate_paths(params: Dictionary, prepare: bool) -> Dictionary:
	var base_path = params.get("base_path", "")
	var path = params.get("path", "")
	if not base_path is String or not path is String:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "base_path and path must be strings")
	var path_err = McpPathValidator.path_error(base_path, "base_path")
	if path_err != null:
		return path_err
	path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
	base_path = base_path.replace("\\", "/").simplify_path()
	path = path.replace("\\", "/").simplify_path()
	if not base_path.ends_with(".tscn") or not path.ends_with(".tscn"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"base_path and path must end in .tscn (got %s and %s)" % [base_path, path])
	if not FileAccess.file_exists(base_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Saved base scene not found: %s" % base_path)
	var paths := {"base_path": base_path, "path": path}
	if prepare:
		var destination_err := SceneJob._destination_error(path)
		if not destination_err.is_empty():
			return destination_err
		var stage = params.get("stage_path", "")
		if not stage is String or not SceneJob._valid_stage_path(stage, path.get_base_dir()):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid inherited scene staging location")
		paths["stage_path"] = stage
	return paths


static func _finish(connection: McpConnection, request_id: String, paths: Dictionary, prepare: bool) -> void:
	var work := ScriptWork.begin(WORK_LABEL)
	var job := SceneJob.new(connection, request_id, paths, prepare)
	# The dispatcher registers the deferred reply before work can start.
	await job.tree.process_frame
	if job.pending():
		var result := await job.run()
		job.reply(result)
	ScriptWork.finish(work)


class SceneJob:
	extends RefCounted

	var connection: McpConnection
	var request_id: String
	var tree: SceneTree
	var paths: Dictionary
	var prepare: bool
	var deadline: int
	var replied := false

	func _init(peer: McpConnection, request: String, validated: Dictionary, is_prepare: bool) -> void:
		connection = peer
		request_id = request
		tree = peer.get_tree()
		paths = validated
		prepare = is_prepare
		deadline = Time.get_ticks_msec() + SETTLE_MAX_MSEC

	func pending() -> bool:
		return (not replied and is_instance_valid(connection) and connection.dispatcher != null
			and connection.dispatcher.has_pending_deferred_response(request_id))

	func reply(result: Dictionary) -> void:
		if not pending() or result.is_empty():
			return
		if not prepare and result.has("error"):
			var details: Dictionary = result.error.get("data", {})
			details.merge({
				"disk_committed": true,
				"tab_opened": EditorInterface.get_open_scenes().has(paths.path),
				"base_path": paths.base_path,
				"path": paths.path,
			})
			result.error["data"] = details
		connection.send_deferred_response(request_id, result)
		replied = true

	func run() -> Dictionary:
		var error := _check_editor()
		if not error.is_empty():
			return error
		if prepare:
			return await _prepare_scene()
		return await _open_scene()

	func _prepare_scene() -> Dictionary:
		var base_path: String = paths.base_path
		var path: String = paths.path
		var stage: String = paths.stage_path
		var loaded := await _wait_for_load(base_path, ResourceLoader.CACHE_MODE_IGNORE, base_path)
		if not loaded.get("ready", false):
			return loaded.get("result", {})
		var base := ResourceLoader.load_threaded_get(base_path) as PackedScene
		if base == null or not base.can_instantiate():
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load a saved PackedScene from %s" % base_path)
		var error := _check_editor()
		if not error.is_empty():
			return error
		error = _destination_error(path)
		if not error.is_empty():
			return error
		if not _valid_stage_path(stage, path.get_base_dir()):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid inherited scene staging location")
		var written := _write_stage(stage, base_path, String(base.get_state().get_node_name(0)))
		if written.has("error"):
			return written
		loaded = await _wait_for_load(stage, ResourceLoader.CACHE_MODE_IGNORE, path)
		if not loaded.get("ready", false):
			return loaded.get("result", {})
		var staged := ResourceLoader.load_threaded_get(stage) as PackedScene
		if _packed_base_path(staged) != base_path or FileAccess.get_sha256(stage) != written.stage_sha256:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not verify that the staged scene for %s inherits %s" % [path, base_path])
		return {"data": paths.merged(written)}

	func _open_scene() -> Dictionary:
		var path: String = paths.path
		var base_path: String = paths.base_path
		if not FileAccess.file_exists(path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Published scene not found: %s" % path)
		# Verify the actual file before any tab change. Only the destination state
		# is used here, so a shallow cache-ignore load is sufficient.
		var loaded := await _wait_for_load(path, ResourceLoader.CACHE_MODE_IGNORE, path)
		if not loaded.get("ready", false):
			return loaded.get("result", {})
		var saved := ResourceLoader.load_threaded_get(path) as PackedScene
		if _packed_base_path(saved) != base_path:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not verify that %s on disk inherits %s" % [path, base_path])
		# An ordinary cached destination is the identity witness. EditorNode
		# adopts the state of its actual input into this cached PackedScene.
		loaded = await _wait_for_load(path, ResourceLoader.CACHE_MODE_REUSE, path)
		if not loaded.get("ready", false):
			return loaded.get("result", {})
		var anchor := ResourceLoader.load_threaded_get(path) as PackedScene
		if anchor == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not cache published scene %s" % path)
		var before := anchor.get_state()
		loaded = await _wait_for_load(path, ResourceLoader.CACHE_MODE_IGNORE_DEEP, path)
		if not loaded.get("ready", false):
			return loaded.get("result", {})
		# Keep the fresh destination token held while opening. Godot 4.7's
		# ordinary editor load joins the settled exact-path task. Verify that
		# identity after draining our token, so a competing load fails closed.
		var error := _check_editor()
		var opened := 0
		if error.is_empty() and not EditorInterface.get_open_scenes().has(path):
			opened = _open_published_tab(connection, path)
		var fresh := ResourceLoader.load_threaded_get(path) as PackedScene
		if not error.is_empty():
			return error
		if (opened == 0 or _packed_base_path(fresh) != base_path or ResourceLoader.get_cached_ref(path) != anchor
			or anchor.get_state() != fresh.get_state() or anchor.get_state() == before):
			return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Scene %s was created, but the editor could not verify that it opened from disk" % path)
		return {"data": {
			"base_path": base_path,
			"path": path,
			"undoable": false,
			"reason": "Creating a scene file cannot be undone via editor undo",
		}}

	## A ready result leaves exactly one owned token for the caller to drain.
	## On timeout or disconnect, keep draining without editor effects until
	## the worker finishes. Never block the editor on load_threaded_get().
	func _wait_for_load(path: String, cache_mode: ResourceLoader.CacheMode, reported_path: String) -> Dictionary:
		if not pending():
			return {}
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			var busy := ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "A resource load is already pending for %s" % reported_path)
			busy["error"]["data"] = {"retryable": true}
			return {"result": busy}
		var error := ResourceLoader.load_threaded_request(path, "PackedScene", false, cache_mode)
		if error != OK:
			return {"result": ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load %s (%s)" % [reported_path, error_string(error)])}
		var status := ResourceLoader.load_threaded_get_status(path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			if Time.get_ticks_msec() >= deadline:
				reply(_timeout_error())
			await tree.process_frame
			status = ResourceLoader.load_threaded_get_status(path)
		if status != ResourceLoader.THREAD_LOAD_LOADED or not pending() or Time.get_ticks_msec() >= deadline:
			if status != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				ResourceLoader.load_threaded_get(path)
			if not pending():
				return {}
			if Time.get_ticks_msec() >= deadline:
				return {"result": _timeout_error()}
			return {"result": ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load a saved PackedScene for %s" % reported_path)}
		return {"ready": true}

	func _check_editor() -> Dictionary:
		if Time.get_ticks_msec() >= deadline:
			return _timeout_error()
		match McpConnection.get_readiness():
			"playing":
				return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_PLAYING, "Stop the game before creating an inherited scene", false)
			"importing":
				return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "Wait for the editor import before creating an inherited scene", true)
		return {}

	func _timeout_error() -> Dictionary:
		return ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "Could not load the scene for %s before the editor deadline" % paths.path)


	static func _valid_stage_path(stage: String, parent: String) -> bool:
		if McpPathValidator.path_error(stage, "stage_path", true) != null or stage != stage.simplify_path():
			return false
		var directory := stage.get_base_dir()
		if directory.get_base_dir() != parent or stage.get_file() != STAGE_FILE:
			return false
		var directory_name := directory.get_file()
		if not directory_name.begins_with(STAGE_PREFIX):
			return false
		var suffix := directory_name.trim_prefix(STAGE_PREFIX)
		if suffix.length() != 8 or not ("_" + suffix).is_valid_identifier():
			return false
		var parent_access := DirAccess.open(parent)
		return parent_access != null and not parent_access.is_link(directory_name) and parent_access.dir_exists(directory_name)


	static func _destination_error(path: String) -> Dictionary:
		var directory := DirAccess.open(path.get_base_dir())
		if directory == null:
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Destination directory is missing or inaccessible: %s" % path.get_base_dir())
		var filename := path.get_file()
		if (directory.file_exists(filename) or directory.dir_exists(filename)
			or directory.is_link(filename) or EditorInterface.get_open_scenes().has(path)):
			var error := ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Destination already exists: %s" % path)
			error["error"]["data"] = {"reason": "destination_exists"}
			return error
		return {}


	static func _write_stage(stage: String, base_path: String, root_name: String) -> Dictionary:
		var directory := DirAccess.open(stage.get_base_dir())
		if (directory == null or directory.file_exists(STAGE_FILE) or directory.dir_exists(STAGE_FILE)
			or directory.is_link(STAGE_FILE)):
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "The inherited scene staging slot is unavailable")
		var file := FileAccess.open(stage, FileAccess.WRITE)
		if file == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not stage the inherited scene: %s" % error_string(FileAccess.get_open_error()))
		# This is Godot's native inherited-root form. The editor supplies the base's
		# saved root name and Godot's own Variant string escaping for both values.
		var uid := ResourceUID.id_to_text(ResourceUID.create_id())
		var dependency_uid := ResourceLoader.get_resource_uid(base_path)
		var uid_field := ""
		if ResourceUID.has_id(dependency_uid) and ResourceUID.get_id_path(dependency_uid) == base_path:
			uid_field = " uid=" + var_to_str(ResourceUID.id_to_text(dependency_uid))
		var text := "[gd_scene format=3 uid=%s]\n\n[ext_resource type=\"PackedScene\"%s path=%s id=\"1\"]\n\n[node name=%s instance=ExtResource(\"1\")]\n" % [
			var_to_str(uid), uid_field, var_to_str(base_path), var_to_str(root_name),
		]
		file.store_string(text)
		file.flush()
		var error := file.get_error()
		file.close()
		if error != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not write the staged inherited scene: %s" % error_string(error))
		return {"stage_sha256": text.sha256_text()}


	static func _open_published_tab(connection: McpConnection, path: String) -> int:
		var root := EditorInterface.get_edited_scene_root()
		var previous_id := root.get_instance_id() if root != null else 0
		connection.pause()
		EditorInterface.open_scene_from_path(path)
		connection.resume()
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.get_instance_id() != previous_id and root.scene_file_path == path and EditorInterface.get_open_scenes().has(path):
			return root.get_instance_id()
		return 0


	static func _packed_base_path(packed: PackedScene) -> String:
		if packed != null:
			var base := packed.get_state().get_base_scene_state()
			if base != null:
				return base.get_path()
		return ""
