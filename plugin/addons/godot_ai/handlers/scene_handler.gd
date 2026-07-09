@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles scene tree reading and node search.

var _connection: McpConnection
var _save_scene_callable: Callable = Callable()
var _save_scene_as_callable: Callable = Callable()


func _init(connection: McpConnection = null) -> void:
	_connection = connection


func get_scene_tree(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("depth", 10)
	var offset: int = maxi(0, int(params.get("offset", 0)))
	# limit <= 0 means "no limit" (the hierarchy resource reads the whole tree);
	# the scene_get_hierarchy tool passes an explicit positive limit. Paginating
	# here — rather than walking + serializing the full tree and slicing on the
	# Python side — means only the requested window builds node dicts and clean
	# scene paths, and only the window crosses the WebSocket.
	var limit: int = int(params.get("limit", 0))
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {"data": {
			"nodes": [],
			"total_count": 0,
			"offset": offset,
			"limit": limit,
			"has_more": false,
			"message": "No scene open",
		}}

	var nodes: Array[Dictionary] = []
	# index_ref[0] is the running DFS index shared across the recursion (Arrays
	# pass by reference in GDScript). The walk still visits every node to get an
	# accurate total_count, but only materializes those inside the window.
	var index_ref: Array[int] = [0]
	_walk_tree(scene_root, nodes, 0, max_depth, scene_root, offset, limit, index_ref)
	var total: int = index_ref[0]
	return {"data": {
		"nodes": nodes,
		"total_count": total,
		"offset": offset,
		"limit": limit,
		"has_more": limit > 0 and offset + limit < total,
	}}


func get_open_scenes(_params: Dictionary) -> Dictionary:
	var scene_paths := EditorInterface.get_open_scenes()
	var scene_root := EditorInterface.get_edited_scene_root()
	var current := scene_root.scene_file_path if scene_root else ""
	return {
		"data": {
			"scenes": scene_paths,
			"current_scene": current,
			"count": scene_paths.size(),
		}
	}


func find_nodes(params: Dictionary) -> Dictionary:
	var name_filter: String = params.get("name", "")
	var type_filter: String = params.get("type", "")
	var group_filter: String = params.get("group", "")

	if name_filter.is_empty() and type_filter.is_empty() and group_filter.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "At least one filter (name, type, group) is required")

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var results: Array[Dictionary] = []
	_find_recursive(scene_root, scene_root, name_filter, type_filter, group_filter, results)
	return {"data": {"nodes": results, "count": results.size()}}


func _find_recursive(node: Node, scene_root: Node, name_filter: String, type_filter: String, group_filter: String, out: Array[Dictionary]) -> void:
	var matches := true

	if not name_filter.is_empty():
		if node.name.to_lower().find(name_filter.to_lower()) == -1:
			matches = false

	if matches and not type_filter.is_empty():
		if node.get_class() != type_filter:
			matches = false

	if matches and not group_filter.is_empty():
		if not node.is_in_group(group_filter):
			matches = false

	if matches:
		out.append({
			"name": node.name,
			"type": node.get_class(),
			"path": McpScenePath.from_node(node, scene_root),
		})

	for child in node.get_children():
		_find_recursive(child, scene_root, name_filter, type_filter, group_filter, out)


## Create a new scene with the given root node type, save to disk, and open it.
func create_scene(params: Dictionary) -> Dictionary:
	var root_type: String = params.get("root_type", "Node3D")
	var path: String = params.get("path", "")

	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err

	if not path.ends_with(".tscn") and not path.ends_with(".scn"):
		path += ".tscn"

	if not ClassDB.class_exists(root_type):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown node type: %s" % root_type)
	if not ClassDB.is_parent_class(root_type, "Node"):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s is not a Node type" % root_type)

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var root: Node = ClassDB.instantiate(root_type)
	if root == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % root_type)

	var root_name: String = params.get("root_name", "")
	if root_name.is_empty():
		root_name = path.get_file().get_basename()
	root.name = root_name

	if _connection:
		_connection.pause_processing = true
	var err := _pack_and_save_with_uid(root, path)
	if err == OK:
		EditorInterface.open_scene_from_path(path)
	if _connection:
		_connection.pause_processing = false

	if err != OK:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to save scene: %s" % error_string(err))

	return {
		"data": {
			"path": path,
			"root_type": root_type,
			"root_name": root_name,
			"undoable": false,
			"reason": "Scene creation involves file system operations",
		}
	}


## Pack `root` and save it to `path`, embedding a fresh uid or preserving the
## one `path` already had — the exact save sequence `create_scene` runs,
## minus the `pause_processing` guard (the caller owns that, since it also
## needs to bracket `open_scene_from_path`) and minus opening the scene
## (switching the editor's active scene isn't safe inside the shared test
## runner, so tests call this directly instead of going through
## `create_scene` end-to-end). Frees `root`. Returns `OK`, or the first
## `Error` encountered.
func _pack_and_save_with_uid(root: Node, path: String) -> Error:
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()

	# Captured BEFORE the save below overwrites the file — see
	# McpResourceIO.ensure_uid's doc comment.
	var prior_uid := ResourceLoader.get_resource_uid(path) if FileAccess.file_exists(path) else ResourceUID.INVALID_ID

	var err := ResourceSaver.save(packed, path)
	if err == OK:
		err = McpResourceIO.ensure_uid(path, prior_uid)
	return err


## How long open_scene waits for the editor to actually switch to the
## requested scene before replying switched=false. Tab switches normally land
## within a few frames; keep this under the dispatcher's 4500 ms deferred
## default so the coroutine always answers before DEFERRED_TIMEOUT fires.
const _OPEN_SETTLE_MAX_MSEC := 3000


## Open an existing scene by file path.
func open_scene(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var force_reload: bool = params.get("force_reload", false)
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var path_err = McpPathValidator.loadable_error(path, "path")
	if path_err != null:
		return path_err

	if not ResourceLoader.exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Scene not found: %s" % path)

	var scene_root := EditorInterface.get_edited_scene_root()
	var current_path := scene_root.scene_file_path if scene_root else ""
	## Instance id of the root at call time. A completed open OR reload always
	## replaces the edited-scene root with a NEW instance, so this is the
	## reliable completion signal — unlike scene_file_path, which is unchanged
	## across a force_reload of the already-open scene (#633 review).
	var prev_root_id := scene_root.get_instance_id() if scene_root else 0
	var payload := {
		"path": path,
		"force_reload": force_reload,
		"reloaded_from_disk": false,
		"previous_scene_path": current_path,
		"undoable": false,
		"reason": "Scene navigation cannot be undone via editor undo",
	}

	if current_path == path and not force_reload:
		## Already the edited scene — nothing switches, reply immediately.
		payload["switched"] = true
		payload["settle"] = "already_current"
		return {"data": payload}

	if force_reload and current_path == path:
		EditorInterface.reload_scene_from_path(path)
		payload["reloaded_from_disk"] = true
	else:
		EditorInterface.open_scene_from_path(path)

	## The tab switch completes asynchronously; replying now lets an immediate
	## follow-up write land on the PREVIOUS scene (#633 — a scene_save issued
	## right after open_scene saved the old scene). Defer the reply until the
	## edited scene actually is `path` AND its root is a fresh instance, so
	## success means "the editor is now editing the (re)loaded scene".
	var request_id: String = params.get("_request_id", "")
	if _connection != null and not request_id.is_empty():
		_finish_open_scene_deferred(_connection, request_id, path, prev_root_id, payload)
		return McpDispatcher.DEFERRED_RESPONSE

	## Synchronous fallback (batch_execute and unit-test contexts can't await):
	## preserve the old reply-immediately behavior, flagged as not waited on.
	payload["switched"] = false
	payload["settle"] = "not_waited"
	return {"data": payload}


## `static` is load-bearing (same reason as FilesystemHandler's deferred scan
## finish): the coroutine must outlive this RefCounted handler, which can be
## freed mid-await by an editor_reload_plugin. Parameterise everything;
## reference no instance state.
static func _finish_open_scene_deferred(
	connection: McpConnection,
	request_id: String,
	path: String,
	prev_root_id: int,
	payload: Dictionary,
) -> void:
	if not is_instance_valid(connection):
		return
	var tree := connection.get_tree()
	if tree == null:
		return
	# Hand back a frame so _dispatch() registers this request as deferred
	# before the coroutine can push a reply.
	await tree.process_frame
	var deadline_ms := Time.get_ticks_msec() + _OPEN_SETTLE_MAX_MSEC
	while Time.get_ticks_msec() < deadline_ms:
		var root := EditorInterface.get_edited_scene_root()
		# Require BOTH the target path AND a fresh root instance: a
		# force_reload keeps scene_file_path == path across the reload, so the
		# instance swap is what proves the (re)load actually completed rather
		# than the coroutine settling on the stale pre-reload root.
		if root != null and root.scene_file_path == path and root.get_instance_id() != prev_root_id:
			if not is_instance_valid(connection):
				return
			payload["switched"] = true
			payload["settle"] = "settled"
			connection.send_deferred_response(request_id, {"data": payload})
			return
		await tree.process_frame
	if not is_instance_valid(connection):
		return
	payload["switched"] = false
	payload["settle"] = "timeout"
	connection.send_deferred_response(request_id, {"data": payload})


## Save the currently edited scene.
## Pauses WebSocket processing during save to prevent re-entrant _process()
## calls during EditorNode::_save_scene_with_preview's thumbnail render.
func save_scene(_params: Dictionary) -> Dictionary:
	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var path := scene_root.scene_file_path
	if path.is_empty():
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Current scene has never been saved; call scene_manage(op='save_as') with a res://... path ending in .tscn or .scn."
		)

	if _connection:
		_connection.pause_processing = true
	var err := _save_current_scene()
	if _connection:
		_connection.pause_processing = false

	if err != OK:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to save scene: %s" % error_string(err))

	return {
		"data": {
			"path": path,
			"undoable": false,
			"reason": "File save cannot be undone via editor undo",
		}
	}


## Save the currently edited scene to a new file path.
func save_scene_as(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err

	if not path.ends_with(".tscn") and not path.ends_with(".scn"):
		path += ".tscn"

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	if _connection:
		_connection.pause_processing = true
	_save_current_scene_as(path)
	if _connection:
		_connection.pause_processing = false

	return {
		"data": {
			"path": path,
			"undoable": false,
			"reason": "File save cannot be undone via editor undo",
		}
	}


func _save_current_scene() -> int:
	if _save_scene_callable.is_valid():
		return int(_save_scene_callable.call())
	return EditorInterface.save_scene()


func _save_current_scene_as(path: String) -> void:
	if _save_scene_as_callable.is_valid():
		_save_scene_as_callable.call(path)
		return
	EditorInterface.save_scene_as(path)


func _walk_tree(node: Node, out: Array[Dictionary], depth: int, max_depth: int, scene_root: Node, offset: int, limit: int, index_ref: Array[int]) -> void:
	if depth > max_depth:
		return
	var idx: int = index_ref[0]
	index_ref[0] = idx + 1
	# Materialize only nodes inside the [offset, offset+limit) window. Outside
	# it we still recurse (to count total_count) but skip the per-node dict and
	# the O(depth) scene-path build — the actual cost this pagination avoids.
	var in_window := idx >= offset and (limit <= 0 or idx < offset + limit)
	if in_window:
		out.append({
			"name": node.name,
			"type": node.get_class(),
			"path": McpScenePath.from_node(node, scene_root),
			"children_count": node.get_child_count(),
		})
	for child in node.get_children():
		_walk_tree(child, out, depth + 1, max_depth, scene_root, offset, limit, index_ref)
