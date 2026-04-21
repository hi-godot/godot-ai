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

	var scene_check := ScenePath.require_edited_scene(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ScenePath.format_parent_error(parent_path, scene_root))

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

	var root_err := _reject_if_scene_root(node, scene_root, "delete")
	if root_err != null:
		return root_err

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ScenePath.format_parent_error(new_parent_path, scene_root))

	var root_err := _reject_if_scene_root(node, scene_root, "reparent")
	if root_err != null:
		return root_err

	# Prevent reparenting a node to itself or to one of its own descendants.
	# Godot's `A.is_ancestor_of(B)` returns true iff B is a descendant of A, so
	# the direction here matters: we want `node.is_ancestor_of(new_parent)` to
	# catch "new_parent is below node in the tree" and thus would create a
	# cycle. The previous direction (`new_parent.is_ancestor_of(node)`) asked
	# the opposite question — whether we were trying to move a node to one of
	# its own ancestors — which is a perfectly valid operation. See issue #121.
	if node == new_parent or node.is_ancestor_of(new_parent):
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, McpPropertyErrors.build_message(node, property))

	var old_value = node.get(property)
	# Prefer declared property type; fall back to runtime type for dynamic props
	# (scripted @export vars can report TYPE_NIL in the property list).
	var target_type: int = prop_type if prop_type != TYPE_NIL else typeof(old_value)

	var instantiated_resource := false

	if target_type == TYPE_OBJECT and value is String:
		if value == "":
			value = null
		else:
			var loaded := ResourceLoader.load(value)
			if loaded == null:
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % value)
			value = loaded
	elif target_type == TYPE_OBJECT and value is Dictionary and value.has("__class__"):
		# Shortcut: {"__class__": "BoxMesh", "size": {...}} instantiates a
		# fresh Resource subclass and applies the remaining keys as
		# properties. Mirrors resource_create's inline-assign path but
		# avoids a separate tool call for the common case.
		var type_str: String = value.get("__class__", "")
		var class_err := ResourceHandler._validate_resource_class(type_str)
		if class_err != null:
			return class_err
		var instance := ClassDB.instantiate(type_str)
		if instance == null or not (instance is Resource):
			return McpErrorCodes.make(
				McpErrorCodes.INTERNAL_ERROR,
				"Failed to instantiate %s as a Resource" % type_str
			)
		var res: Resource = instance
		var remaining: Dictionary = (value as Dictionary).duplicate()
		remaining.erase("__class__")
		if not remaining.is_empty():
			var apply_err := ResourceHandler._apply_resource_properties(res, remaining)
			if apply_err != null:
				return apply_err
		value = res
		instantiated_resource = true
	else:
		value = _coerce_value(value, target_type)
		## Refuse wrong-shape dicts that _coerce_value passed through (#123).
		var coerce_err := _check_dict_coerce_failed(value, target_type)
		if coerce_err != null:
			return coerce_err

	_undo_redo.create_action("MCP: Set %s.%s" % [node.name, property])
	_undo_redo.add_do_property(node, property, value)
	_undo_redo.add_undo_property(node, property, old_value)
	if instantiated_resource:
		_undo_redo.add_do_reference(value)
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

	## The scene root's name is baked into the .tscn serialization and is
	## referenced by every NodePath that starts with `/<root>` (AnimationPlayer
	## tracks, RemoteTransform3D targets, exported NodePath @vars, etc.).
	## Renaming it silently breaks those references. The MCP tool's docstring
	## has always promised "Cannot rename the scene root" — enforce it. #122
	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot rename the scene root")

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

	var root_err := _reject_if_scene_root(node, scene_root, "duplicate")
	if root_err != null:
		return root_err

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

	var root_err := _reject_if_scene_root(node, scene_root, "reorder")
	if root_err != null:
		return root_err

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


## Canonical dict-key sets for dict→Variant coercion. Alpha on `COLOR_KEYS`
## is optional — the coercer defaults it to 1.0 when absent.
const VECTOR2_KEYS: Array[String] = ["x", "y"]
const VECTOR3_KEYS: Array[String] = ["x", "y", "z"]
const COLOR_KEYS: Array[String] = ["r", "g", "b"]


## End-to-end coerce check for validation handlers (curve, texture,
## resource properties). Returns a full `make(...)`-shaped error dict
## (prefixed with `prefix`) if the value didn't land as the target
## Variant type, else null. Dict-shape failures get the
## `_check_dict_coerce_failed` message (expected-vs-got keys); non-dict
## non-Vector inputs (String, int, …) get a generic "must coerce"
## message.
##
## Only TYPE_VECTOR2 / TYPE_VECTOR3 / TYPE_COLOR are recognized — other
## targets would false-negative on a valid value. Extend the match
## alongside `_coerce_value` if you add a new coerce target.
static func _check_coerced(value: Variant, target_type: int, prefix: String) -> Variant:
	var err = _check_dict_coerce_failed(value, target_type)
	if err != null:
		return McpErrorCodes.prefix_message(err, prefix)
	var ok := false
	match target_type:
		TYPE_VECTOR2:
			ok = value is Vector2
		TYPE_VECTOR3:
			ok = value is Vector3
		TYPE_COLOR:
			ok = value is Color
	if not ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s: must coerce to %s, got %s" % [prefix, type_string(target_type), type_string(typeof(value))],
		)
	return null


## Detect a failed dict→typed-Variant coercion. Returns an INVALID_PARAMS
## error dict if `value` is still a Dictionary after a coercion attempt
## targeting a Vector2/Vector3/Color slot, else null. Message names the
## expected keys and the keys actually received so agents self-correct
## on the next retry.
static func _check_dict_coerce_failed(value: Variant, target_type: int) -> Variant:
	if not (value is Dictionary):
		return null
	var expected: Array[String] = []
	var type_name := ""
	match target_type:
		TYPE_VECTOR2:
			expected = VECTOR2_KEYS
			type_name = "Vector2"
		TYPE_VECTOR3:
			expected = VECTOR3_KEYS
			type_name = "Vector3"
		TYPE_COLOR:
			expected = COLOR_KEYS
			type_name = "Color"
		_:
			return null
	var got_keys: Array = (value as Dictionary).keys()
	return McpErrorCodes.make(
		McpErrorCodes.INVALID_PARAMS,
		"Cannot coerce dict to %s: expected keys %s; got %s" % [type_name, str(expected), str(got_keys)]
	)


## Coerce JSON-shaped values into Godot Variants when the target property
## type is known. Returns the coerced value on success, or the input
## unchanged on failure — callers detect the type mismatch via an
## `is <Type>` check (curve_handler, texture_handler) or via the
## `_check_dict_coerce_failed` helper (set_property, resource_handler).
##
## Dictionary→Vector2/Vector3/Color cases REQUIRE all canonical keys;
## wrong-shape dicts flow through unchanged. See issue #123 — previous
## `dict.get(key, 0)` defaults silently zero-filled missing axes.
static func _coerce_value(value: Variant, target_type: int) -> Variant:
	match target_type:
		TYPE_VECTOR2:
			if value is Dictionary and value.has_all(VECTOR2_KEYS):
				return Vector2(value["x"], value["y"])
		TYPE_VECTOR3:
			if value is Dictionary and value.has_all(VECTOR3_KEYS):
				return Vector3(value["x"], value["y"], value["z"])
		TYPE_COLOR:
			if value is Dictionary and value.has_all(COLOR_KEYS):
				return Color(value["r"], value["g"], value["b"], value.get("a", 1.0))
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
	var scene_check := ScenePath.require_edited_scene(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node
	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	return {"node": node, "path": node_path, "scene_root": scene_root}


## Reject operations targeting the scene root. Returns an INVALID_PARAMS error
## dict with "Cannot <op> the scene root", or null if `node` is not the root.
static func _reject_if_scene_root(node: Node, scene_root: Node, op: String) -> Variant:
	if node == scene_root:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Cannot %s the scene root" % op)
	return null


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
