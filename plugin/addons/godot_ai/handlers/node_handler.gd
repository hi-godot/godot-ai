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
	var scene_path: String = params.get("scene_path", "")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var new_node: Node

	if not scene_path.is_empty():
		# Scene instancing path — load and instantiate a PackedScene.
		# GEN_EDIT_STATE_INSTANCE makes the editor treat the result as a real
		# scene instance (foldout icon, the .tscn stores a reference instead of
		# an exploded subtree). Descendants remain owned by their sub-scene;
		# setting their owner to our scene_root would break the instance link.
		if not scene_path.begins_with("res://"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "scene_path must start with res://")
		if not ResourceLoader.exists(scene_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Scene not found: %s" % scene_path)
		var packed_scene = ResourceLoader.load(scene_path)
		if packed_scene == null or not packed_scene is PackedScene:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a PackedScene" % scene_path)
		new_node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		if new_node == null:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate scene: %s" % scene_path)
	else:
		# ClassDB path — create by type.
		if node_type.is_empty():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: type (or provide scene_path)")
		if not ClassDB.class_exists(node_type):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown node type: %s" % node_type)
		if not ClassDB.is_parent_class(node_type, "Node"):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "%s is not a Node type" % node_type)
		new_node = ClassDB.instantiate(node_type)
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

	var response := {
		"name": new_node.name,
		"type": new_node.get_class(),
		"path": ScenePath.from_node(new_node, scene_root),
		"parent_path": ScenePath.from_node(parent, scene_root),
		"undoable": true,
	}
	if not scene_path.is_empty():
		response["scene_path"] = scene_path
	return {"data": response}


func delete_node(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot delete the scene root")

	var parent := node.get_parent()
	var idx := node.get_index()

	_undo_redo.create_action("MCP: Delete %s" % node.name)
	_undo_redo.add_do_method(parent, "remove_child", node)
	_undo_redo.add_undo_method(parent, "add_child", node, true)
	_undo_redo.add_undo_method(parent, "move_child", node, idx)
	_undo_redo.add_undo_method(node, "set_owner", scene_root)
	_undo_redo.add_undo_reference(node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"undoable": true,
		}
	}


func reparent_node(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	var new_parent_path: String = params.get("new_parent", "")
	if new_parent_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: new_parent")

	var new_parent := ScenePath.resolve(new_parent_path, scene_root)
	if new_parent == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % new_parent_path)

	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot reparent the scene root")

	# Prevent reparenting a node to one of its own descendants
	if new_parent.is_ancestor_of(node) or new_parent == node:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot reparent a node to itself or its descendant")

	var old_parent := node.get_parent()
	var old_idx := node.get_index()

	_undo_redo.create_action("MCP: Reparent %s" % node.name)
	_undo_redo.add_do_method(old_parent, "remove_child", node)
	_undo_redo.add_do_method(new_parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(new_parent, "remove_child", node)
	_undo_redo.add_undo_method(old_parent, "add_child", node, true)
	_undo_redo.add_undo_method(old_parent, "move_child", node, old_idx)
	_undo_redo.add_undo_method(node, "set_owner", scene_root)
	_undo_redo.add_undo_reference(node)
	_undo_redo.commit_action()

	# Re-set owner for all descendants (reparent can break ownership chain)
	_set_owner_recursive(node, scene_root)

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"old_parent": ScenePath.from_node(old_parent, scene_root),
			"new_parent": ScenePath.from_node(new_parent, scene_root),
			"undoable": true,
		}
	}


func set_property(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	var property: String = params.get("property", "")
	if property.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: property")

	if not "value" in params:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: value")

	var value = params.get("value")

	var found := false
	var prop_type: int = TYPE_NIL
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not found:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Property '%s' not found on %s" % [property, node.get_class()])

	var old_value = node.get(property)
	# Prefer declared property type; fall back to runtime type for dynamic props
	# (scripted @export vars can report TYPE_NIL in the property list).
	var target_type: int = prop_type if prop_type != TYPE_NIL else typeof(old_value)

	if target_type == TYPE_OBJECT and value is String:
		if value == "":
			value = null
		else:
			var loaded := ResourceLoader.load(value)
			if loaded == null:
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % value)
			value = loaded
	else:
		value = _coerce_value(value, target_type)

	_undo_redo.create_action("MCP: Set %s.%s" % [node.name, property])
	_undo_redo.add_do_property(node, property, value)
	_undo_redo.add_undo_property(node, property, old_value)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"property": property,
			"value": _serialize_value(node.get(property)),
			"old_value": _serialize_value(old_value),
			"undoable": true,
		}
	}


func rename_node(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	var new_name: String = params.get("new_name", "")
	if new_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: new_name")

	if new_name.validate_node_name() != new_name:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid characters in name: %s" % new_name)

	var old_name := String(node.name)
	if old_name == new_name:
		return {
			"data": {
				"path": node_path,
				"name": new_name,
				"old_name": old_name,
				"unchanged": true,
				"undoable": false,
				"reason": "Name unchanged",
			}
		}

	# Scene root has no siblings, so skip sibling collision check.
	if node != scene_root:
		var parent := node.get_parent()
		for sibling in parent.get_children():
			if sibling != node and String(sibling.name) == new_name:
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "A sibling already has the name '%s'" % new_name)

	_undo_redo.create_action("MCP: Rename %s to %s" % [old_name, new_name])
	_undo_redo.add_do_property(node, "name", new_name)
	_undo_redo.add_undo_property(node, "name", old_name)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"old_path": node_path,
			"name": String(node.name),
			"old_name": old_name,
			"undoable": true,
		}
	}


func duplicate_node(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot duplicate the scene root")

	var parent := node.get_parent()
	var dup: Node = node.duplicate()
	if dup == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to duplicate node")

	# Apply optional name
	var new_name: String = params.get("name", "")
	if not new_name.is_empty():
		dup.name = new_name

	_undo_redo.create_action("MCP: Duplicate %s" % node.name)
	_undo_redo.add_do_method(parent, "add_child", dup, true)
	_undo_redo.add_do_method(dup, "set_owner", scene_root)
	_undo_redo.add_do_reference(dup)
	_undo_redo.add_undo_method(parent, "remove_child", dup)
	_undo_redo.commit_action()

	# Set owner for all descendants of the duplicate
	_set_owner_recursive(dup, scene_root)

	return {
		"data": {
			"path": ScenePath.from_node(dup, scene_root),
			"original_path": node_path,
			"name": dup.name,
			"type": dup.get_class(),
			"undoable": true,
		}
	}


func move_node(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot reorder the scene root")

	if not "index" in params:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: index")

	var new_index: int = params.get("index", 0)
	var parent := node.get_parent()
	var old_index := node.get_index()
	var sibling_count := parent.get_child_count()

	if new_index < 0 or new_index >= sibling_count:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Index %d out of range (0..%d)" % [new_index, sibling_count - 1])

	_undo_redo.create_action("MCP: Move %s to index %d" % [node.name, new_index])
	_undo_redo.add_do_method(parent, "move_child", node, new_index)
	_undo_redo.add_undo_method(parent, "move_child", node, old_index)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"old_index": old_index,
			"new_index": new_index,
			"undoable": true,
		}
	}


func add_to_group(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var group: String = params.get("group", "")
	if group.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: group")

	if node.is_in_group(group):
		return {"data": {"path": node_path, "group": group, "already_member": true, "undoable": false, "reason": "No change made"}}

	_undo_redo.create_action("MCP: Add %s to group %s" % [node.name, group])
	_undo_redo.add_do_method(node, "add_to_group", group, true)
	_undo_redo.add_undo_method(node, "remove_from_group", group)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"group": group,
			"undoable": true,
		}
	}


func remove_from_group(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var group: String = params.get("group", "")
	if group.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: group")

	if not node.is_in_group(group):
		return {"data": {"path": node_path, "group": group, "not_member": true, "undoable": false, "reason": "Node not in group"}}

	_undo_redo.create_action("MCP: Remove %s from group %s" % [node.name, group])
	_undo_redo.add_do_method(node, "remove_from_group", group)
	_undo_redo.add_undo_method(node, "add_to_group", group, true)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"group": group,
			"undoable": true,
		}
	}


func set_selection(params: Dictionary) -> Dictionary:
	var paths: Array = params.get("paths", [])
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var selection := EditorInterface.get_selection()
	selection.clear()

	var selected: Array[String] = []
	var not_found: Array[String] = []
	for path_variant in paths:
		var path: String = str(path_variant)
		var node := ScenePath.resolve(path, scene_root)
		if node:
			selection.add_node(node)
			selected.append(path)
		else:
			not_found.append(path)

	return {
		"data": {
			"selected": selected,
			"not_found": not_found,
			"count": selected.size(),
			"undoable": false,
			"reason": "Selection changes are not tracked in undo history",
		}
	}


func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.set_owner(owner)
		_set_owner_recursive(child, owner)


## Coerce a JSON value to match the expected Godot type.
static func _coerce_value(value: Variant, target_type: int) -> Variant:
	match target_type:
		TYPE_VECTOR2:
			if value is Dictionary:
				return Vector2(value.get("x", 0), value.get("y", 0))
		TYPE_VECTOR3:
			if value is Dictionary:
				return Vector3(value.get("x", 0), value.get("y", 0), value.get("z", 0))
		TYPE_COLOR:
			if value is Dictionary:
				return Color(value.get("r", 0), value.get("g", 0), value.get("b", 0), value.get("a", 1))
			if value is String:
				return Color(value)
		TYPE_BOOL:
			if value is float or value is int:
				return bool(value)
		TYPE_INT:
			if value is float:
				return int(value)
		TYPE_FLOAT:
			if value is int:
				return float(value)
		TYPE_STRING_NAME:
			if value is String:
				return StringName(value)
		TYPE_NODE_PATH:
			if value is String:
				return NodePath(value)
			if value == null:
				return NodePath()
		TYPE_OBJECT:
			# Resource loading is handled in set_property so we can return a
			# typed error; here we only pass through cleared values.
			if value == null:
				return null
		TYPE_ARRAY:
			if value is Array:
				return value
		TYPE_DICTIONARY:
			if value is Dictionary:
				return value
	return value


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
		TYPE_STRING_NAME:
			return str(value)
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
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(_serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var out := {}
			for k in value:
				out[str(k)] = _serialize_value(value[k])
			return out
		TYPE_OBJECT:
			if value is Resource and value.resource_path:
				return value.resource_path
			return str(value)
		_:
			return str(value)
