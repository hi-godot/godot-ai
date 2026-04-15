@tool
class_name UiHandler
extends RefCounted

## Handles UI-specific (Control) layout helpers: anchor presets, etc.
##
## Anchors/offsets are the worst part of Control layout to set one-property-at-a-time.
## This handler wraps Godot's built-in presets (FULL_RECT, CENTER, TOP_LEFT, ...) so
## callers can set a whole layout with one command, with proper undo.

var _undo_redo: EditorUndoRedoManager


const _PRESETS := {
	"top_left": Control.PRESET_TOP_LEFT,
	"top_right": Control.PRESET_TOP_RIGHT,
	"bottom_left": Control.PRESET_BOTTOM_LEFT,
	"bottom_right": Control.PRESET_BOTTOM_RIGHT,
	"center_left": Control.PRESET_CENTER_LEFT,
	"center_top": Control.PRESET_CENTER_TOP,
	"center_right": Control.PRESET_CENTER_RIGHT,
	"center_bottom": Control.PRESET_CENTER_BOTTOM,
	"center": Control.PRESET_CENTER,
	"left_wide": Control.PRESET_LEFT_WIDE,
	"top_wide": Control.PRESET_TOP_WIDE,
	"right_wide": Control.PRESET_RIGHT_WIDE,
	"bottom_wide": Control.PRESET_BOTTOM_WIDE,
	"vcenter_wide": Control.PRESET_VCENTER_WIDE,
	"hcenter_wide": Control.PRESET_HCENTER_WIDE,
	"full_rect": Control.PRESET_FULL_RECT,
}

const _RESIZE_MODES := {
	"minsize": Control.PRESET_MODE_MINSIZE,
	"keep_width": Control.PRESET_MODE_KEEP_WIDTH,
	"keep_height": Control.PRESET_MODE_KEEP_HEIGHT,
	"keep_size": Control.PRESET_MODE_KEEP_SIZE,
}

const _ANCHOR_OFFSET_PROPS := [
	"anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
	"offset_left", "offset_top", "offset_right", "offset_bottom",
]


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


## Apply a Control layout preset (anchors + offsets) to a UI node.
##
## Params:
##   path        - scene path to a Control node (required)
##   preset      - preset name: full_rect, center, top_left, ... (required)
##   resize_mode - minsize | keep_width | keep_height | keep_size (default: minsize)
##   margin      - integer margin in pixels from the anchor edges (default: 0)
func set_anchor_preset(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	var preset_name: String = str(params.get("preset", "")).to_lower()
	if preset_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: preset")
	if not _PRESETS.has(preset_name):
		var names := _PRESETS.keys()
		names.sort()
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(names)]
		)

	var resize_mode_name: String = str(params.get("resize_mode", "minsize")).to_lower()
	if not _RESIZE_MODES.has(resize_mode_name):
		var names := _RESIZE_MODES.keys()
		names.sort()
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Unknown resize_mode '%s'. Valid: %s" % [resize_mode_name, ", ".join(names)]
		)

	var margin: int = int(params.get("margin", 0))

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	if not node is Control:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Node %s is not a Control (got %s)" % [node_path, node.get_class()]
		)

	var control := node as Control
	var preset_value: int = _PRESETS[preset_name]
	var resize_mode_value: int = _RESIZE_MODES[resize_mode_name]

	# Snapshot before so we can undo every property the preset may have touched.
	var before: Dictionary = {}
	for prop in _ANCHOR_OFFSET_PROPS:
		before[prop] = control.get(prop)

	_undo_redo.create_action("MCP: Set %s anchor preset %s" % [control.name, preset_name])
	_undo_redo.add_do_method(
		control, "set_anchors_and_offsets_preset", preset_value, resize_mode_value, margin
	)
	for prop in _ANCHOR_OFFSET_PROPS:
		_undo_redo.add_undo_property(control, prop, before[prop])
	_undo_redo.commit_action()

	var after: Dictionary = {}
	for prop in _ANCHOR_OFFSET_PROPS:
		after[prop] = control.get(prop)

	return {
		"data": {
			"path": node_path,
			"preset": preset_name,
			"resize_mode": resize_mode_name,
			"margin": margin,
			"anchors": {
				"left": after.anchor_left,
				"top": after.anchor_top,
				"right": after.anchor_right,
				"bottom": after.anchor_bottom,
			},
			"offsets": {
				"left": after.offset_left,
				"top": after.offset_top,
				"right": after.offset_right,
				"bottom": after.offset_bottom,
			},
			"undoable": true,
		}
	}


# ============================================================================
# build_layout — declarative nested-dict → Control tree in one undo action
# ============================================================================

## Build a tree of Control nodes atomically.
##
## Params:
##   tree         - Dictionary describing the root node. Required fields: "type".
##                  Optional: "name", "properties" (dict), "anchor_preset",
##                  "anchor_margin", "theme" (res:// path), "children" (array).
##   parent_path  - Parent scene path. Empty or "/" = scene root.
##
## Validation is done before any scene mutation: class names, property
## existence, and res:// paths are all checked up-front. If anything is
## invalid, no node is created.
func build_layout(params: Dictionary) -> Dictionary:
	var tree = params.get("tree")
	if typeof(tree) != TYPE_DICTIONARY:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: tree (must be a dictionary)")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent_path: String = params.get("parent_path", "")
	var parent: Node = scene_root
	if not parent_path.is_empty() and parent_path != "/":
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Parent not found: %s" % parent_path)

	# Validate + build in memory first; if anything fails, free and bail.
	var built := _build_subtree(tree)
	if built.has("error"):
		return built
	var root_node: Node = built.node
	var created: Array[Node] = built.created

	_undo_redo.create_action("MCP: Build UI layout (%d nodes)" % created.size())
	_undo_redo.add_do_method(parent, "add_child", root_node, true)
	_undo_redo.add_do_method(root_node, "set_owner", scene_root)
	for n in created:
		_undo_redo.add_do_method(n, "set_owner", scene_root)
		_undo_redo.add_do_reference(n)
	_undo_redo.add_undo_method(parent, "remove_child", root_node)
	_undo_redo.commit_action()

	return {
		"data": {
			"root_path": ScenePath.from_node(root_node, scene_root),
			"node_count": created.size(),
			"undoable": true,
		}
	}


## Recursively instantiate + configure a node and its children in memory.
## Returns {"node": root, "created": [all descendants incl. root]} or {"error": ...}.
func _build_subtree(spec: Dictionary) -> Dictionary:
	var node_type: String = spec.get("type", "")
	if node_type.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Every layout node requires a 'type'")
	if not ClassDB.class_exists(node_type):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown type: %s" % node_type)
	if not ClassDB.is_parent_class(node_type, "Node"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "%s is not a Node type" % node_type)

	var node: Node = ClassDB.instantiate(node_type)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % node_type)

	var node_name: String = spec.get("name", "")
	if not node_name.is_empty():
		node.name = node_name

	# Properties.
	if spec.has("properties"):
		var props = spec.get("properties")
		if typeof(props) != TYPE_DICTIONARY:
			node.free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "properties must be a dictionary")
		for key in props:
			var value = props[key]
			var apply_err := _apply_property(node, str(key), value)
			if apply_err != null:
				node.free()
				return apply_err

	# Theme (res:// path -> Resource).
	if spec.has("theme"):
		var theme_path: String = str(spec.get("theme", ""))
		if not theme_path.is_empty():
			if not theme_path.begins_with("res://"):
				node.free()
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "theme must be a res:// path")
			if not ResourceLoader.exists(theme_path):
				node.free()
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Theme not found: %s" % theme_path)
			var theme_res: Resource = ResourceLoader.load(theme_path)
			if theme_res == null or not theme_res is Theme:
				node.free()
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "theme path must point to a Theme resource: %s" % theme_path)
			if not node is Control and not node is Window:
				node.free()
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "theme can only be set on Control / Window (got %s)" % node_type)
			node.theme = theme_res as Theme

	# Anchor preset — applied before children so children inherit sensible anchors.
	if spec.has("anchor_preset"):
		var preset_name: String = str(spec.get("anchor_preset", "")).to_lower()
		if not _PRESETS.has(preset_name):
			node.free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown anchor_preset: %s" % preset_name)
		if not node is Control:
			node.free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "anchor_preset requires a Control (got %s)" % node_type)
		var preset_value: int = _PRESETS[preset_name]
		var margin: int = int(spec.get("anchor_margin", 0))
		(node as Control).set_anchors_and_offsets_preset(preset_value, Control.PRESET_MODE_MINSIZE, margin)

	var created: Array[Node] = [node]
	if spec.has("children"):
		var children = spec.get("children")
		if typeof(children) != TYPE_ARRAY:
			node.free()
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "children must be an array")
		for child_spec in children:
			if typeof(child_spec) != TYPE_DICTIONARY:
				node.free()
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "each child must be a dictionary")
			var child_result := _build_subtree(child_spec)
			if child_result.has("error"):
				node.free()
				return child_result
			var child_node: Node = child_result.node
			node.add_child(child_node)
			for n in child_result.created:
				created.append(n)
	return {"node": node, "created": created}


## Apply a property to a newly-instantiated node. Handles Color/Vector2/NodePath
## coercion from JSON-friendly forms. Returns null on success, error dict on failure.
func _apply_property(node: Node, prop: String, value: Variant) -> Variant:
	var found := false
	var prop_type := TYPE_NIL
	for p in node.get_property_list():
		if p.name == prop:
			found = true
			prop_type = p.get("type", TYPE_NIL)
			break
	if not found:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Property '%s' not found on %s" % [prop, node.get_class()]
		)

	var coercion := _coerce_for_type(value, prop_type)
	if not coercion.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Property '%s' on %s expects type %s (cannot coerce %s)" % [
				prop, node.get_class(), type_string(prop_type), value
			]
		)
	node.set(prop, coercion.value)
	return null


## Coerce a JSON-friendly value to the target Godot type. Returns
## {"ok": true, "value": coerced} on success, {"ok": false} on failure.
## For types we don't explicitly coerce, the value is returned as-is
## (Godot will typecheck at set() time and fail loudly if it disagrees).
static func _coerce_for_type(value: Variant, prop_type: int) -> Dictionary:
	match prop_type:
		TYPE_COLOR:
			if value is Color:
				return {"ok": true, "value": value}
			if value is String:
				var a := Color.from_string(value, Color(0, 0, 0, 0))
				var b := Color.from_string(value, Color(1, 1, 1, 1))
				if a == b:
					return {"ok": true, "value": a}
				return {"ok": false}
			if value is Dictionary and value.has("r") and value.has("g") and value.has("b"):
				return {
					"ok": true,
					"value": Color(float(value.r), float(value.g), float(value.b), float(value.get("a", 1.0))),
				}
			return {"ok": false}
		TYPE_VECTOR2:
			if value is Vector2:
				return {"ok": true, "value": value}
			if value is Dictionary and value.has("x") and value.has("y"):
				return {"ok": true, "value": Vector2(float(value.x), float(value.y))}
			if value is Array and value.size() == 2:
				return {"ok": true, "value": Vector2(float(value[0]), float(value[1]))}
			return {"ok": false}
		TYPE_VECTOR2I:
			if value is Vector2i:
				return {"ok": true, "value": value}
			if value is Dictionary and value.has("x") and value.has("y"):
				return {"ok": true, "value": Vector2i(int(value.x), int(value.y))}
			if value is Array and value.size() == 2:
				return {"ok": true, "value": Vector2i(int(value[0]), int(value[1]))}
			return {"ok": false}
		TYPE_NODE_PATH:
			if value is NodePath:
				return {"ok": true, "value": value}
			if value is String:
				return {"ok": true, "value": NodePath(value)}
			return {"ok": false}
	return {"ok": true, "value": value}
