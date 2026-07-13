@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

## Handles node creation and manipulation with undo/redo support.

const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func create_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", "")
	var scene_path: String = params.get("scene_path", "")

	var scene_check := McpScenePath.require_edited_scene(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(parent_path, scene_root))

	var new_node: Node

	if not scene_path.is_empty():
		# Scene instancing path — load and instantiate a PackedScene.
		# GEN_EDIT_STATE_INSTANCE makes the editor treat the result as a real
		# scene instance (foldout icon, the .tscn stores a reference instead of
		# an exploded subtree). Descendants remain owned by their sub-scene;
		# setting their owner to our scene_root would break the instance link.
		var scene_path_err = McpPathValidator.loadable_error(scene_path, "scene_path")
		if scene_path_err != null:
			return scene_path_err
		if not ResourceLoader.exists(scene_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Scene not found: %s" % scene_path)
		var packed_scene = ResourceLoader.load(scene_path)
		if packed_scene == null or not packed_scene is PackedScene:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a PackedScene" % scene_path)
		new_node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		if new_node == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate scene: %s" % scene_path)
	else:
		# ClassDB path — create by type.
		if node_type.is_empty():
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: type (or provide scene_path)")
		if not ClassDB.class_exists(node_type):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown node type: %s" % node_type)
		if not ClassDB.is_parent_class(node_type, "Node"):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s is not a Node type" % node_type)
		new_node = ClassDB.instantiate(node_type)
		if new_node == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % node_type)

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
		"path": McpScenePath.from_node(new_node, scene_root),
		"parent_path": McpScenePath.from_node(parent, scene_root),
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: new_parent")

	var new_parent := McpScenePath.resolve(new_parent_path, scene_root)
	if new_parent == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(new_parent_path, scene_root))

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
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Cannot reparent a node to itself or its descendant")

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
			"path": McpScenePath.from_node(node, scene_root),
			"old_parent": McpScenePath.from_node(old_parent, scene_root),
			"new_parent": McpScenePath.from_node(new_parent, scene_root),
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: property")

	if not "value" in params:
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: value")

	var value = params.get("value")

	var found := false
	var prop_type: int = TYPE_NIL
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not found:
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS, McpPropertyErrors.build_message(node, property))

	var old_value = node.get(property)
	# Prefer declared property type; fall back to runtime type for dynamic props
	# (scripted @export vars can report TYPE_NIL in the property list).
	var target_type: int = prop_type if prop_type != TYPE_NIL else typeof(old_value)

	var instantiated_resource := false

	# Some MCP clients (Cline) stringify the documented {"__class__": "BoxMesh", ...}
	# value before sending. Promote that string back to a Dictionary here so the
	# `__class__` branch below handles it, instead of the next branch treating
	# the JSON blob as a res:// path and emitting "Resource not found: {...}".
	# See #206.
	if target_type == TYPE_OBJECT and value is String and value.begins_with("{"):
		var json := JSON.new()
		if json.parse(value) == OK and json.data is Dictionary and (json.data as Dictionary).has("__class__"):
			value = json.data

	var nil_resource_string: bool = target_type == TYPE_NIL and (value == "" or (value is String and value.begins_with("res://")))
	var resource_string_value: bool = value is String and (target_type == TYPE_OBJECT or nil_resource_string)
	if resource_string_value:
		if value == "":
			value = null
		else:
			var value_path_err = McpPathValidator.loadable_error(value, "value")
			if value_path_err != null:
				return value_path_err
			if not ResourceLoader.exists(value):
				return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % value)
			var loaded := ResourceLoader.load(value)
			if loaded == null:
				return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % value)
			value = loaded
	elif target_type == TYPE_OBJECT and value is Dictionary and value.has("__class__"):
		# Shortcut: {"__class__": "BoxMesh", "size": {...}} instantiates a
		# fresh Resource subclass and applies the remaining keys as
		# properties. Mirrors resource_create's inline-assign path but
		# avoids a separate tool call for the common case.
		var type_str: String = value.get("__class__", "")
		var made := ResourceHandler._instantiate_resource(type_str)
		if made is Dictionary:
			return made
		var res: Resource = made
		var remaining: Dictionary = (value as Dictionary).duplicate()
		remaining.erase("__class__")
		if not remaining.is_empty():
			var apply_err := ResourceHandler._apply_resource_properties(res, remaining)
			if apply_err != null:
				return apply_err
		value = res
		instantiated_resource = true
	elif target_type == TYPE_ARRAY and old_value is Array and (old_value as Array).is_typed():
		## Typed Array[T] slot (#612): the generic TYPE_ARRAY passthrough
		## hands an untyped Array to Godot's typed setter, which rejects it
		## wholesale and leaves the slot at its default — with success still
		## reported. Route through the element-aware coercer instead; errors
		## name the offending element index.
		var typed_out: Variant = _coerce_typed_array(value, old_value)
		if typed_out is Dictionary:
			return typed_out
		value = typed_out
	elif (
		target_type == TYPE_DICTIONARY
		and old_value is Dictionary
		and (old_value as Dictionary).is_typed()
	):
		## Typed Dictionary[K, V] slot (#612 stage 3) — same silent-drop
		## family as typed arrays. A successful result is always a TYPED
		## Dictionary (a cleared duplicate of the slot), while the error
		## envelope is an untyped {"error": ...} — that's the discriminator
		## (a legit payload could contain an "error" key; typedness can't lie).
		var typed_dict_out: Dictionary = _coerce_typed_dictionary(value, old_value)
		if not typed_dict_out.is_typed():
			return typed_dict_out
		value = typed_dict_out
	else:
		value = _coerce_value(value, target_type)
		## Refuse any value that didn't land as the target compound Variant
		## — wrong-shape dict (#123) or non-dict input like list / JSON string
		## that used to silently default-construct Vector3.ZERO (#191).
		var coerce_err := _check_coerced(value, target_type)
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: new_name")

	## The scene root's name is baked into the .tscn serialization and is
	## referenced by every NodePath that starts with `/<root>` (AnimationPlayer
	## tracks, RemoteTransform3D targets, exported NodePath @vars, etc.).
	## Renaming it silently breaks those references. The MCP tool's docstring
	## has always promised "Cannot rename the scene root" — enforce it. #122
	if node == scene_root:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Cannot rename the scene root")

	if new_name.validate_node_name() != new_name:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid characters in name: %s" % new_name)

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
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "A sibling already has the name '%s'" % new_name)

	_undo_redo.create_action("MCP: Rename %s to %s" % [old_name, new_name])
	_undo_redo.add_do_property(node, "name", new_name)
	_undo_redo.add_undo_property(node, "name", old_name)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
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
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to duplicate node")

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
			"path": McpScenePath.from_node(dup, scene_root),
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: index")

	var new_index: int = params.get("index", 0)
	var parent := node.get_parent()
	var old_index := node.get_index()
	var sibling_count := parent.get_child_count()

	if new_index < 0 or new_index >= sibling_count:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Index %d out of range (0..%d)" % [new_index, sibling_count - 1])

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

	var group_value: Variant = params.get("group", "")
	var type_err := McpParamValidators.require_string("group", group_value)
	if type_err != null:
		return type_err
	var group := String(group_value)
	if group.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: group")

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

	var group_value: Variant = params.get("group", "")
	var type_err := McpParamValidators.require_string("group", group_value)
	if type_err != null:
		return type_err
	var group := String(group_value)
	if group.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: group")

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
	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var selection := EditorInterface.get_selection()
	selection.clear()

	var selected: Array[String] = []
	var not_found: Array[String] = []
	for path_variant in paths:
		var path: String = str(path_variant)
		var node := McpScenePath.resolve(path, scene_root)
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
const VECTOR4_KEYS: Array[String] = ["x", "y", "z", "w"]
const COLOR_KEYS: Array[String] = ["r", "g", "b"]


## End-to-end coerce check for compound JSON-shaped targets
## (Vector2/Vector3/Color). Returns a full `make(...)`-shaped error dict
## if `value` didn't land as the target Variant after `_coerce_value`,
## else null. Wrong-shape dicts get the `_check_dict_coerce_failed`
## message (expected-vs-got keys); non-dict inputs (Array, String,
## primitive) name the received type and a JSON shape hint. No-op for
## non-compound targets — Godot's setter handles those.
##
## Used by set_property, resource_handler, and validation handlers
## (curve, texture). Issue #191 — passing a list, JSON string, or
## anything else to a Vector3 property used to silently store
## Vector3.ZERO; this gates that path.
static func _check_coerced(value: Variant, target_type: int, prefix: String = "") -> Variant:
	var ok := false
	match target_type:
		TYPE_VECTOR2:
			ok = value is Vector2
		TYPE_VECTOR3:
			ok = value is Vector3
		TYPE_COLOR:
			ok = value is Color
		TYPE_PACKED_VECTOR2_ARRAY:
			ok = value is PackedVector2Array
		TYPE_PACKED_VECTOR3_ARRAY:
			ok = value is PackedVector3Array
		TYPE_PACKED_VECTOR4_ARRAY:
			ok = value is PackedVector4Array
		TYPE_PACKED_COLOR_ARRAY:
			ok = value is PackedColorArray
		TYPE_PACKED_INT32_ARRAY:
			ok = value is PackedInt32Array
		TYPE_PACKED_INT64_ARRAY:
			ok = value is PackedInt64Array
		TYPE_PACKED_FLOAT32_ARRAY:
			ok = value is PackedFloat32Array
		TYPE_PACKED_FLOAT64_ARRAY:
			ok = value is PackedFloat64Array
		TYPE_PACKED_STRING_ARRAY:
			ok = value is PackedStringArray
		TYPE_VECTOR2I: ok = value is Vector2i
		TYPE_VECTOR3I: ok = value is Vector3i
		TYPE_VECTOR4: ok = value is Vector4
		TYPE_VECTOR4I: ok = value is Vector4i
		TYPE_QUATERNION: ok = value is Quaternion
		TYPE_RECT2: ok = value is Rect2
		TYPE_RECT2I: ok = value is Rect2i
		TYPE_AABB: ok = value is AABB
		TYPE_PLANE: ok = value is Plane
		TYPE_BASIS: ok = value is Basis
		TYPE_TRANSFORM2D: ok = value is Transform2D
		TYPE_TRANSFORM3D: ok = value is Transform3D
		TYPE_PROJECTION: ok = value is Projection
		_:
			# null / untyped-TYPE_NIL / already-correct-type are handled by
			# Godot's setter; anything else would silently no-op, so error.
			if value == null or target_type == TYPE_NIL or typeof(value) == target_type:
				return null
			var unsupported := ErrorCodes.make(
				ErrorCodes.WRONG_TYPE,
				"Cannot write %s to a %s property; godot-ai has no coercion for that type" % [
					type_string(typeof(value)), type_string(target_type),
				],
			)
			return ErrorCodes.prefix_message(unsupported, prefix)
	if ok:
		return null
	var dict_err := _check_dict_coerce_failed(value, target_type)
	if dict_err != null:
		return ErrorCodes.prefix_message(dict_err, prefix)
	## Wording stays neutral on shape — `_shape_hint` already produces a
	## dict-shaped string for Vector2/3/Color and a list-shaped one for
	## the Packed*Array slots. The old "expected a dict like [...]" phrasing
	## read self-contradictory for packed targets (PR #424 review).
	var err := ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Cannot coerce %s to %s; expected %s" % [
			type_string(typeof(value)), type_string(target_type), _shape_hint(target_type),
		],
	)
	return ErrorCodes.prefix_message(err, prefix)


## Build a "{\"x\":1,...}" hint string from the canonical key constants
## so adding a key (e.g. Vector4) only touches VECTORN_KEYS. Packed*Array
## targets short-circuit to a literal list-shaped hint.
static func _shape_hint(target_type: int) -> String:
	match target_type:
		TYPE_PACKED_VECTOR2_ARRAY:
			return "[{\"x\":0,\"y\":0}, ...]"
		TYPE_PACKED_VECTOR3_ARRAY:
			return "[{\"x\":0,\"y\":0,\"z\":0}, ...]"
		TYPE_PACKED_VECTOR4_ARRAY:
			return "[{\"x\":0,\"y\":0,\"z\":0,\"w\":0}, ...]"
		TYPE_PACKED_COLOR_ARRAY:
			return "[{\"r\":0,\"g\":0,\"b\":0,\"a\":1}, ...]"
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return "[int, ...]"
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return "[float, ...]"
		TYPE_PACKED_STRING_ARRAY:
			return "[\"...\", ...]"
		TYPE_VECTOR2I:
			return "{\"x\":0,\"y\":0}"
		TYPE_VECTOR3I:
			return "{\"x\":0,\"y\":0,\"z\":0}"
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return "{\"x\":0,\"y\":0,\"z\":0,\"w\":0}"
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return "{\"position\":{...},\"size\":{...}}"
		TYPE_PLANE:
			return "{\"normal\":{...},\"d\":0}"
		TYPE_BASIS:
			return "{\"x\":{...},\"y\":{...},\"z\":{...}}"
		TYPE_TRANSFORM2D:
			return "{\"x\":{...},\"y\":{...},\"origin\":{...}}"
		TYPE_TRANSFORM3D:
			return "{\"basis\":{...},\"origin\":{...}}"
		TYPE_PROJECTION:
			return "{\"x\":{...},\"y\":{...},\"z\":{...},\"w\":{...}}"
	var keys: Array[String] = []
	match target_type:
		TYPE_VECTOR2: keys = VECTOR2_KEYS
		TYPE_VECTOR3: keys = VECTOR3_KEYS
		TYPE_COLOR: keys = COLOR_KEYS
	var pairs: Array[String] = []
	for k in keys:
		pairs.append("\"%s\":0" % k)
	return "{" + ",".join(pairs) + "}"


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
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
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
		## Vector2/Vector3/Color route through the canonical strict parser
		## (#714): same dict/array/string shapes as every other handler, and
		## non-numeric components fall through (returning the original
		## value) so _check_coerced flags them instead of crashing a typed
		## constructor or silently writing black/zeros.
		TYPE_VECTOR2:
			var v2 = McpJsonValues.parse_vector2(value)
			if v2 != null:
				return v2
		TYPE_VECTOR3:
			var v3 = McpJsonValues.parse_vector3(value)
			if v3 != null:
				return v3
		TYPE_COLOR:
			var col = McpJsonValues.parse_color(value)
			if col != null:
				return col
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
		TYPE_PACKED_VECTOR2_ARRAY:
			if value is Array:
				var out := PackedVector2Array()
				for item in value:
					if item is Vector2:
						out.append(item)
					elif item is Dictionary and item.has_all(VECTOR2_KEYS):
						out.append(Vector2(item["x"], item["y"]))
					else:
						return value  # leave for _check_coerced to flag
				return out
		TYPE_PACKED_VECTOR3_ARRAY:
			if value is Array:
				var out := PackedVector3Array()
				for item in value:
					if item is Vector3:
						out.append(item)
					elif item is Dictionary and item.has_all(VECTOR3_KEYS):
						out.append(Vector3(item["x"], item["y"], item["z"]))
					else:
						return value
				return out
		TYPE_PACKED_VECTOR4_ARRAY:
			if value is Array:
				var out := PackedVector4Array()
				for item in value:
					if item is Vector4:
						out.append(item)
					elif item is Dictionary and item.has_all(VECTOR4_KEYS):
						out.append(Vector4(item["x"], item["y"], item["z"], item["w"]))
					else:
						return value
				return out
		TYPE_PACKED_COLOR_ARRAY:
			if value is Array:
				var out := PackedColorArray()
				for item in value:
					if item is Color:
						out.append(item)
					elif item is Dictionary and item.has_all(COLOR_KEYS):
						out.append(Color(item["r"], item["g"], item["b"], item.get("a", 1.0)))
					elif item is String:
						out.append(Color(item))
					else:
						return value
				return out
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			if value is Array:
				var out: Variant = PackedInt32Array() if target_type == TYPE_PACKED_INT32_ARRAY else PackedInt64Array()
				for item in value:
					if item is int or item is float:
						out.append(int(item))
					else:
						return value
				return out
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			if value is Array:
				var out: Variant = PackedFloat32Array() if target_type == TYPE_PACKED_FLOAT32_ARRAY else PackedFloat64Array()
				for item in value:
					if item is float or item is int:
						out.append(float(item))
					else:
						return value
				return out
		TYPE_PACKED_STRING_ARRAY:
			if value is Array:
				var out := PackedStringArray()
				for item in value:
					if item is String:
						out.append(item)
					else:
						return value
				return out
		TYPE_VECTOR2I:
			if value is Dictionary and value.has_all(VECTOR2_KEYS):
				return Vector2i(int(value["x"]), int(value["y"]))
		TYPE_VECTOR3I:
			if value is Dictionary and value.has_all(VECTOR3_KEYS):
				return Vector3i(int(value["x"]), int(value["y"]), int(value["z"]))
		TYPE_VECTOR4:
			if value is Dictionary and value.has_all(VECTOR4_KEYS):
				return Vector4(value["x"], value["y"], value["z"], value["w"])
		TYPE_VECTOR4I:
			if value is Dictionary and value.has_all(VECTOR4_KEYS):
				return Vector4i(int(value["x"]), int(value["y"]), int(value["z"]), int(value["w"]))
		TYPE_QUATERNION:
			if value is Dictionary and value.has_all(VECTOR4_KEYS):
				return Quaternion(value["x"], value["y"], value["z"], value["w"])
		TYPE_RECT2:
			if value is Dictionary and value.has("position") and value.has("size"):
				var p: Variant = _coerce_value(value["position"], TYPE_VECTOR2)
				var s: Variant = _coerce_value(value["size"], TYPE_VECTOR2)
				if p is Vector2 and s is Vector2:
					return Rect2(p, s)
		TYPE_RECT2I:
			if value is Dictionary and value.has("position") and value.has("size"):
				var p: Variant = _coerce_value(value["position"], TYPE_VECTOR2I)
				var s: Variant = _coerce_value(value["size"], TYPE_VECTOR2I)
				if p is Vector2i and s is Vector2i:
					return Rect2i(p, s)
		TYPE_AABB:
			if value is Dictionary and value.has("position") and value.has("size"):
				var p: Variant = _coerce_value(value["position"], TYPE_VECTOR3)
				var s: Variant = _coerce_value(value["size"], TYPE_VECTOR3)
				if p is Vector3 and s is Vector3:
					return AABB(p, s)
		TYPE_PLANE:
			if value is Dictionary and value.has("normal") and value.has("d"):
				var n: Variant = _coerce_value(value["normal"], TYPE_VECTOR3)
				if n is Vector3:
					return Plane(n, float(value["d"]))
		TYPE_BASIS:
			if value is Dictionary and value.has_all(["x", "y", "z"]):
				var bx: Variant = _coerce_value(value["x"], TYPE_VECTOR3)
				var by: Variant = _coerce_value(value["y"], TYPE_VECTOR3)
				var bz: Variant = _coerce_value(value["z"], TYPE_VECTOR3)
				if bx is Vector3 and by is Vector3 and bz is Vector3:
					return Basis(bx, by, bz)
		TYPE_TRANSFORM2D:
			if value is Dictionary and value.has_all(["x", "y", "origin"]):
				var tx: Variant = _coerce_value(value["x"], TYPE_VECTOR2)
				var ty: Variant = _coerce_value(value["y"], TYPE_VECTOR2)
				var to_: Variant = _coerce_value(value["origin"], TYPE_VECTOR2)
				if tx is Vector2 and ty is Vector2 and to_ is Vector2:
					return Transform2D(tx, ty, to_)
		TYPE_TRANSFORM3D:
			if value is Dictionary and value.has("basis") and value.has("origin"):
				var b: Variant = _coerce_value(value["basis"], TYPE_BASIS)
				var o: Variant = _coerce_value(value["origin"], TYPE_VECTOR3)
				if b is Basis and o is Vector3:
					return Transform3D(b, o)
		TYPE_PROJECTION:
			if value is Dictionary and value.has_all(VECTOR4_KEYS):
				var px: Variant = _coerce_value(value["x"], TYPE_VECTOR4)
				var py: Variant = _coerce_value(value["y"], TYPE_VECTOR4)
				var pz: Variant = _coerce_value(value["z"], TYPE_VECTOR4)
				var pw: Variant = _coerce_value(value["w"], TYPE_VECTOR4)
				if px is Vector4 and py is Vector4 and pz is Vector4 and pw is Vector4:
					return Projection(px, py, pz, pw)
		# PackedByteArray intentionally unhandled — needs design decision
		# (base64 string vs. raw int list); JSON has no native byte type.
	return value


## Fill a typed `Array[T]` slot from a JSON list (#612 stage 1: value-element
## types). `slot_value` is the property's current typed Array — Godot's getter
## returns the (possibly empty) typed container, which carries the element
## type, so no PROPERTY_HINT_TYPE_STRING parsing is needed. Elements coerce
## one at a time through the existing `_coerce_value` / `_check_coerced`
## pair, then bulk-move via `Array.assign()` with a post-assign size check,
## so a wrong element can never silently drop the write: it errors naming
## the element index. Returns the filled typed Array on success, or a
## `make(...)`-shaped error Dictionary (callers discriminate on
## `result is Dictionary` — a successful result is always an Array).
##
## Object elements (Array[Texture2D], Array[MyResource], ...) coerce per
## element through `_coerce_object_element` (#612 stage 2), mirroring the
## single-slot TYPE_OBJECT paths: res:// strings load, {"__class__": ...}
## instantiates, and each landed element is conformance-checked against the
## slot's element class/script so a wrong-class Resource errors naming the
## index instead of being rejected wholesale by `assign`.
static func _coerce_typed_array(value: Variant, slot_value: Array, prefix: String = "") -> Variant:
	var elem_label := _typed_array_element_label(slot_value)
	if not (value is Array):
		var err := ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Cannot write %s to a typed Array[%s] property; expected a list" % [
				type_string(typeof(value)), elem_label,
			],
		)
		return ErrorCodes.prefix_message(err, prefix)
	var elem_type := slot_value.get_typed_builtin()
	var staging: Array = []
	var in_list: Array = value
	for i in in_list.size():
		var elem_prefix := ("element %d" % i) if prefix.is_empty() else "%s element %d" % [prefix, i]
		var coerced: Variant
		if elem_type == TYPE_OBJECT:
			coerced = _coerce_object_element(in_list[i], elem_prefix)
			if coerced is Dictionary:
				## Object elements are never legit Dictionaries (a dict input
				## is either {"__class__"} — consumed above — or an error), so
				## a Dictionary return is unambiguously the error envelope.
				return coerced
			if coerced != null and not _object_element_conforms(coerced, slot_value):
				var conform_err := ErrorCodes.make(
					ErrorCodes.WRONG_TYPE,
					"element is %s, which is not a %s" % [
						(coerced as Object).get_class(), elem_label,
					],
				)
				return ErrorCodes.prefix_message(conform_err, elem_prefix)
		else:
			coerced = _coerce_value(in_list[i], elem_type)
			var elem_err := _check_coerced(coerced, elem_type, elem_prefix)
			if elem_err != null:
				return elem_err
			if coerced == null:
				## Prefix with `elem_prefix` (which already folds in `prefix`),
				## not `prefix` again — the latter double-stamped the property
				## context (PR #682 review). Object arrays allow null entries
				## (Godot typed object arrays store null); value-type arrays
				## don't.
				var null_err := ErrorCodes.make(
					ErrorCodes.WRONG_TYPE,
					"cannot store null in Array[%s]" % elem_label,
				)
				return ErrorCodes.prefix_message(null_err, elem_prefix)
		staging.append(coerced)
	var out := slot_value.duplicate()
	out.clear()
	out.assign(staging)
	if out.size() != staging.size():
		## Backstop for element shapes `_check_coerced` waves through but the
		## typed container still rejects — `assign` loud-rejects and leaves a
		## short array, which without this check would be a partial write.
		var assign_err := ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Array[%s] element conversion failed during assign (%d of %d elements landed)" % [
				elem_label, out.size(), staging.size(),
			],
		)
		return ErrorCodes.prefix_message(assign_err, prefix)
	return out


## "int" / "Vector3" / "Texture2D" / "MyItemData" — element-type name of a
## typed Array slot, for error messages.
static func _typed_array_element_label(slot_value: Array) -> String:
	if slot_value.get_typed_builtin() == TYPE_OBJECT:
		return _object_type_label(slot_value.get_typed_class_name(), slot_value.get_typed_script())
	return type_string(slot_value.get_typed_builtin())


## Coerce one element of an object-typed Array (#612 stage 2). Mirrors the
## single-slot TYPE_OBJECT paths in set_property: a res:// path string loads
## the Resource; {"__class__": "X", ...} (including the #206 stringified
## form) instantiates via ResourceHandler and applies the remaining keys;
## "" / null store a null entry (typed object arrays allow them). Returns
## the Object (or null), or a make(...)-shaped error Dictionary with
## `elem_prefix` already folded in.
static func _coerce_object_element(elem: Variant, elem_prefix: String) -> Variant:
	if elem == null:
		return null
	if elem is Object:
		return elem
	if elem is String and (elem as String).begins_with("{"):
		var json := JSON.new()
		if json.parse(elem) == OK and json.data is Dictionary and (json.data as Dictionary).has("__class__"):
			elem = json.data
	if elem is String:
		if String(elem).is_empty():
			return null
		var path_err = McpPathValidator.loadable_error(elem, "value")
		if path_err != null:
			return ErrorCodes.prefix_message(path_err, elem_prefix)
		if not ResourceLoader.exists(elem):
			return ErrorCodes.prefix_message(
				ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % elem),
				elem_prefix,
			)
		var loaded := ResourceLoader.load(elem)
		if loaded == null:
			return ErrorCodes.prefix_message(
				ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % elem),
				elem_prefix,
			)
		return loaded
	if elem is Dictionary and (elem as Dictionary).has("__class__"):
		var type_str: String = (elem as Dictionary).get("__class__", "")
		var made := ResourceHandler._instantiate_resource(type_str)
		if made is Dictionary:
			return ErrorCodes.prefix_message(made, elem_prefix)
		var res: Resource = made
		var remaining: Dictionary = (elem as Dictionary).duplicate()
		remaining.erase("__class__")
		if not remaining.is_empty():
			var apply_err: Variant = ResourceHandler._apply_resource_properties(res, remaining)
			if apply_err != null:
				return ErrorCodes.prefix_message(apply_err, elem_prefix)
		return res
	return ErrorCodes.prefix_message(
		ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			'cannot convert %s to an Object element; pass a res:// path or {"__class__": ...}'
			% type_string(typeof(elem)),
		),
		elem_prefix,
	)


## True when `elem` satisfies the object-typed slot's element constraint —
## script type when the slot is Array[MyScriptClass], native class
## otherwise. Checked per element so a wrong-class Resource errors naming
## the index instead of being rejected wholesale by `Array.assign()`.
static func _object_element_conforms(elem: Object, slot_value: Array) -> bool:
	return _object_conforms(elem, slot_value.get_typed_class_name(), slot_value.get_typed_script())


## Shared class/script conformance predicate for typed Array elements and
## typed Dictionary values (#612 stages 2–3).
static func _object_conforms(elem: Object, cls_name: StringName, script: Variant) -> bool:
	if script is Script:
		return is_instance_of(elem, script)
	var cls := String(cls_name)
	return cls.is_empty() or elem.is_class(cls)


## Fill a typed `Dictionary[K, V]` slot from a JSON object (#612 stage 3).
## `slot_value` is the property's current typed Dictionary — the getter
## returns the (possibly empty) typed container carrying both constraint
## sides. Keys coerce via `_coerce_typed_dict_key` (JSON object keys are
## always Strings, so int/float/StringName key slots parse the string and
## fail closed on anything inexact); values mirror the typed-array element
## rules — object values through `_coerce_object_element` + conformance,
## everything else through `_coerce_value`/`_check_coerced`. Never partial:
## any bad key or value errors naming the key and nothing is written.
##
## Returns the filled TYPED Dictionary on success or an UNTYPED
## `make(...)`-shaped error Dictionary — callers discriminate on
## `is_typed()`, since a success result is always a duplicate of the typed
## slot and error envelopes are plain dicts.
static func _coerce_typed_dictionary(
	value: Variant, slot_value: Dictionary, prefix: String = ""
) -> Dictionary:
	var label := _typed_dictionary_label(slot_value)
	if not (value is Dictionary):
		var err := ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Cannot write %s to a typed %s property; expected an object" % [
				type_string(typeof(value)), label,
			],
		)
		return ErrorCodes.prefix_message(err, prefix)
	var key_type := slot_value.get_typed_key_builtin() if slot_value.is_typed_key() else TYPE_NIL
	var value_type := (
		slot_value.get_typed_value_builtin() if slot_value.is_typed_value() else TYPE_NIL
	)
	var out := slot_value.duplicate()
	out.clear()
	var in_dict: Dictionary = value
	for raw_key in in_dict.keys():
		var key_prefix := (
			'key "%s"' % str(raw_key) if prefix.is_empty()
			else '%s key "%s"' % [prefix, str(raw_key)]
		)
		var key: Variant = _coerce_typed_dict_key(raw_key, key_type, label, key_prefix)
		if key is Dictionary:
			## Scalar-only key coercion never returns a legit Dictionary key,
			## so a Dictionary here is unambiguously the error envelope.
			return key
		var raw_value: Variant = in_dict[raw_key]
		var coerced: Variant
		if value_type == TYPE_NIL:
			## Untyped value side (e.g. Dictionary[String, Variant]).
			coerced = raw_value
		elif value_type == TYPE_OBJECT:
			coerced = _coerce_object_element(raw_value, key_prefix)
			if coerced is Dictionary:
				return coerced
			if coerced != null and not _object_conforms(
				coerced,
				slot_value.get_typed_value_class_name(),
				slot_value.get_typed_value_script(),
			):
				var conform_err := ErrorCodes.make(
					ErrorCodes.WRONG_TYPE,
					"value is %s, which is not a %s" % [
						(coerced as Object).get_class(),
						_object_type_label(
							slot_value.get_typed_value_class_name(),
							slot_value.get_typed_value_script(),
						),
					],
				)
				return ErrorCodes.prefix_message(conform_err, key_prefix)
		else:
			coerced = _coerce_value(raw_value, value_type)
			var value_err := _check_coerced(coerced, value_type, key_prefix)
			if value_err != null:
				return value_err
			if coerced == null:
				var null_err := ErrorCodes.make(
					ErrorCodes.WRONG_TYPE,
					"cannot store null as a %s value in %s" % [type_string(value_type), label],
				)
				return ErrorCodes.prefix_message(null_err, key_prefix)
		out[key] = coerced
	if out.size() != in_dict.size():
		## Two input keys collapsing onto one coerced key ("1" and "01" both
		## parse to int 1) would silently lose an entry — refuse instead.
		var collide_err := ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s keys collide after coercion (%d of %d entries landed)" % [
				label, out.size(), in_dict.size(),
			],
		)
		return ErrorCodes.prefix_message(collide_err, prefix)
	return out


## Coerce one JSON-object key onto a typed Dictionary's key slot. JSON keys
## are always Strings, so int/float/StringName key types accept exactly the
## strings that parse cleanly; everything else fails closed naming the key.
## Object/compound key types are unreachable from JSON and refuse loudly.
static func _coerce_typed_dict_key(
	raw_key: Variant, key_type: int, label: String, key_prefix: String
) -> Variant:
	if key_type == TYPE_NIL or typeof(raw_key) == key_type:
		return raw_key
	if raw_key is String:
		var key_str := raw_key as String
		match key_type:
			TYPE_STRING_NAME:
				return StringName(key_str)
			TYPE_INT:
				if key_str.is_valid_int():
					return int(key_str)
			TYPE_FLOAT:
				if key_str.is_valid_float():
					return float(key_str)
		## String key that didn't parse: JSON object keys are ALWAYS strings,
		## so blaming the String-ness would imply the caller could somehow
		## send a non-string key — name the expected key type instead.
		var parse_err := ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"key does not parse as %s (the %s key type)" % [type_string(key_type), label],
		)
		return ErrorCodes.prefix_message(parse_err, key_prefix)
	if raw_key is float and key_type == TYPE_INT and is_equal_approx(raw_key, roundf(raw_key)):
		## Whole JSON numbers arrive as floats through some non-JSON callers.
		return int(raw_key)
	var err := ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"cannot use %s as a %s key" % [type_string(typeof(raw_key)), label],
	)
	return ErrorCodes.prefix_message(err, key_prefix)


## "Dictionary[String, int]" / "Dictionary[int, Texture2D]" — for error
## messages. Untyped sides read as Variant.
static func _typed_dictionary_label(slot_value: Dictionary) -> String:
	var key_label := "Variant"
	if slot_value.is_typed_key():
		key_label = (
			_object_type_label(
				slot_value.get_typed_key_class_name(), slot_value.get_typed_key_script()
			)
			if slot_value.get_typed_key_builtin() == TYPE_OBJECT
			else type_string(slot_value.get_typed_key_builtin())
		)
	var value_label := "Variant"
	if slot_value.is_typed_value():
		value_label = (
			_object_type_label(
				slot_value.get_typed_value_class_name(), slot_value.get_typed_value_script()
			)
			if slot_value.get_typed_value_builtin() == TYPE_OBJECT
			else type_string(slot_value.get_typed_value_builtin())
		)
	return "Dictionary[%s, %s]" % [key_label, value_label]


## Class/script display name for an object-typed constraint side.
static func _object_type_label(cls_name: StringName, script: Variant) -> String:
	var cls := String(cls_name)
	if script is Script and not String((script as Script).get_global_name()).is_empty():
		cls = String((script as Script).get_global_name())
	return cls if not cls.is_empty() else "Object"


func get_node_properties(params: Dictionary) -> Dictionary:
	var resolved := _resolve_node(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var scene_root: Node = resolved.scene_root

	# Optional token-reducing filter: `fields` restricts the response to a
	# named subset. Defaults off (empty), so existing callers see the full
	# dump unchanged. The MCP tool types this as a list, but batch_execute and
	# raw callers bypass that, so validate the shape here before iterating.
	var fields_param: Variant = params.get("fields", [])
	if fields_param == null:
		fields_param = []
	if not (fields_param is Array):
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"'fields' must be an array of property names, got %s (%s)" % [
				type_string(typeof(fields_param)), str(fields_param),
			],
		)
	var field_filter := {}
	for f in fields_param:
		## Property names are strings on the wire; anything else is a
		## malformed filter (e.g. [123] or [["fov"]]) — reject rather than
		## silently stringify into a filter that matches nothing (#123/#126:
		## strict within the accepted shape). StringName is allowed for
		## editor-side callers.
		if not (f is String or f is StringName):
			return ErrorCodes.make(
				ErrorCodes.INVALID_PARAMS,
				"'fields' elements must be property-name strings, got %s in %s" % [
					type_string(typeof(f)), str(fields_param),
				],
			)
		field_filter[str(f)] = true
	var use_field_filter := not field_filter.is_empty()

	var properties: Array[Dictionary] = []
	var editor_property_count := 0
	for prop in node.get_property_list():
		var usage: int = prop.get("usage", 0)
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		editor_property_count += 1
		if use_field_filter and not field_filter.has(prop.name):
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
			# Total editor-visible properties before field filtering, so a
			# caller that passed `fields` knows how many were withheld.
			"total_count": editor_property_count,
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
			"path": McpScenePath.from_node(child, scene_root),
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
## on success, or an error dict (has "error" key) on failure. Thin wrapper
## around the shared `McpNodeValidator.resolve_or_error` helper (audit-v2 #20).
func _resolve_node(params: Dictionary) -> Dictionary:
	return McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", ""),
	)


## Reject operations targeting the scene root. Returns an INVALID_PARAMS error
## dict with "Cannot <op> the scene root", or null if `node` is not the root.
static func _reject_if_scene_root(node: Node, scene_root: Node, op: String) -> Variant:
	if node == scene_root:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Cannot %s the scene root" % op)
	return null


## Convert a Godot Variant to a JSON-safe value. Compound geometry types
## (AABB, Rect2, Transforms, …) and packed arrays serialize as structured
## dicts/arrays so agents can inspect fields instead of parsing Godot's
## debug repr — see issue #214.
static func _serialize_value(value: Variant) -> Variant:
	return VariantSerializer.serialize(value)
