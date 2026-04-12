@tool
class_name NodeHandler
extends RefCounted

## Handles node creation and manipulation with undo/redo support.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func create_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", "")

	if node_type.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: type")

	if not ClassDB.class_exists(node_type):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown node type: %s" % node_type)
	if not ClassDB.is_parent_class(node_type, "Node"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "%s is not a Node type" % node_type)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var new_node: Node = ClassDB.instantiate(node_type)
	if new_node == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % node_type)

	if not node_name.is_empty():
		new_node.name = node_name

	_undo_redo.create_action("MCP: Create %s" % new_node.name)
	_undo_redo.add_do_method(parent, "add_child", new_node, true)
	_undo_redo.add_do_method(new_node, "set_owner", scene_root)
	_undo_redo.add_do_reference(new_node)
	_undo_redo.add_undo_method(parent, "remove_child", new_node)
	_undo_redo.commit_action()

	return {
		"data": {
			"name": new_node.name,
			"type": new_node.get_class(),
			"path": ScenePath.from_node(new_node, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
			"undoable": true,
		}
	}


func get_node_properties(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	var properties: Array[Dictionary] = []
	for prop in node.get_property_list():
		var usage: int = prop.get("usage", 0)
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		# Safe read: custom script getters can error; skip bad properties
		# rather than letting one bad read timeout the entire request.
		var value = node.get(prop.name)
		if value == null and prop.type != TYPE_NIL:
			continue
		properties.append({
			"name": prop.name,
			"type": type_string(prop.type),
			"value": _serialize_value(value),
		})
	return {
		"data": {
			"path": node_path,
			"node_type": node.get_class(),
			"properties": properties,
			"count": properties.size(),
		}
	}


func get_children(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	var children: Array[Dictionary] = []
	for child in node.get_children():
		children.append({
			"name": child.name,
			"type": child.get_class(),
			"path": ScenePath.from_node(child, scene_root),
			"children_count": child.get_child_count(),
		})
	return {
		"data": {
			"parent_path": node_path,
			"children": children,
			"count": children.size(),
		}
	}


func get_groups(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var groups: Array[String] = []
	for group in node.get_groups():
		# Skip internal groups (start with underscore)
		if not str(group).begins_with("_"):
			groups.append(str(group))
	return {
		"data": {
			"path": node_path,
			"groups": groups,
			"count": groups.size(),
		}
	}


## Validate path param, resolve to node. Returns dict with node/path/scene_root
## on success, or an error dict (has "error" key) on failure.
func _resolve_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	return {"node": node, "path": node_path, "scene_root": scene_root}


## Convert a Godot Variant to a JSON-safe value.
static func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_TRANSFORM2D:
			return str(value)
		TYPE_TRANSFORM3D:
			return str(value)
		TYPE_NODE_PATH:
			return str(value)
		TYPE_OBJECT:
			if value is Resource and value.resource_path:
				return value.resource_path
			return str(value)
		_:
			return str(value)
