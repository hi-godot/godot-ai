@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
## Leave headroom within the dispatcher's default 4500 ms deferred budget.
const SETTLE_MAX_MSEC := 3000

## EditorInterface uses CACHE_MODE_REPLACE, which can reset embedded resources
## shared with an open, dirty base tab. Serve a fresh disk snapshot only during
## the synchronous native operation on this exact scene path.
class SceneSnapshotLoader:
	extends ResourceFormatLoader

	var scene_path: String
	var packed_scene: PackedScene
	var registered := false
	var consulted := false
	var served := false

	func _init(path: String, packed: PackedScene) -> void:
		scene_path = path
		packed_scene = packed

	func _get_recognized_extensions() -> PackedStringArray:
		registered = true
		return PackedStringArray()

	func _recognize_path(path: String, type: StringName) -> bool:
		if (
			path == scene_path
			and (type.is_empty() or type == &"PackedScene")
			and OS.get_thread_caller_id() == OS.get_main_thread_id()
		):
			consulted = true
			return true
		return false

	func _load(_path: String, _original_path: String, _use_sub_threads: bool, cache_mode: int) -> Variant:
		if cache_mode == ResourceLoader.CACHE_MODE_REPLACE:
			served = true
			return packed_scene
		return ERR_UNAVAILABLE

	func run(operation: Callable) -> bool:
		ResourceLoader.add_resource_format_loader(self, true)
		# Registration returns void and fails if the loader table is full.
		# Enumerating extensions visits every admitted loader without remapping.
		ResourceLoader.get_recognized_extensions_for_type("")
		if not registered:
			return false
		# A resource remap may send the requested file to a different path.
		# Require an exact match before opening, and remove the loader either way.
		ResourceLoader.get_dependencies(scene_path)
		if consulted:
			operation.call()
		ResourceLoader.remove_resource_format_loader(self)
		return served


## Open and save a native inherited scene from a saved .tscn base.
static func start(connection: McpConnection, params: Dictionary) -> Dictionary:
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
	var destination_err := _inherit_destination_error(path)
	if not destination_err.is_empty():
		return destination_err

	var request_id: String = params.get("_request_id", "")
	if connection == null or request_id.is_empty() or not connection.is_inside_tree():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Call scene_manage(op='inherit') directly to wait for the new scene tab")
	if ScriptWork.active_count("inherit_scene") > 0:
		var busy := ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "An inherited scene is already being created. Retry shortly.")
		busy["error"]["data"] = {"retryable": true}
		return busy
	_finish_inherit_scene_deferred(connection, request_id, base_path, path)
	return McpDispatcher.DEFERRED_RESPONSE


static func _inherit_destination_error(path: String) -> Dictionary:
	var parent := path.get_base_dir()
	var directory := DirAccess.open(parent)
	if directory == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Destination directory is missing or inaccessible: %s" % parent)
	var filename := path.get_file()
	if (
		directory.file_exists(filename)
		or directory.dir_exists(filename)
		or directory.is_link(filename)
		or EditorInterface.get_open_scenes().has(path)
	):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Destination already exists: %s" % path)
	return {}


static func _inherit_request_pending(connection: McpConnection, request_id: String) -> bool:
	return is_instance_valid(connection) and connection.dispatcher != null and connection.dispatcher.has_pending_deferred_response(request_id)


static func _finish_inherit_scene_deferred(connection: McpConnection, request_id: String, base_path: String, path: String) -> void:
	var work := ScriptWork.begin("inherit_scene")
	var result := await _inherit_scene_in_editor(connection, request_id, base_path, path)
	ScriptWork.finish(work)
	if not result.is_empty() and _inherit_request_pending(connection, request_id):
		connection.send_deferred_response(request_id, result)


static func _inherit_scene_in_editor(connection: McpConnection, request_id: String, base_path: String, path: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + SETTLE_MAX_MSEC
	var tree := connection.get_tree()
	# Register the deferred request before opening any tab. No editor operation
	# starts after the command loses its dispatcher entry.
	await tree.process_frame
	if not _inherit_request_pending(connection, request_id):
		return {}
	var err := _inherit_editor_error(deadline)
	if not err.is_empty():
		return err
	err = _inherit_destination_error(path)
	if not err.is_empty():
		return err
	if not FileAccess.file_exists(base_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Saved base scene not found: %s" % base_path)
	var packed := ResourceLoader.load(base_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null or not packed.can_instantiate():
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load a saved PackedScene from %s" % base_path)
	if not _inherit_request_pending(connection, request_id):
		return {}
	err = _inherit_editor_error(deadline)
	if not err.is_empty():
		return err

	var inherited_id := _open_inherited_tab(connection, base_path, packed)
	if inherited_id == 0:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Editor did not open a new inherited tab from the saved %s" % base_path)
	# Wait for the editor to settle, then require this exact untitled root.
	await tree.process_frame
	if not _inherit_request_pending(connection, request_id):
		return {}
	err = _inherit_editor_error(deadline)
	if not err.is_empty():
		return err
	return _save_inherited_tab(connection, request_id, base_path, path, inherited_id, deadline)


static func _open_inherited_tab(connection: McpConnection, base_path: String, packed: PackedScene) -> int:
	# The native open selects its new root synchronously. Never search among
	# untitled tabs, which may already include other scenes from this base.
	var root := EditorInterface.get_edited_scene_root()
	var previous_id := root.get_instance_id() if root != null else 0
	var loader := SceneSnapshotLoader.new(base_path, packed)
	connection.pause()
	var served := loader.run(EditorInterface.open_scene_from_path.bind(base_path, true))
	connection.resume()
	root = EditorInterface.get_edited_scene_root()
	if served and root != null and root.get_instance_id() != previous_id and root.scene_file_path.is_empty():
		return root.get_instance_id()
	return 0


static func _save_inherited_tab(connection: McpConnection, request_id: String, base_path: String, path: String, inherited_id: int, deadline: int) -> Dictionary:
	var root := _matching_root(inherited_id, "")
	if root == null:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Editor switched away from the new inherited tab for %s before it could be saved" % base_path)
	var inherited := PackedScene.new()
	var pack_error := inherited.pack(root)
	if pack_error != OK:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not verify inherited tab for %s (%s)" % [base_path, error_string(pack_error)])
	if _packed_base_path(inherited) != base_path:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "New scene tab does not inherit %s" % base_path)
	if not _inherit_request_pending(connection, request_id):
		return {}
	var err := _inherit_editor_error(deadline)
	if not err.is_empty():
		return err
	err = _inherit_destination_error(path)
	if not err.is_empty():
		return err
	if _matching_root(inherited_id, "") == null:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Editor switched away from the new inherited tab for %s before it could be saved" % base_path)

	connection.pause()
	EditorInterface.save_scene_as(path, false)
	connection.resume()
	if _matching_root(inherited_id, path) == null or not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Editor did not save the inherited tab to %s" % path)
	# Save As returns void. Read the destination file itself to verify that
	# the persisted scene still links directly to the requested source.
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if _packed_base_path(saved) != base_path:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not verify that %s on disk inherits %s" % [path, base_path])
	# Save As can update the root's path without updating the editor tab's
	# cached path. Reopen the verified file in its tab so get_roots and close
	# can find it by path immediately.
	if not EditorInterface.get_open_scenes().has(path):
		if not _inherit_request_pending(connection, request_id):
			return {}
		if _matching_root(inherited_id, path) == null:
			return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Editor switched away after saving %s" % path)
		# Reuse the saved snapshot during the native reload so it instantiates
		# the saved base rather than resolving a dirty base through the cache.
		var loader := SceneSnapshotLoader.new(path, saved)
		connection.pause()
		var served := loader.run(EditorInterface.reload_scene_from_path.bind(path))
		connection.resume()
		root = EditorInterface.get_edited_scene_root()
		if not served or root == null or root.scene_file_path != path or not EditorInterface.get_open_scenes().has(path):
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Saved %s, but the editor did not reload its scene tab" % path)
	return {"data": {
		"base_path": base_path,
		"path": path,
		"undoable": false,
		"reason": "Creating a scene file cannot be undone via editor undo",
	}}


static func _matching_root(instance_id: int, scene_path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.get_instance_id() == instance_id and root.scene_file_path == scene_path:
		return root
	return null


static func _inherit_editor_error(deadline: int) -> Dictionary:
	if Time.get_ticks_msec() >= deadline:
		return ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "The inherited scene tab did not settle before the save deadline")
	match McpConnection.get_readiness():
		"playing":
			return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_PLAYING, "Stop the game before creating an inherited scene", false)
		"importing":
			return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "Wait for the editor import before creating an inherited scene", true)
	return {}


static func _packed_base_path(packed: PackedScene) -> String:
	if packed != null:
		var base := packed.get_state().get_base_scene_state()
		if base != null:
			return base.get_path()
	return ""
