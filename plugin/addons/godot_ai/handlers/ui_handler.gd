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
