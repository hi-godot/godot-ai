@tool
extends RefCounted

## Handles Camera2D / Camera3D authoring — create, configure, bounds, damping,
## node-parent-based follow, presets.
##
## All writes are bundled into a single EditorUndoRedoManager action.
## Setting current=true auto-unmarks previously-current cameras of the same
## class in the same action so one Ctrl-Z reverts the switch.

const CameraValues := preload("res://addons/godot_ai/handlers/camera_values.gd")
const CameraPresets := preload("res://addons/godot_ai/handlers/camera_presets.gd")

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
const _CURRENT_SETTLE_ATTEMPTS := 3
const _CURRENT_SETTLE_DELAY_MSEC := 2


var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# Camera2D doesn't expose `current` as a settable property in Godot 4 —
# only is_current() / make_current() / clear_current(). Camera3D exposes
# both, but using methods uniformly avoids per-class branching.
static func _is_current(cam: Node) -> bool:
	if cam == null:
		return false
	return bool(cam.is_current())


# Register a current=true switch on `node` in the open undo action,
# unmarking previously-current siblings of the same class so a single
# Ctrl-Z reverts the whole switch.
#
# Both DO and UNDO route through `_apply_make_current` / `_apply_clear_current`
# on the handler itself rather than calling Camera.make_current() directly.
# The helpers do the make_current (or clear_current) call plus bounded sync
# settling when the viewport hasn't yet reflected the change — macOS headless
# occasionally reports `is_current() == false` immediately after a committed
# make_current (observed CI run 24682342469) and symmetrically still reports
# the displaced camera as current immediately after an undo (observed CI runs
# 24682342469, 24692250322, 24696571517, 25079965242 — tracked in #140).
#
# Because those callables bind to `self` (a RefCounted handler, not a scene
# node), every action that calls this helper must pin its history via
# `create_action(name, MERGE_DISABLE, scene_root)` — otherwise the
# handler-bound ops land in GLOBAL_HISTORY while the scene-node ops land in
# the scene's history, and a single editor_undo reverts only half the action.
#
# Both DO and UNDO use a single make_current() call — never a
# clear_current() + make_current() pair. make_current() takes over the
# viewport slot atomically (Godot enforces one current camera per class
# per viewport), so the displaced camera naturally returns
# is_current() == false without an explicit clear. The two-step approach
# leaves the viewport temporarily with no current camera between the
# clear and the make, which races with editor cleanup on macOS headless
# (observed flaking CI runs 24674252085, 24675424785).
func _add_make_current_to_action(node: Node, type_str: String, scene_root: Node) -> void:
	var prev_current: Node = null
	for cam in _list_cameras_in_scene(scene_root, type_str):
		if cam == node:
			continue
		if _is_current(cam):
			prev_current = cam
			break
	_undo_redo.add_do_method(self, "_apply_make_current", node)
	if prev_current != null:
		_undo_redo.add_undo_method(self, "_apply_make_current", prev_current)
	else:
		_undo_redo.add_undo_method(self, "_apply_clear_current", node)


# Apply make_current on `cam` with bounded synchronous settling. Registered as the
# do/undo callable by `_add_make_current_to_action`. See that function's
# comment for why the undo path needs the retry inside the action itself.
# Safe against a freed camera node — short-circuits if the node is gone
# or not in the tree.
func _apply_make_current(cam: Node) -> void:
	if cam == null or not is_instance_valid(cam) or not cam.is_inside_tree():
		return
	for attempt in range(_CURRENT_SETTLE_ATTEMPTS):
		cam.make_current()
		_force_camera_refresh(cam)
		if _is_current(cam):
			return
		_displace_stale_camera_2d(cam)
		if _is_current(cam):
			return
		if attempt < _CURRENT_SETTLE_ATTEMPTS - 1:
			OS.delay_msec(_CURRENT_SETTLE_DELAY_MSEC)


# Call after commit_action() whenever the action registered a make_current DO.
# The undo path cannot use a post-undo hook, so it relies on `_apply_make_current`
# directly; create/configure/apply_preset get this extra post-commit verifier.
func _verify_current_after_commit(node: Node) -> void:
	_apply_make_current(node)


func _force_camera_refresh(cam: Node) -> void:
	if cam is Camera2D:
		(cam as Camera2D).force_update_scroll()


func _displace_stale_camera_2d(target: Node) -> void:
	if not (target is Camera2D):
		return
	var viewport := target.get_viewport()
	if viewport == null:
		return
	var stale := viewport.get_camera_2d()
	if stale == null or stale == target or not is_instance_valid(stale):
		return
	var was_enabled := stale.enabled
	if was_enabled:
		stale.enabled = false
	target.make_current()
	_force_camera_refresh(target)
	if was_enabled:
		stale.enabled = true


# Symmetric counterpart to `_apply_make_current` for the "no previous
# current camera" branch (create_camera with make_current=true and no
# sibling was current). clear_current errors in Godot if called on a
# non-current camera, so guard on is_current first.
func _apply_clear_current(cam: Node) -> void:
	if cam == null or not is_instance_valid(cam) or not cam.is_inside_tree():
		return
	if _is_current(cam):
		cam.clear_current()


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
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, McpScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_camera(type_str)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate camera")
	if not node_name.is_empty():
		node.name = node_name

	_undo_redo.create_action(
		"MCP: Create %s '%s'" % [_VALID_TYPES[type_str], node.name],
		UndoRedo.MERGE_DISABLE, scene_root
	)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	if make_current:
		# Must land AFTER add_child: making current before the node is in the
		# tree is a silent no-op on the viewport.
		_add_make_current_to_action(node, type_str, scene_root)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()
	if make_current:
		_verify_current_after_commit(node)

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"name": String(node.name),
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"current": bool(make_current),
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
	var prop_types := _property_type_map(node)
	var coerced: Dictionary = {}
	var old_values: Dictionary = {}
	# `current` is special-cased via methods (Camera2D doesn't expose it as a property).
	var current_request: Variant = null

	for property in properties:
		var prop_name: String = String(property)
		if not (prop_name in valid_keys):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not valid for %s. Valid: %s" % [
					prop_name, _VALID_TYPES[type_str], ", ".join(valid_keys)
				]
			)
		if prop_name == "current":
			current_request = bool(properties[prop_name])
			continue
		var prop_type: int = prop_types.get(prop_name, TYPE_NIL)
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

	_undo_redo.create_action(
		"MCP: Configure camera %s" % node.name,
		UndoRedo.MERGE_DISABLE, scene_root
	)
	for prop_name in coerced:
		_undo_redo.add_do_property(node, prop_name, coerced[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	var verify_current_after := false
	if current_request != null:
		var want_on: bool = bool(current_request)
		var was_on: bool = _is_current(node)
		if want_on and not was_on:
			_add_make_current_to_action(node, type_str, scene_root)
			verify_current_after = true
		elif not want_on and was_on:
			_undo_redo.add_do_method(self, "_apply_clear_current", node)
			_undo_redo.add_undo_method(self, "_apply_make_current", node)
	_undo_redo.commit_action()
	if verify_current_after:
		_verify_current_after_commit(node)

	var applied: Array[String] = []
	var serialized: Dictionary = {}
	for prop_name in coerced:
		applied.append(prop_name)
		serialized[prop_name] = CameraValues.serialize(coerced[prop_name])
	if current_request != null:
		applied.append("current")
		serialized["current"] = bool(current_request)

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
		var v = params.get(edge)
		if v != null:
			var prop_name: String = edges[edge]
			applied[prop_name] = int(v)
			old_values[prop_name] = node.get(prop_name)

	var smoothed = params.get("smoothed")
	if smoothed != null:
		applied["limit_smoothed"] = bool(smoothed)
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
	var pos_v = params.get("position_speed")
	if pos_v != null:
		var pos_speed := float(pos_v)
		var pos_enable := pos_speed > 0.0
		applied["position_smoothing_enabled"] = pos_enable
		old_values["position_smoothing_enabled"] = node.get("position_smoothing_enabled")
		if pos_enable:
			applied["position_smoothing_speed"] = pos_speed
			old_values["position_smoothing_speed"] = node.get("position_smoothing_speed")

	# rotation_speed: same pattern for rotation_smoothing_*.
	var rot_v = params.get("rotation_speed")
	if rot_v != null:
		var rot_speed := float(rot_v)
		var rot_enable := rot_speed > 0.0
		applied["rotation_smoothing_enabled"] = rot_enable
		old_values["rotation_smoothing_enabled"] = node.get("rotation_smoothing_enabled")
		if rot_enable:
			applied["rotation_smoothing_speed"] = rot_speed
			old_values["rotation_smoothing_speed"] = node.get("rotation_smoothing_speed")

	for flag in ["drag_horizontal_enabled", "drag_vertical_enabled"]:
		var flag_v = params.get(flag)
		if flag_v != null:
			applied[flag] = bool(flag_v)
			old_values[flag] = node.get(flag)

	# drag_margins: dict {left, top, right, bottom} floats in [0,1]; null/missing keys untouched.
	var margins_v = params.get("drag_margins")
	if margins_v != null:
		if not (margins_v is Dictionary):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"drag_margins must be a dict with optional keys left/top/right/bottom"
			)
		var margins: Dictionary = margins_v
		for edge in _DAMPING_MARGIN_KEYS:
			var margin_v = margins.get(edge)
			if margin_v == null:
				continue
			var v := float(margin_v)
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
	var target := McpScenePath.resolve(target_path, scene_root)
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
			"path": McpScenePath.from_node(node, scene_root),
			"target_path": McpScenePath.from_node(target, scene_root),
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
			if _is_current(cam):
				node = cam
				resolved_via = "current"
				break
		if node == null and not all_cams.is_empty():
			node = all_cams[0]
			resolved_via = "first"
	else:
		node = McpScenePath.resolve(camera_path, scene_root)
		if node == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, McpScenePath.format_node_error(camera_path, scene_root))
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
	var prop_types := _property_type_map(node)
	var props: Dictionary = {}
	for key in keys:
		if key == "current":
			props[key] = _is_current(node)
			continue
		if prop_types.has(key):
			props[key] = CameraValues.serialize(node.get(key))

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"type": type_str,
			"class": node.get_class(),
			"current": _is_current(node),
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
			"path": McpScenePath.from_node(cam, scene_root),
			"class": cam.get_class(),
			"type": _camera_type_str(cam),
			"current": _is_current(cam),
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
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, McpScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_camera(type_str)
	node.name = node_name

	var preset_props: Dictionary = blueprint.get("properties", {})
	var valid_keys: Array = _KEYS_2D if type_str == "2d" else _KEYS_3D
	var prop_types := _property_type_map(node)
	var applied: Array[String] = []
	for prop in preset_props:
		var prop_name := String(prop)
		if not (prop_name in valid_keys):
			continue  # Silently skip preset keys that don't apply to this camera class.
		# `current` lives on methods, not as a writable property on Camera2D —
		# always handled via the make_current path below.
		if prop_name == "current":
			continue
		var prop_type: int = prop_types.get(prop_name, TYPE_NIL)
		if prop_type == TYPE_NIL:
			continue
		var coerce_result := CameraValues.coerce(prop_name, preset_props[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		node.set(prop_name, coerce_result.value)
		applied.append(prop_name)

	_undo_redo.create_action(
		"MCP: Apply camera preset %s" % preset_name,
		UndoRedo.MERGE_DISABLE, scene_root
	)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	if make_current:
		_add_make_current_to_action(node, type_str, scene_root)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()
	if make_current:
		_verify_current_after_commit(node)

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
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
	var node := McpScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, McpScenePath.format_node_error(node_path, scene_root))
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


## Build a name -> property-type dict from the object's property list.
## Single walk of get_property_list() amortizes lookups across a batch of
## properties in configure / apply_preset.
static func _property_type_map(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	if obj == null:
		return out
	for prop in obj.get_property_list():
		out[prop.name] = int(prop.get("type", TYPE_NIL))
	return out
