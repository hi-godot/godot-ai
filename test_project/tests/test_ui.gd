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


# Add a Control under the scene root for a single test. If `ctl` is null,
# creates a Panel; otherwise uses the provided (caller-allocated) instance.
# Returns the scene path, or "" if the scene isn't ready — in which case an
# already-allocated `ctl` is freed so the caller doesn't leak it.
func _add_control(ctl_name: String = "TestHudPanel", ctl: Control = null) -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		if ctl != null:
			ctl.queue_free()
		return ""
	if ctl == null:
		ctl = Panel.new()
	ctl.name = ctl_name
	scene_root.add_child(ctl)
	ctl.owner = scene_root
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
		skip("Scene not ready — _add_control returned empty path")
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
		skip("Scene not ready — _add_control returned empty path")
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
		skip("Scene not ready — _add_control returned empty path")
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
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "Full_Rect"})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "full_rect")
	_remove_control(path)


func test_set_anchor_preset_keep_size_mode() -> void:
	var path := _add_control("TestUiKeepSize")
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
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
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_anchor_preset({"path": path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_control(path)


func test_set_anchor_preset_unknown_preset() -> void:
	var path := _add_control("TestUiUnknownPreset")
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_anchor_preset({"path": path, "preset": "not_a_preset"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	# Error message should list valid options so the agent can recover.
	assert_contains(result.error.message, "full_rect")
	_remove_control(path)


func test_set_anchor_preset_unknown_resize_mode() -> void:
	var path := _add_control("TestUiUnknownResize")
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
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
		skip("No scene root — is a scene open?")
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
		skip("Scene not ready — _add_control returned empty path")
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
# set_text — set `text` on any text-bearing Control
# ============================================================================


func test_set_text_on_label() -> void:
	var path := _add_control("TestSetTextLabel", Label.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": "Hello"})
	assert_has_key(result, "data")
	assert_eq(result.data.text, "Hello")
	assert_eq(result.data.old_text, "")
	assert_eq(result.data.node_type, "Label")
	assert_true(result.data.undoable)
	# Verify the live node was actually updated.
	var scene_root := EditorInterface.get_edited_scene_root()
	var label := ScenePath.resolve(path, scene_root) as Label
	assert_eq(label.text, "Hello")
	_remove_control(path)


func test_set_text_on_button() -> void:
	var path := _add_control("TestSetTextButton", Button.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": "Go"})
	assert_has_key(result, "data")
	assert_eq(result.data.text, "Go")
	assert_eq(result.data.node_type, "Button")
	_remove_control(path)


func test_set_text_on_line_edit() -> void:
	# LineEdit covers the interactive-input side of the duck-type path.
	var path := _add_control("TestSetTextLineEdit", LineEdit.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": "input"})
	assert_has_key(result, "data")
	assert_eq(result.data.text, "input")
	assert_eq(result.data.node_type, "LineEdit")
	_remove_control(path)


func test_set_text_replaces_existing_text() -> void:
	var label := Label.new()
	label.text = "old"
	var path := _add_control("TestSetTextReplace", label)
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": "new"})
	assert_has_key(result, "data")
	assert_eq(result.data.text, "new")
	assert_eq(result.data.old_text, "old")
	_remove_control(path)


func test_set_text_missing_path() -> void:
	var result := _handler.set_text({"text": "hi"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_text_missing_text() -> void:
	var path := _add_control("TestSetTextMissingText", Label.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "text")
	_remove_control(path)


func test_set_text_rejects_non_string_value() -> void:
	var path := _add_control("TestSetTextBadType", Label.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": 42})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_control(path)


func test_set_text_unknown_node() -> void:
	var result := _handler.set_text({"path": "/DoesNotExist", "text": "x"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_text_non_control_node() -> void:
	# Scene root in the test project is a Node3D, not a Control.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.set_text({
		"path": "/" + scene_root.name, "text": "x"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not a Control")


func test_set_text_control_without_text_property() -> void:
	# Panel is a Control but has no `text` property — should give a clear error,
	# not silently no-op or crash.
	var path := _add_control("TestSetTextNoTextProp", Panel.new())
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	var result := _handler.set_text({"path": path, "text": "x"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "text")
	_remove_control(path)


func test_set_text_is_undoable() -> void:
	var label := Label.new()
	label.text = "before"
	var path := _add_control("TestSetTextUndo", label)
	if path.is_empty():
		skip("Scene not ready — _add_control returned empty path")
		return
	_handler.set_text({"path": path, "text": "after"})
	assert_eq(label.text, "after", "Apply should change text")
	_undo_redo.undo()
	assert_eq(label.text, "before", "Undo should restore prior text")
	_remove_control(path)


# ============================================================================
# build_layout — declarative UI tree composer
# ============================================================================


func test_build_layout_creates_simple_tree() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
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
		skip("No scene root — is a scene open?")
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
		skip("No scene root — is a scene open?")
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


# ============================================================================
# Friction fix: theme_override_* properties in build_layout
# ============================================================================

func test_build_layout_theme_override_color() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.build_layout({
		"tree": {
			"type": "Label",
			"name": "TestOverrideColor",
			"properties": {
				"text": "Red text",
				"theme_override_colors/font_color": "#ff0000",
			},
		},
	})
	assert_has_key(result, "data")
	var label: Label = scene_root.find_child("TestOverrideColor", true, false)
	assert_true(label != null, "Label should exist")
	assert_true(label.has_theme_color_override("font_color"), "Color override should be set")
	# Read back via the *_override getter (not the fallback get_theme_color)
	# so we're asserting on the stored Variant, not on any theme fallback path.
	var stored: Color = label.get_theme_color_override("font_color")
	assert_eq(stored.r, 1.0)
	assert_eq(stored.g, 0.0)
	assert_eq(stored.b, 0.0)
	# Cleanup.
	label.get_parent().remove_child(label)
	label.queue_free()


func test_build_layout_theme_override_constant() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.build_layout({
		"tree": {
			"type": "VBoxContainer",
			"name": "TestOverrideConst",
			"properties": {
				"theme_override_constants/separation": 20,
			},
		},
	})
	assert_has_key(result, "data")
	var vbox := scene_root.find_child("TestOverrideConst", true, false) as VBoxContainer
	assert_true(vbox != null, "VBoxContainer should exist")
	assert_true(vbox.has_theme_constant_override("separation"), "Constant override should be set")
	# Read back via *_override getter — asserts the stored int, not a fallback.
	assert_eq(vbox.get_theme_constant_override("separation"), 20)
	vbox.get_parent().remove_child(vbox)
	vbox.queue_free()


func test_build_layout_theme_override_font_size() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.build_layout({
		"tree": {
			"type": "Label",
			"name": "TestOverrideFontSize",
			"properties": {
				"text": "Big",
				"theme_override_font_sizes/font_size": 32,
			},
		},
	})
	assert_has_key(result, "data")
	var label := scene_root.find_child("TestOverrideFontSize", true, false) as Label
	assert_true(label != null, "Label should exist")
	assert_true(label.has_theme_font_size_override("font_size"), "Font size override should be set")
	# Read back via *_override getter.
	assert_eq(label.get_theme_font_size_override("font_size"), 32)
	label.get_parent().remove_child(label)
	label.queue_free()


func test_build_layout_theme_override_stylebox() -> void:
	# theme_override_styles/ accepts a res:// path to a StyleBox resource.
	# Previously untested — verifies that load + add_theme_stylebox_override
	# actually install the resource.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	# Create a throwaway StyleBoxFlat on disk.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.2, 0.3, 1.0)
	var sb_path := "res://tests/_mcp_test_override_stylebox.tres"
	ResourceSaver.save(sb, sb_path)

	var result := _handler.build_layout({
		"tree": {
			"type": "Panel",
			"name": "TestOverrideStyle",
			"properties": {
				"theme_override_styles/panel": sb_path,
			},
		},
	})
	assert_has_key(result, "data")
	var panel := scene_root.find_child("TestOverrideStyle", true, false) as Panel
	assert_true(panel != null, "Panel should exist")
	assert_true(panel.has_theme_stylebox_override("panel"), "Stylebox override should be set")
	var stored: StyleBox = panel.get_theme_stylebox_override("panel")
	assert_true(stored is StyleBoxFlat, "Stored override is a StyleBoxFlat")
	assert_eq((stored as StyleBoxFlat).bg_color, Color(0.1, 0.2, 0.3, 1.0))
	# Cleanup.
	panel.get_parent().remove_child(panel)
	panel.queue_free()
	DirAccess.remove_absolute(sb_path)


func test_build_layout_theme_override_rejects_non_control() -> void:
	var result := _handler.build_layout({
		"tree": {
			"type": "Node3D",
			"properties": {"theme_override_colors/font_color": "#ff0000"},
		},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "theme_override_")
