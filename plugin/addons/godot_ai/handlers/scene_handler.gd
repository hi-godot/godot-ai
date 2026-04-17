@tool
class_name SceneHandler
extends RefCounted

## Handles scene tree reading and node search.

var _connection: Connection


func _init(connection: Connection = null) -> void:
	_connection = connection


func get_scene_tree(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("depth", 10)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {"data": {"nodes": [], "message": "No scene open"}}

	var nodes: Array[Dictionary] = []
	_walk_tree(scene_root, nodes, 0, max_depth, scene_root)
	return {"data": {"nodes": nodes, "total_count": nodes.size()}}


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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "At least one filter (name, type, group) is required")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

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
			"path": ScenePath.from_node(node, scene_root),
		})

	for child in node.get_children():
		_find_recursive(child, scene_root, name_filter, type_filter, group_filter, out)


## Create a new scene with the given root node type, save to disk, and open it.
func create_scene(params: Dictionary) -> Dictionary:
	var root_type: String = params.get("root_type", "Node3D")
	var path: String = params.get("path", "")

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	if not path.ends_with(".tscn") and not path.ends_with(".scn"):
		path += ".tscn"

	if not ClassDB.class_exists(root_type):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown node type: %s" % root_type)
	if not ClassDB.is_parent_class(root_type, "Node"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "%s is not a Node type" % root_type)

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var root: Node = ClassDB.instantiate(root_type)
	if root == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % root_type)

	var root_name: String = params.get("root_name", "")
	if root_name.is_empty():
		root_name = path.get_file().get_basename()
	root.name = root_name

	var packed := PackedScene.new()
	packed.pack(root)
	root.free()

	if _connection:
		_connection.pause_processing = true
	var err := ResourceSaver.save(packed, path)
	EditorInterface.open_scene_from_path(path)
	if _connection:
		_connection.pause_processing = false

	if err != OK:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to save scene: %s" % error_string(err))

	return {
		"data": {
			"path": path,
			"root_type": root_type,
			"root_name": root_name,
			"undoable": false,
			"reason": "Scene creation involves file system operations",
		}
	}


## Open an existing scene by file path.
func open_scene(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not ResourceLoader.exists(path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Scene not found: %s" % path)

	EditorInterface.open_scene_from_path(path)

	return {
		"data": {
			"path": path,
			"undoable": false,
			"reason": "Scene navigation cannot be undone via editor undo",
		}
	}


## Save the currently edited scene.
## Pauses WebSocket processing during save to prevent re-entrant _process()
## calls during EditorNode::_save_scene_with_preview's thumbnail render.
func save_scene(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	if _connection:
		_connection.pause_processing = true
	var err := EditorInterface.save_scene()
	if _connection:
		_connection.pause_processing = false

	if err != OK:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to save scene: %s" % error_string(err))

	return {
		"data": {
			"path": scene_root.scene_file_path,
			"undoable": false,
			"reason": "File save cannot be undone via editor undo",
		}
	}


## Save the currently edited scene to a new file path.
func save_scene_as(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	if not path.ends_with(".tscn") and not path.ends_with(".scn"):
		path += ".tscn"

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	if _connection:
		_connection.pause_processing = true
	EditorInterface.save_scene_as(path)
	if _connection:
		_connection.pause_processing = false

	return {
		"data": {
			"path": path,
			"undoable": false,
			"reason": "File save cannot be undone via editor undo",
		}
	}


func _walk_tree(node: Node, out: Array[Dictionary], depth: int, max_depth: int, scene_root: Node) -> void:
	if depth > max_depth:
		return
	out.append({
		"name": node.name,
		"type": node.get_class(),
		"path": ScenePath.from_node(node, scene_root),
		"children_count": node.get_child_count(),
	})
	for child in node.get_children():
		_walk_tree(child, out, depth + 1, max_depth, scene_root)
