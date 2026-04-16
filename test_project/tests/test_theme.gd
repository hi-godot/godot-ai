@tool
extends McpTestSuite

## Tests for ThemeHandler — Theme resource authoring.

var _handler: ThemeHandler
var _undo_redo: EditorUndoRedoManager

const TEST_THEME_PATH := "res://tests/_mcp_test_theme.tres"


func suite_name() -> String:
	return "theme"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ThemeHandler.new(_undo_redo)


func suite_teardown() -> void:
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)


func _make_theme() -> void:
	# Ensure the test theme file exists fresh.
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	_handler.create_theme({"path": TEST_THEME_PATH})


# ----- create_theme -----

func test_create_theme_writes_file() -> void:
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	var result := _handler.create_theme({"path": TEST_THEME_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_THEME_PATH)
	assert_true(FileAccess.file_exists(TEST_THEME_PATH), "Theme file should exist after create")


func test_create_theme_requires_res_path() -> void:
	var result := _handler.create_theme({"path": "/tmp/foo.tres"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_theme_requires_tres_suffix() -> void:
	var result := _handler.create_theme({"path": "res://foo.txt"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_theme_rejects_existing_without_overwrite() -> void:
	_make_theme()
	var result := _handler.create_theme({"path": TEST_THEME_PATH})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_theme_overwrite_allowed() -> void:
	_make_theme()
	var result := _handler.create_theme({"path": TEST_THEME_PATH, "overwrite": true})
	assert_has_key(result, "data")


# ----- theme_set_color -----

func test_theme_set_color_accepts_hex() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": "#e0e0ff",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "color")
	assert_true(result.data.undoable)
	# Reload from disk to confirm it was persisted.
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_true(theme.has_color("font_color", "Label"))
	var c := theme.get_color("font_color", "Label")
	assert_true(abs(c.r - 0.8784) < 0.01, "Color parsed from hex")


func test_theme_set_color_accepts_dict() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": {"r": 0.5, "g": 0.3, "b": 0.1, "a": 1.0},
	})
	assert_has_key(result, "data")


func test_theme_set_color_rejects_garbage_string() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": "not-a-color-at-all-!!",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_theme_set_color_missing_theme_path() -> void:
	var result := _handler.set_color({
		"class_name": "Label",
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_theme_set_color_missing_class_name() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_theme_set_color_theme_not_found() -> void:
	var result := _handler.set_color({
		"theme_path": "res://nope/does_not_exist.tres",
		"class_name": "Label",
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- theme_set_constant -----

func test_theme_set_constant() -> void:
	_make_theme()
	var result := _handler.set_constant({
		"theme_path": TEST_THEME_PATH,
		"class_name": "VBoxContainer",
		"name": "separation",
		"value": 16,
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_eq(theme.get_constant("separation", "VBoxContainer"), 16)


# ----- theme_set_font_size -----

func test_theme_set_font_size() -> void:
	_make_theme()
	var result := _handler.set_font_size({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_size",
		"value": 24,
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_eq(theme.get_font_size("font_size", "Label"), 24)


# ----- theme_set_stylebox_flat -----

func test_theme_set_stylebox_flat_composes_fields() -> void:
	# The `all` key inside each nested dict applies uniformly to all sides.
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"bg_color": "#101820",
		"border_color": "#00ffff",
		"border": {"all": 2},
		"corners": {"all": 8},
		"margins": {"all": 12.0},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.stylebox_class, "StyleBoxFlat")
	assert_eq(result.data.border.top, 2)
	assert_eq(result.data.corners.top_left, 8)
	assert_eq(result.data.margins.top, 12.0)
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("normal", "Button")
	assert_true(sb != null, "StyleBox was saved")
	assert_eq(sb.border_width_left, 2)
	assert_eq(sb.corner_radius_top_left, 8)
	assert_eq(sb.content_margin_left, 12.0)


func test_theme_set_stylebox_flat_side_specific_overrides_all() -> void:
	# Side-specific keys must override `all`.
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"border": {"all": 1, "top": 4},
		"corners": {"all": 0, "top_left": 16},
		"margins": {"all": 2.0, "bottom": 10.0},
	})
	assert_has_key(result, "data")
	# Response reflects the resolved per-side values.
	assert_eq(result.data.border.top, 4)
	assert_eq(result.data.border.bottom, 1)
	assert_eq(result.data.border.left, 1)
	assert_eq(result.data.border.right, 1)
	assert_eq(result.data.corners.top_left, 16)
	assert_eq(result.data.corners.top_right, 0)
	assert_eq(result.data.margins.bottom, 10.0)
	assert_eq(result.data.margins.top, 2.0)
	# And the saved StyleBox matches.
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("normal", "Button")
	assert_eq(sb.border_width_top, 4)
	assert_eq(sb.border_width_bottom, 1)
	assert_eq(sb.corner_radius_top_left, 16)
	assert_eq(sb.corner_radius_top_right, 0)
	assert_eq(sb.content_margin_bottom, 10.0)


func test_theme_set_stylebox_flat_shadow_nested_dict() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"shadow": {"color": "#00000080", "size": 6, "offset_x": 2.0, "offset_y": 3.0},
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("normal", "Button")
	assert_eq(sb.shadow_size, 6)
	assert_eq(sb.shadow_offset, Vector2(2.0, 3.0))


func test_theme_set_stylebox_flat_rejects_unknown_nested_key() -> void:
	# Typos in nested dicts must fail loudly, not be silently ignored.
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"border": {"all": 1, "topp": 4},  # 'topp' not a real key
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "topp")


func test_theme_set_stylebox_flat_rejects_bad_color() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"bg_color": "not a color!!",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- theme_apply -----

func test_theme_apply_to_control() -> void:
	_make_theme()
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var panel := Panel.new()
	panel.name = "TestThemedPanel"
	scene_root.add_child(panel)
	panel.owner = scene_root
	var path := "/" + scene_root.name + "/TestThemedPanel"

	var result := _handler.apply_theme({
		"node_path": path,
		"theme_path": TEST_THEME_PATH,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.cleared, false)
	assert_true(panel.theme != null, "Theme should be assigned to panel")

	# Clean up.
	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_theme_apply_clear_with_empty_path() -> void:
	_make_theme()
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var panel := Panel.new()
	panel.name = "TestClearThemePanel"
	panel.theme = ResourceLoader.load(TEST_THEME_PATH)
	scene_root.add_child(panel)
	panel.owner = scene_root
	var path := "/" + scene_root.name + "/TestClearThemePanel"

	var result := _handler.apply_theme({"node_path": path, "theme_path": ""})
	assert_has_key(result, "data")
	assert_eq(result.data.cleared, true)
	assert_true(panel.theme == null, "Theme should be cleared")

	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_theme_apply_rejects_non_control() -> void:
	_make_theme()
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	# Scene root is a Node3D — not a Control.
	var result := _handler.apply_theme({
		"node_path": "/" + scene_root.name,
		"theme_path": TEST_THEME_PATH,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not a Control")


# ----- Regression: Copilot review fixes -----

func test_theme_set_color_rejects_null_value() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": null,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "null")


func test_create_theme_overwritten_flag_tracks_pre_save_state() -> void:
	# Fresh location — overwritten must be false even when overwrite=true.
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	var result := _handler.create_theme({"path": TEST_THEME_PATH, "overwrite": true})
	assert_has_key(result, "data")
	assert_eq(result.data.overwritten, false, "Overwritten should be false on fresh create")

	# Second call: now it should be true.
	var result2 := _handler.create_theme({"path": TEST_THEME_PATH, "overwrite": true})
	assert_has_key(result2, "data")
	assert_eq(result2.data.overwritten, true, "Overwritten should be true on second create")


func test_create_theme_missing_path_names_param_correctly() -> void:
	# Error message should name `path`, not `theme_path`, for theme_create.
	var result := _handler.create_theme({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "path")
	# Make sure it's NOT using the default "theme_path" label.
	assert_true(result.error.message.find("theme_path") == -1, "Error should say 'path', not 'theme_path'")


# ----- Friction fix: auto-create parent directories -----

func test_create_theme_creates_parent_directories() -> void:
	var nested_path := "res://tests/_mcp_nested_dir/subdir/test_theme.tres"
	# Ensure clean state.
	if FileAccess.file_exists(nested_path):
		DirAccess.remove_absolute(nested_path)
	if DirAccess.dir_exists_absolute("res://tests/_mcp_nested_dir/subdir"):
		DirAccess.remove_absolute("res://tests/_mcp_nested_dir/subdir")
	if DirAccess.dir_exists_absolute("res://tests/_mcp_nested_dir"):
		DirAccess.remove_absolute("res://tests/_mcp_nested_dir")

	var result := _handler.create_theme({"path": nested_path})
	assert_has_key(result, "data")
	assert_true(FileAccess.file_exists(nested_path), "Theme file should exist in nested dir")

	# Cleanup.
	DirAccess.remove_absolute(nested_path)
	DirAccess.remove_absolute("res://tests/_mcp_nested_dir/subdir")
	DirAccess.remove_absolute("res://tests/_mcp_nested_dir")


# ----- Per-side stylebox parameters via nested dicts -----

func test_set_stylebox_flat_per_side_border_width() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"border": {"all": 1, "top": 4, "bottom": 2},
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("normal", "Button")
	assert_eq(sb.border_width_top, 4)
	assert_eq(sb.border_width_bottom, 2)
	assert_eq(sb.border_width_left, 1)  # from `all`
	assert_eq(sb.border_width_right, 1)


func test_set_stylebox_flat_per_corner_radius() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "panel",
		"corners": {"all": 4, "top_left": 12, "bottom_right": 0},
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("panel", "Panel")
	assert_eq(sb.corner_radius_top_left, 12)
	assert_eq(sb.corner_radius_top_right, 4)  # from `all`
	assert_eq(sb.corner_radius_bottom_left, 4)
	assert_eq(sb.corner_radius_bottom_right, 0)


func test_set_stylebox_flat_per_side_content_margin() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "PanelContainer",
		"name": "panel",
		"margins": {"all": 8.0, "top": 16.0},
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxFlat = theme.get_stylebox("panel", "PanelContainer")
	assert_eq(sb.content_margin_top, 16.0)
	assert_eq(sb.content_margin_bottom, 8.0)
	assert_eq(sb.content_margin_left, 8.0)
	assert_eq(sb.content_margin_right, 8.0)
