@tool
class_name CameraHandler
extends RefCounted

## Handles Camera2D / Camera3D authoring — create, configure, bounds, damping,
## node-parent-based follow, presets.
##
## All writes are bundled into a single EditorUndoRedoManager action.
## Setting current=true auto-unmarks previously-current cameras of the same
## class in the same action so one Ctrl-Z reverts the switch.


const _VALID_TYPES := {
	"2d": "Camera2D",
	"3d": "Camera3D",
}

const _KEYS_2D := [
	"zoom",
	"offset",
	"anchor_mode",
	"ignore_rotation",
	"enabled",
	"current",
	"process_callback",
	"position_smoothing_enabled",
	"position_smoothing_speed",
	"rotation_smoothing_enabled",
	"rotation_smoothing_speed",
	"drag_horizontal_enabled",
	"drag_vertical_enabled",
	"drag_horizontal_offset",
	"drag_vertical_offset",
	"drag_left_margin",
	"drag_top_margin",
	"drag_right_margin",
	"drag_bottom_margin",
	"limit_left",
	"limit_right",
	"limit_top",
	"limit_bottom",
	"limit_smoothed",
]

const _KEYS_3D := [
	"fov",
	"near",
	"far",
	"size",
	"projection",
	"keep_aspect",
	"cull_mask",
	"doppler_tracking",
	"h_offset",
	"v_offset",
	"current",
]

const _DAMPING_MARGIN_KEYS := ["left", "top", "right", "bottom"]


var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# camera_create
# ============================================================================

func create_camera(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "Camera")
	var type_str: String = params.get("type", "2d")
	var make_current: bool = bool(params.get("make_current", false))

	if not _VALID_TYPES.has(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid camera type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var pre_existing := _list_cameras_in_scene(scene_root, type_str)
	var is_first_camera := pre_existing.is_empty()

	var node := _instantiate_camera(type_str)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate camera")
	if not node_name.is_empty():
		node.name = node_name

	_undo_redo.create_action("MCP: Create %s '%s'" % [_VALID_TYPES[type_str], node.name])
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	if make_current:
		# Unmark any previously-current siblings of the same class.
		for cam in pre_existing:
			if cam.current:
				_undo_redo.add_do_property(cam, "current", false)
				_undo_redo.add_undo_property(cam, "current", true)
		# Must land AFTER add_child: setting current=true before the node is
		# in the tree is a silent no-op on the viewport.
		_undo_redo.add_do_property(node, "current", true)
		_undo_redo.add_undo_property(node, "current", false)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
			"name": String(node.name),
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"current": bool(make_current),
			"is_first_camera": is_first_camera,
			"undoable": true,
		}
	}


# ============================================================================
# camera_configure
# ============================================================================

func configure(params: Dictionary) -> Dictionary:
	var resolved := _resolve_camera(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var type_str: String = resolved.type
	var scene_root: Node = resolved.scene_root

	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "properties dict is empty")

	var valid_keys: Array = _KEYS_2D if type_str == "2d" else _KEYS_3D
	var coerced: Dictionary = {}
	var old_values: Dictionary = {}

	for property in properties:
		var prop_name: String = String(property)
		if not (prop_name in valid_keys):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not valid for %s. Valid: %s" % [
					prop_name, _VALID_TYPES[type_str], ", ".join(valid_keys)
				]
			)
		var prop_type := _object_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not present on %s" % [prop_name, node.get_class()]
			)
		var coerce_result := CameraValues.coerce(prop_name, properties[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		coerced[prop_name] = coerce_result.value
		old_values[prop_name] = node.get(prop_name)

	_undo_redo.create_action("MCP: Configure camera %s" % node.name)
	for prop_name in coerced:
		_undo_redo.add_do_property(node, prop_name, coerced[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	# If current is being turned on, unmark previously-current siblings in the same action.
	if coerced.has("current") and bool(coerced["current"]) and not bool(old_values.get("current", false)):
		for cam in _list_cameras_in_scene(scene_root, type_str):
			if cam == node:
				continue
			if cam.current:
				_undo_redo.add_do_property(cam, "current", false)
				_undo_redo.add_undo_property(cam, "current", true)
	_undo_redo.commit_action()

	var applied: Array[String] = []
	var serialized: Dictionary = {}
	for prop_name in coerced:
		applied.append(prop_name)
		serialized[prop_name] = CameraValues.serialize(coerced[prop_name])

	return {
		"data": {
			"path": node_path,
			"type": type_str,
			"class": node.get_class(),
			"applied": applied,
			"values": serialized,
			"undoable": true,
		}
	}


# ============================================================================
# camera_set_limits_2d
# ============================================================================

func set_limits_2d(params: Dictionary) -> Dictionary:
	var resolved := _resolve_camera(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var type_str: String = resolved.type

	if type_str != "2d":
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"camera_set_limits_2d requires a Camera2D (got %s)" % node.get_class()
		)

	var applied: Dictionary = {}
	var old_values: Dictionary = {}
	var edges := {
		"left": "limit_left",
		"right": "limit_right",
		"top": "limit_top",
		"bottom": "limit_bottom",
	}
	for edge in edges:
		if params.has(edge) and params[edge] != null:
			var prop_name: String = edges[edge]
			applied[prop_name] = int(params[edge])
			old_values[prop_name] = node.get(prop_name)

	if params.has("smoothed") and params["smoothed"] != null:
		applied["limit_smoothed"] = bool(params["smoothed"])
		old_values["limit_smoothed"] = node.get("limit_smoothed")

	if applied.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"No limits specified; provide at least one of left, right, top, bottom, smoothed"
		)

	_undo_redo.create_action("MCP: Set camera limits on %s" % node.name)
	for prop_name in applied:
		_undo_redo.add_do_property(node, prop_name, applied[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	_undo_redo.commit_action()

	var values: Dictionary = {}
	for prop_name in applied:
		values[prop_name] = applied[prop_name]

	return {
		"data": {
			"path": node_path,
			"applied": applied.keys(),
			"values": values,
			"undoable": true,
		}
	}


# ============================================================================
# camera_set_damping_2d
# ============================================================================

func set_damping_2d(params: Dictionary) -> Dictionary:
	var resolved := _resolve_camera(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var type_str: String = resolved.type

	if type_str != "2d":
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"camera_set_damping_2d requires a Camera2D (got %s)" % node.get_class()
		)

	var applied: Dictionary = {}
	var old_values: Dictionary = {}

	# position_speed: set position_smoothing_speed AND toggle position_smoothing_enabled.
	if params.has("position_speed") and params["position_speed"] != null:
		var pos_speed := float(params["position_speed"])
		var pos_enable := pos_speed > 0.0
		applied["position_smoothing_enabled"] = pos_enable
		old_values["position_smoothing_enabled"] = node.get("position_smoothing_enabled")
		if pos_enable:
			applied["position_smoothing_speed"] = pos_speed
			old_values["position_smoothing_speed"] = node.get("position_smoothing_speed")

	# rotation_speed: same pattern for rotation_smoothing_*.
	if params.has("rotation_speed") and params["rotation_speed"] != null:
		var rot_speed := float(params["rotation_speed"])
		var rot_enable := rot_speed > 0.0
		applied["rotation_smoothing_enabled"] = rot_enable
		old_values["rotation_smoothing_enabled"] = node.get("rotation_smoothing_enabled")
		if rot_enable:
			applied["rotation_smoothing_speed"] = rot_speed
			old_values["rotation_smoothing_speed"] = node.get("rotation_smoothing_speed")

	# drag_horizontal_enabled / drag_vertical_enabled.
	for flag in ["drag_horizontal_enabled", "drag_vertical_enabled"]:
		if params.has(flag) and params[flag] != null:
			applied[flag] = bool(params[flag])
			old_values[flag] = node.get(flag)

	# drag_margins: dict {left, top, right, bottom} floats in [0,1]; null/missing keys untouched.
	if params.has("drag_margins") and params["drag_margins"] != null:
		var margins_v = params["drag_margins"]
		if not (margins_v is Dictionary):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"drag_margins must be a dict with optional keys left/top/right/bottom"
			)
		var margins: Dictionary = margins_v
		for edge in _DAMPING_MARGIN_KEYS:
			if not margins.has(edge) or margins[edge] == null:
				continue
			var v := float(margins[edge])
			if v < 0.0 or v > 1.0:
				return McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"drag_margins.%s must be in [0, 1] (got %s)" % [edge, v]
				)
			var prop_name: String = "drag_%s_margin" % edge
			applied[prop_name] = v
			old_values[prop_name] = node.get(prop_name)

	if applied.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"No damping params specified; provide at least one of position_speed, rotation_speed, drag_margins, drag_horizontal_enabled, drag_vertical_enabled"
		)

	_undo_redo.create_action("MCP: Set camera damping on %s" % node.name)
	for prop_name in applied:
		_undo_redo.add_do_property(node, prop_name, applied[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"applied": applied.keys(),
			"values": applied,
			"undoable": true,
		}
	}


# ============================================================================
# camera_follow_2d
# ============================================================================

func follow_2d(params: Dictionary) -> Dictionary:
	var resolved := _resolve_camera(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var type_str: String = resolved.type
	var scene_root: Node = resolved.scene_root

	if type_str != "2d":
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"camera_follow_2d requires a Camera2D (got %s)" % node.get_class()
		)

	var target_path: String = params.get("target_path", "")
	if target_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: target_path")
	var target := ScenePath.resolve(target_path, scene_root)
	if target == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Target not found: %s" % target_path)
	if not (target is Node2D) and target != scene_root:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Follow target must be a Node2D (got %s)" % target.get_class()
		)
	if target == node:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Camera cannot follow itself")
	if target.is_ancestor_of(node) and node.get_parent() != target:
		# A non-parent ancestor — still valid to reparent under (direct parent).
		pass
	if node.is_ancestor_of(target):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Cannot follow a descendant of the camera"
		)

	var smoothing_speed := float(params.get("smoothing_speed", 5.0))
	var zero_transform: bool = bool(params.get("zero_transform", true))

	var old_parent := node.get_parent()
	var old_idx: int = node.get_index() if old_parent != null else 0
	var old_position = node.get("position")
	var old_rotation = node.get("rotation")
	var old_smoothing_enabled: bool = bool(node.get("position_smoothing_enabled"))
	var old_smoothing_speed: float = float(node.get("position_smoothing_speed"))

	var already_child: bool = old_parent == target
	var reparented: bool = not already_child

	_undo_redo.create_action("MCP: Camera follow %s" % target.name)
	if reparented:
		_undo_redo.add_do_method(old_parent, "remove_child", node)
		_undo_redo.add_do_method(target, "add_child", node, true)
		_undo_redo.add_do_method(node, "set_owner", scene_root)
		_undo_redo.add_do_reference(node)
	if zero_transform:
		if target is Node2D:
			_undo_redo.add_do_property(node, "position", Vector2.ZERO)
			_undo_redo.add_undo_property(node, "position", old_position)
			_undo_redo.add_do_property(node, "rotation", 0.0)
			_undo_redo.add_undo_property(node, "rotation", old_rotation)
	_undo_redo.add_do_property(node, "position_smoothing_enabled", true)
	_undo_redo.add_undo_property(node, "position_smoothing_enabled", old_smoothing_enabled)
	if smoothing_speed > 0.0:
		_undo_redo.add_do_property(node, "position_smoothing_speed", smoothing_speed)
		_undo_redo.add_undo_property(node, "position_smoothing_speed", old_smoothing_speed)
	if reparented:
		_undo_redo.add_undo_method(target, "remove_child", node)
		_undo_redo.add_undo_method(old_parent, "add_child", node, true)
		_undo_redo.add_undo_method(old_parent, "move_child", node, old_idx)
		_undo_redo.add_undo_method(node, "set_owner", scene_root)
		_undo_redo.add_undo_reference(node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"target_path": ScenePath.from_node(target, scene_root),
			"reparented": reparented,
			"smoothing_speed": smoothing_speed,
			"zero_transform": zero_transform and (target is Node2D),
			"undoable": true,
		}
	}


# ============================================================================
# camera_get
# ============================================================================

func get_camera(params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var camera_path: String = params.get("camera_path", "")
	var node: Node = null
	var resolved_via: String = ""
	if camera_path.is_empty():
		# Empty: prefer current camera (2D or 3D, either is fine), else first found.
		var all_cams := _list_cameras_in_scene(scene_root, "")
		for cam in all_cams:
			if cam.current:
				node = cam
				resolved_via = "current"
				break
		if node == null and not all_cams.is_empty():
			node = all_cams[0]
			resolved_via = "first"
	else:
		node = ScenePath.resolve(camera_path, scene_root)
		if node == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % camera_path)
		if not _is_camera(node):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Node %s is not a camera (got %s)" % [camera_path, node.get_class()]
			)
		resolved_via = "path"

	if node == null:
		return {
			"data": {
				"path": "",
				"type": "",
				"class": "",
				"current": false,
				"properties": {},
				"resolved_via": "not_found",
			}
		}

	var type_str := _camera_type_str(node)
	var keys: Array = _KEYS_2D if type_str == "2d" else _KEYS_3D
	var props: Dictionary = {}
	for key in keys:
		if _object_property_type(node, key) != TYPE_NIL:
			props[key] = CameraValues.serialize(node.get(key))

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"type": type_str,
			"class": node.get_class(),
			"current": bool(node.get("current")),
			"properties": props,
			"resolved_via": resolved_via,
		}
	}


# ============================================================================
# camera_list
# ============================================================================

func list_cameras(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var cams := _list_cameras_in_scene(scene_root, "")
	var out: Array[Dictionary] = []
	for cam in cams:
		out.append({
			"path": ScenePath.from_node(cam, scene_root),
			"class": cam.get_class(),
			"type": _camera_type_str(cam),
			"current": bool(cam.get("current")),
		})
	return {"data": {"cameras": out}}


# ============================================================================
# camera_apply_preset
# ============================================================================

func apply_preset(params: Dictionary) -> Dictionary:
	var preset_name: String = params.get("preset", "")
	if preset_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: preset")

	var overrides: Dictionary = params.get("overrides", {})
	var blueprint = CameraPresets.build(preset_name, overrides)
	if blueprint == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(CameraPresets.list_presets())]
		)

	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "")
	var type_str: String = params.get("type", String(blueprint.get("default_type", "2d")))
	var make_current: bool = bool(params.get("make_current", true))
	if node_name.is_empty():
		node_name = preset_name.capitalize()
	if not _VALID_TYPES.has(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid camera type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var pre_existing := _list_cameras_in_scene(scene_root, type_str)
	var node := _instantiate_camera(type_str)
	node.name = node_name

	var preset_props: Dictionary = blueprint.get("properties", {})
	var valid_keys: Array = _KEYS_2D if type_str == "2d" else _KEYS_3D
	var applied: Array[String] = []
	for prop in preset_props:
		var prop_name := String(prop)
		if not (prop_name in valid_keys):
			continue  # Silently skip preset keys that don't apply to this camera class.
		var prop_type := _object_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			continue
		var coerce_result := CameraValues.coerce(prop_name, preset_props[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		node.set(prop_name, coerce_result.value)
		applied.append(prop_name)

	_undo_redo.create_action("MCP: Apply camera preset %s" % preset_name)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	if make_current:
		for cam in pre_existing:
			if cam.current:
				_undo_redo.add_do_property(cam, "current", false)
				_undo_redo.add_undo_property(cam, "current", true)
		_undo_redo.add_do_property(node, "current", true)
		_undo_redo.add_undo_property(node, "current", false)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
			"name": node_name,
			"preset": preset_name,
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"applied": applied,
			"current": bool(make_current),
			"undoable": true,
		}
	}


# ============================================================================
# Helpers
# ============================================================================

static func _instantiate_camera(type_str: String) -> Node:
	match type_str:
		"2d":
			return Camera2D.new()
		"3d":
			return Camera3D.new()
	return null


static func _is_camera(node: Node) -> bool:
	return node is Camera2D or node is Camera3D


static func _camera_type_str(node: Node) -> String:
	if node is Camera2D:
		return "2d"
	if node is Camera3D:
		return "3d"
	return ""


func _resolve_camera(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("camera_path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: camera_path")
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	if not _is_camera(node):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Node %s is not a camera (got %s)" % [node_path, node.get_class()]
		)
	return {
		"node": node,
		"path": node_path,
		"type": _camera_type_str(node),
		"scene_root": scene_root,
	}


## Walk the edited scene for cameras. class_filter: "2d", "3d", or "" for all.
static func _list_cameras_in_scene(scene_root: Node, class_filter: String) -> Array:
	var result: Array = []
	if scene_root == null:
		return result
	_collect_cameras(scene_root, class_filter, result)
	return result


static func _collect_cameras(node: Node, class_filter: String, out: Array) -> void:
	var matches := false
	match class_filter:
		"2d":
			matches = node is Camera2D
		"3d":
			matches = node is Camera3D
		_:
			matches = node is Camera2D or node is Camera3D
	if matches:
		out.append(node)
	for child in node.get_children():
		_collect_cameras(child, class_filter, out)


static func _object_property_type(obj: Object, name: String) -> int:
	if obj == null:
		return TYPE_NIL
	for prop in obj.get_property_list():
		if prop.name == name:
			return int(prop.get("type", TYPE_NIL))
	return TYPE_NIL
