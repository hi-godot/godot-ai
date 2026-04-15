@tool
extends McpTestSuite

## Tests for UiHandler — Control layout helpers (anchor presets).

var _handler: UiHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "ui"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = UiHandler.new(_undo_redo)


# Create a Control named `TestHudPanel` under the scene root for a single test.
# Returns the path, or empty string if the scene isn't ready.
func _add_control(ctl_name: String = "TestHudPanel") -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ""
	var panel := Panel.new()
	panel.name = ctl_name
	scene_root.add_child(panel)
	panel.owner = scene_root
	return "/" + scene_root.name + "/" + ctl_name


func _remove_control(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := ScenePath.resolve(path, scene_root)
	if node != null:
		node.get_parent().remove_child(node)
		node.queue_free()


# ----- set_anchor_preset: happy path -----

func test_set_anchor_preset_full_rect() -> void:
	var path := _add_control("TestUiFullRect")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "full_rect"})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "full_rect")
	assert_eq(result.data.anchors.left, 0.0)
	assert_eq(result.data.anchors.top, 0.0)
	assert_eq(result.data.anchors.right, 1.0)
	assert_eq(result.data.anchors.bottom, 1.0)
	assert_true(result.data.undoable)
	_remove_control(path)


func test_set_anchor_preset_center() -> void:
	var path := _add_control("TestUiCenter")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "center"})
	assert_has_key(result, "data")
	assert_eq(result.data.anchors.left, 0.5)
	assert_eq(result.data.anchors.top, 0.5)
	assert_eq(result.data.anchors.right, 0.5)
	assert_eq(result.data.anchors.bottom, 0.5)
	_remove_control(path)


func test_set_anchor_preset_top_left_with_margin() -> void:
	var path := _add_control("TestUiTopLeftMargin")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({
		"path": path, "preset": "top_left", "margin": 8
	})
	assert_has_key(result, "data")
	assert_eq(result.data.margin, 8)
	assert_eq(result.data.anchors.left, 0.0)
	assert_eq(result.data.anchors.top, 0.0)
	# offset_left/top should be shifted by the margin
	assert_eq(result.data.offsets.left, 8.0)
	assert_eq(result.data.offsets.top, 8.0)
	_remove_control(path)


func test_set_anchor_preset_accepts_mixed_case() -> void:
	var path := _add_control("TestUiMixedCase")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "Full_Rect"})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "full_rect")
	_remove_control(path)


func test_set_anchor_preset_keep_size_mode() -> void:
	var path := _add_control("TestUiKeepSize")
	if path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	(node as Control).size = Vector2(100, 50)
	var result := _handler.set_anchor_preset({
		"path": path, "preset": "center", "resize_mode": "keep_size"
	})
	assert_has_key(result, "data")
	assert_eq(result.data.resize_mode, "keep_size")
	# With keep_size on PRESET_CENTER, width/height should remain 100/50.
	var size := (node as Control).size
	assert_eq(size.x, 100.0)
	assert_eq(size.y, 50.0)
	_remove_control(path)


# ----- set_anchor_preset: validation errors -----

func test_set_anchor_preset_missing_path() -> void:
	var result := _handler.set_anchor_preset({"preset": "full_rect"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_anchor_preset_missing_preset() -> void:
	var path := _add_control("TestUiMissingPreset")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({"path": path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_control(path)


func test_set_anchor_preset_unknown_preset() -> void:
	var path := _add_control("TestUiUnknownPreset")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "not_a_preset"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	# Error message should list valid options so the agent can recover.
	assert_contains(result.error.message, "full_rect")
	_remove_control(path)


func test_set_anchor_preset_unknown_resize_mode() -> void:
	var path := _add_control("TestUiUnknownResize")
	if path.is_empty():
		return
	var result := _handler.set_anchor_preset({
		"path": path, "preset": "center", "resize_mode": "stretch"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_control(path)


func test_set_anchor_preset_unknown_node() -> void:
	var result := _handler.set_anchor_preset({
		"path": "/DoesNotExist", "preset": "full_rect"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_anchor_preset_non_control_node() -> void:
	# Scene root in the test project is a Node3D, not a Control.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var result := _handler.set_anchor_preset({
		"path": "/" + scene_root.name, "preset": "full_rect"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not a Control")


# ----- undo -----

func test_set_anchor_preset_is_undoable() -> void:
	var path := _add_control("TestUiUndo")
	if path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var ctl := ScenePath.resolve(path, scene_root) as Control
	var before_left := ctl.anchor_left
	var before_right := ctl.anchor_right
	_handler.set_anchor_preset({"path": path, "preset": "full_rect"})
	assert_eq(ctl.anchor_right, 1.0, "Apply should change anchor_right")
	_undo_redo.undo()
	assert_eq(ctl.anchor_left, before_left, "Undo should restore anchor_left")
	assert_eq(ctl.anchor_right, before_right, "Undo should restore anchor_right")
	_remove_control(path)


# ============================================================================
# build_layout — declarative UI tree composer
# ============================================================================


func test_build_layout_creates_simple_tree() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var spec := {
		"type": "Panel",
		"name": "TestBuildSimple",
		"children": [
			{"type": "Label", "name": "Title", "properties": {"text": "Hello"}},
			{"type": "Button", "name": "Go", "properties": {"text": "Go"}},
		],
	}
	var result := _handler.build_layout({"tree": spec})
	assert_has_key(result, "data")
	assert_eq(result.data.node_count, 3)
	var root := ScenePath.resolve(result.data.root_path, scene_root)
	assert_true(root != null)
	assert_true(root is Panel)
	assert_eq(root.get_child_count(), 2)
	var label: Label = root.get_node("Title")
	assert_eq(label.text, "Hello")

	# Clean up.
	root.get_parent().remove_child(root)
	root.queue_free()


func test_build_layout_rejects_unknown_type() -> void:
	var result := _handler.build_layout({"tree": {"type": "NotARealClass"}})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_rejects_non_node_type() -> void:
	# Resource is not a Node.
	var result := _handler.build_layout({"tree": {"type": "Resource"}})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_rejects_missing_type() -> void:
	var result := _handler.build_layout({"tree": {"name": "NoType"}})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_rejects_unknown_property() -> void:
	# Label has no "bogus_prop".
	var result := _handler.build_layout({
		"tree": {"type": "Label", "properties": {"bogus_prop": 1}}
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_rejects_bad_parent_path() -> void:
	var result := _handler.build_layout({
		"tree": {"type": "Panel"}, "parent_path": "/Nowhere/Nope"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_applies_anchor_preset_and_coerces_color() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var spec := {
		"type": "ColorRect",
		"name": "TestBuildColor",
		"anchor_preset": "full_rect",
		"properties": {"color": "#112233"},
	}
	var result := _handler.build_layout({"tree": spec})
	assert_has_key(result, "data")
	var node: ColorRect = ScenePath.resolve(result.data.root_path, scene_root)
	assert_true(node != null)
	assert_eq(node.anchor_right, 1.0, "anchor_preset=full_rect should set anchor_right=1")
	# Color coerced from hex — "#112233" -> r~=0.067, g~=0.133, b~=0.2
	assert_true(abs(node.color.r - 0.067) < 0.05)

	node.get_parent().remove_child(node)
	node.queue_free()


func test_build_layout_rejects_anchor_preset_on_non_control() -> void:
	# Node doesn't inherit from Control, so anchor_preset must be rejected.
	var result := _handler.build_layout({
		"tree": {"type": "Node", "anchor_preset": "center"}
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_build_layout_is_undoable() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var before_count := scene_root.get_child_count()
	var result := _handler.build_layout({
		"tree": {"type": "Panel", "name": "TestBuildUndo",
			"children": [{"type": "Label"}, {"type": "Button"}]}
	})
	assert_has_key(result, "data")
	assert_eq(scene_root.get_child_count(), before_count + 1)
	_undo_redo.undo()
	assert_eq(scene_root.get_child_count(), before_count, "Undo should remove the whole built tree")


func test_build_layout_rejects_non_theme_resource() -> void:
	# A .tres that is not a Theme — use a StandardMaterial3D saved to disk.
	var bogus_path := "res://tests/_mcp_test_not_a_theme.tres"
	var mat := StandardMaterial3D.new()
	ResourceSaver.save(mat, bogus_path)
	var result := _handler.build_layout({
		"tree": {"type": "Panel", "theme": bogus_path}
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Theme resource")
	if FileAccess.file_exists(bogus_path):
		DirAccess.remove_absolute(bogus_path)


func test_build_layout_rejects_uncoercible_property() -> void:
	# Label.modulate is a Color — "not a color" must be rejected (not silently passed).
	var result := _handler.build_layout({
		"tree": {"type": "Label", "properties": {"modulate": "not a color!!"}}
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "modulate")
