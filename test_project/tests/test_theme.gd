@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const ThemeHandler := preload("res://addons/godot_ai/handlers/theme_handler.gd")

## Tests for ThemeHandler — Theme resource authoring.

var _handler: ThemeHandler
var _undo_redo: EditorUndoRedoManager

## Suite-scoped Texture2D / Font fixtures under user:// (recreated on every
## save so a stale ResourceLoader cache can't outlive the file).
var _texture_fixture: String = ""
var _font_fixture: String = ""

const TEST_THEME_PATH := "res://tests/_mcp_test_theme.tres"


func suite_name() -> String:
	return "theme"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ThemeHandler.new(_undo_redo)
	_texture_fixture = _make_texture_fixture()
	_font_fixture = _make_font_fixture()


func suite_teardown() -> void:
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	_remove_fixtures()


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
	assert_is_error(result)


func test_create_theme_requires_tres_suffix() -> void:
	var result := _handler.create_theme({"path": "res://foo.txt"})
	assert_is_error(result)


func test_create_theme_rejects_existing_without_overwrite() -> void:
	_make_theme()
	var result := _handler.create_theme({"path": TEST_THEME_PATH})
	assert_is_error(result)


func test_create_theme_overwrite_allowed() -> void:
	_make_theme()
	var result := _handler.create_theme({"path": TEST_THEME_PATH, "overwrite": true})
	assert_has_key(result, "data")
	assert_eq(result.data.overwritten, true,
		"overwritten flag must reflect the pre-existing file")
	assert_true(FileAccess.file_exists(TEST_THEME_PATH),
		"theme file should still exist after overwrite")


## Spy McpConnection that counts pause()/resume() calls instead of actually
## touching WebSocket processing state — proves a handler routes its
## ResourceSaver.save through the #288 reentrancy guard without needing a
## live connection.
class _PauseSpyConnection:
	extends McpConnection
	var pause_calls := 0
	var resume_calls := 0

	func pause() -> void:
		pause_calls += 1
		super()

	func resume() -> void:
		resume_calls += 1
		super()


func test_create_theme_saves_through_pause_guard() -> void:
	var spy := _PauseSpyConnection.new()
	var handler := ThemeHandler.new(_undo_redo, spy)
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	var result := handler.create_theme({"path": TEST_THEME_PATH})
	assert_has_key(result, "data")
	assert_eq(spy.pause_calls, 1, "create_theme's save must pause processing once (#288 guard)")
	assert_eq(spy.resume_calls, 1, "create_theme's save must resume processing once (#288 guard)")
	assert_false(spy.pause_processing, "guard must not leave the connection paused")
	spy.free()


func test_set_color_undo_callable_saves_through_pause_guard() -> void:
	var spy := _PauseSpyConnection.new()
	var handler := ThemeHandler.new(_undo_redo, spy)
	if FileAccess.file_exists(TEST_THEME_PATH):
		DirAccess.remove_absolute(TEST_THEME_PATH)
	handler.create_theme({"path": TEST_THEME_PATH})
	spy.pause_calls = 0
	spy.resume_calls = 0
	var result := handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": "#e0e0ff",
	})
	assert_has_key(result, "data")
	assert_eq(spy.pause_calls, 1, "_apply_scalar's undo-callable save must pause processing once (#288 guard)")
	assert_eq(spy.resume_calls, 1, "_apply_scalar's undo-callable save must resume processing once (#288 guard)")
	spy.free()


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
	# Read back from disk so a missing dict→Color coercion can't pass by
	# returning a successful envelope while storing a raw Dict.
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_true(theme.has_color("font_color", "Label"))
	var c := theme.get_color("font_color", "Label")
	assert_true(c is Color, "Stored value must be a Color, not a raw Dict")
	assert_true(abs(c.r - 0.5) < 0.01)
	assert_true(abs(c.g - 0.3) < 0.01)
	assert_true(abs(c.b - 0.1) < 0.01)
	assert_true(abs(c.a - 1.0) < 0.01)


func test_theme_set_color_rejects_garbage_string() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Label",
		"name": "font_color",
		"value": "not-a-color-at-all-!!",
	})
	assert_is_error(result)


func test_theme_set_color_missing_theme_path() -> void:
	var result := _handler.set_color({
		"class_name": "Label",
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_theme_set_color_missing_class_name() -> void:
	_make_theme()
	var result := _handler.set_color({
		"theme_path": TEST_THEME_PATH,
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result)


func test_theme_set_color_theme_not_found() -> void:
	var result := _handler.set_color({
		"theme_path": "res://nope/does_not_exist.tres",
		"class_name": "Label",
		"name": "font_color",
		"value": "#ff0000",
	})
	assert_is_error(result)


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
	assert_is_error(result)
	assert_contains(result.error.message, "topp")


func test_theme_set_stylebox_flat_rejects_bad_color() -> void:
	_make_theme()
	var result := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"bg_color": "not a color!!",
	})
	assert_is_error(result)


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
	assert_is_error(result)
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
	assert_is_error(result)
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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
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


func test_set_stylebox_flat_rejects_invalid_numbers() -> void:
	## dsarno's native probe: a valid value plus a non-numeric one must refuse
	## with a structured error, leave the stored slot untouched, and commit no
	## undo action. The runner's script-error capture also fails this test if
	## the handler raises an engine conversion error instead of refusing.
	_make_theme()
	var seeded := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"bg_color": "#112233",
		"border": {"all": 1},
	})
	assert_has_key(seeded, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var before: StyleBoxFlat = theme.get_stylebox("guarded", "Panel")
	var before_color := before.bg_color
	_undo_redo.clear_history()

	var bad_border := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"bg_color": "#ff0000",
		"border": {"all": {"bad": true}},
	})
	assert_is_error(bad_border, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_border.error.message, "border.all")
	var stored: StyleBoxFlat = theme.get_stylebox("guarded", "Panel")
	assert_true(
		stored.bg_color.is_equal_approx(before_color),
		"a refused patch must not change the stored slot"
	)
	assert_eq(stored.border_width_top, 1)
	assert_false(editor_undo(_undo_redo), "a refused patch must not commit an undo action")

	var bad_margin := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"margins": {"all": INF},
	})
	assert_is_error(bad_margin, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_margin.error.message, "margins.all")
	assert_contains(bad_margin.error.message, "finite")

	var bad_corner := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"corners": {"top_left": []},
	})
	assert_is_error(bad_corner, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_corner.error.message, "corners.top_left")

	var bad_shadow_size := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"shadow": {"size": {"bad": true}},
	})
	assert_is_error(bad_shadow_size, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_shadow_size.error.message, "shadow.size")

	var bad_shadow_offset := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"shadow": {"offset_x": NAN},
	})
	assert_is_error(bad_shadow_offset, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_shadow_offset.error.message, "shadow.offset_x")

	## Strict flags: a stringified bool must not invert the caller's intent.
	var bad_flag := _handler.set_stylebox_flat({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Panel",
		"name": "guarded",
		"anti_aliasing": "false",
	})
	assert_is_error(bad_flag, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_flag.error.message, "anti_aliasing")


# ----- stylebox_texture / font / icon fixtures -----

const TEST_THEME_TEXTURE_PATH := "user://test_theme_texture.tres"
const TEST_THEME_FONT_PATH := "user://test_theme_font.tres"


func _make_texture_fixture() -> String:
	if FileAccess.file_exists(TEST_THEME_TEXTURE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_THEME_TEXTURE_PATH))
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 0.5, 0.0, 1.0))
	var texture := ImageTexture.create_from_image(image)
	if ResourceSaver.save(texture, TEST_THEME_TEXTURE_PATH) != OK:
		return ""
	return TEST_THEME_TEXTURE_PATH


func _make_font_fixture() -> String:
	if FileAccess.file_exists(TEST_THEME_FONT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_THEME_FONT_PATH))
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Arial"])
	if ResourceSaver.save(font, TEST_THEME_FONT_PATH) != OK:
		return ""
	return TEST_THEME_FONT_PATH


func _remove_fixtures() -> void:
	for path in [TEST_THEME_TEXTURE_PATH, TEST_THEME_FONT_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ----- set_stylebox_texture -----

func test_set_stylebox_texture_composes_fields() -> void:
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	var result := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "normal",
		"texture_path": texture_path,
		"region": {"position": {"x": 1.0, "y": 2.0}, "size": {"x": 4.0, "y": 4.0}},
		"margins": {"all": 2.0, "left": 3.0},
		"draw_center": false,
		"axis_stretch_horizontal": "tile",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.stylebox_class, "StyleBoxTexture")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	var sb: StyleBoxTexture = theme.get_stylebox("normal", "Button")
	assert_true(sb is StyleBoxTexture, "slot must hold a StyleBoxTexture")
	assert_true(sb.texture != null, "texture must be assigned")
	assert_eq(sb.region_rect, Rect2(1, 2, 4, 4))
	assert_eq(sb.texture_margin_left, 3.0, "per-side margin must override all")
	assert_eq(sb.texture_margin_top, 2.0)
	assert_false(sb.draw_center)
	assert_eq(sb.axis_stretch_horizontal, StyleBoxTexture.AXIS_STRETCH_MODE_TILE)


func test_set_stylebox_texture_is_undoable() -> void:
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	## Earlier suites leave actions in the scene history; clear so
	## `editor_undo` can only reach this test's action.
	_undo_redo.clear_history()
	var result := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "hover",
		"texture_path": texture_path,
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_true(theme.has_stylebox("hover", "Button"))
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	var reloaded: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_false(reloaded.has_stylebox("hover", "Button"), "undo must clear the added slot")


func test_set_stylebox_texture_rejects_bad_inputs() -> void:
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	var bad_region := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "bad_region",
		"texture_path": texture_path,
		"region": {"x": 1.0},
	})
	assert_is_error(bad_region, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_region.error.message, "region")
	var bad_axis := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "bad_axis",
		"texture_path": texture_path,
		"axis_stretch_vertical": "wobble",
	})
	assert_is_error(bad_axis, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_axis.error.message, "axis_stretch_vertical")
	var bad_resource := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "bad_resource",
		"texture_path": TEST_THEME_PATH,
	})
	assert_is_error(bad_resource, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_resource.error.message, "Texture2D")


func test_set_stylebox_texture_rejects_invalid_margins() -> void:
	## dsarno's native probe: left=2 plus a non-numeric right must refuse the
	## whole call — no slot stored, no undo action, no engine conversion error.
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	_undo_redo.clear_history()
	var bad_margin := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "guarded",
		"texture_path": texture_path,
		"margins": {"left": 2, "right": {"bad": true}},
	})
	assert_is_error(bad_margin, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_margin.error.message, "margins.right")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_false(theme.has_stylebox("guarded", "Button"),
		"a refused texture stylebox must not be stored")
	assert_false(editor_undo(_undo_redo), "a refused call must not commit an undo action")

	var nonfinite := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "guarded",
		"texture_path": texture_path,
		"margins": {"all": INF},
	})
	assert_is_error(nonfinite, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(nonfinite.error.message, "margins.all")
	assert_contains(nonfinite.error.message, "finite")
	assert_false(theme.has_stylebox("guarded", "Button"))

	## Strict flag parity with the flat stylebox.
	var bad_flag := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "guarded",
		"texture_path": texture_path,
		"draw_center": "false",
	})
	assert_is_error(bad_flag, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_flag.error.message, "draw_center")


func test_set_stylebox_texture_rejects_non_finite_region() -> void:
	## A NaN/INF region component must refuse the call: region_rect accepts
	## non-finite values without normalization, so committing one would persist
	## an invalid slot plus an undo action.
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	_undo_redo.clear_history()
	var bad_array := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "guarded",
		"texture_path": texture_path,
		"region": [NAN, 0.0, 4.0, 4.0],
	})
	assert_is_error(bad_array, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_array.error.message, "region")
	var bad_dict := _handler.set_stylebox_texture({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "guarded",
		"texture_path": texture_path,
		"region": {"position": {"x": INF, "y": 0.0}, "size": {"x": 4.0, "y": 4.0}},
	})
	assert_is_error(bad_dict, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_dict.error.message, "region")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_false(theme.has_stylebox("guarded", "Button"),
		"a refused region must not store a stylebox")
	assert_false(editor_undo(_undo_redo), "a refused region must not commit an undo action")


func test_side_helpers_refuse_non_numeric_values_without_mutation() -> void:
	## Direct helper probes mirroring dsarno's evidence: the helpers must
	## return a structured error and apply nothing at all.
	var texture_sb := StyleBoxTexture.new()
	var texture_result := ThemeHandler._apply_texture_margins(texture_sb, {"left": 2, "right": {"bad": true}})
	assert_is_error(texture_result, ErrorCodes.WRONG_TYPE)
	assert_contains(texture_result.error.message, "margins.right")
	assert_eq(texture_sb.texture_margin_left, 0.0,
		"no side may be applied when a later key is invalid")

	var flat_sb := StyleBoxFlat.new()
	var flat_result := ThemeHandler._apply_sides(flat_sb, {"all": {"bad": true}}, "border",
		["top", "bottom", "left", "right"], "border_width_", TYPE_INT)
	assert_is_error(flat_result, ErrorCodes.WRONG_TYPE)
	assert_contains(flat_result.error.message, "border.all")
	assert_eq(flat_sb.border_width_top, 0)

	var ok_result := ThemeHandler._apply_sides(flat_sb, {"all": 2, "top": 4}, "border",
		["top", "bottom", "left", "right"], "border_width_", TYPE_INT)
	assert_has_key(ok_result, "ok")
	assert_eq(flat_sb.border_width_top, 4)
	assert_eq(flat_sb.border_width_left, 2)

	assert_true(ThemeHandler._parse_rect2([NAN, 0.0, 4.0, 4.0]) == null,
		"a NaN region component must be refused")
	assert_true(ThemeHandler._parse_rect2(Rect2(NAN, 0.0, 4.0, 4.0)) == null,
		"a NaN Rect2 must be refused")
	assert_true(
		ThemeHandler._parse_rect2({"position": {"x": INF, "y": 0.0}, "size": {"x": 4.0, "y": 4.0}}) == null,
		"an INF region component must be refused"
	)


# ----- set_font / set_icon -----

func test_set_font_assigns_and_undoes() -> void:
	var font_path := _font_fixture
	if font_path.is_empty():
		skip("Font fixture could not be created")
		return
	_make_theme()
	_undo_redo.clear_history()
	var result := _handler.set_font({
		"theme_path": TEST_THEME_PATH,
		"class_name": "Button",
		"name": "font",
		"font_path": font_path,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "font")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_true(theme.has_font("font", "Button"))
	assert_true(theme.get_font("font", "Button") is Font)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	var reloaded: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_false(reloaded.has_font("font", "Button"), "undo must clear the font slot")


func test_set_icon_rejects_wrong_resource_class() -> void:
	var font_path := _font_fixture
	if font_path.is_empty():
		skip("Font fixture could not be created")
		return
	_make_theme()
	var result := _handler.set_icon({
		"theme_path": TEST_THEME_PATH,
		"class_name": "CheckBox",
		"name": "checked",
		"texture_path": font_path,
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "Texture2D")


func test_set_icon_assigns_texture() -> void:
	var texture_path := _texture_fixture
	if texture_path.is_empty():
		skip("Texture fixture could not be created")
		return
	_make_theme()
	var result := _handler.set_icon({
		"theme_path": TEST_THEME_PATH,
		"class_name": "CheckBox",
		"name": "checked",
		"texture_path": texture_path,
	})
	assert_has_key(result, "data")
	var theme: Theme = ResourceLoader.load(TEST_THEME_PATH)
	assert_true(theme.has_icon("checked", "CheckBox"))


# ----- stylebox_override -----

func test_stylebox_override_patches_control_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var panel := Panel.new()
	panel.name = "OverridePanel"
	scene_root.add_child(panel)
	panel.owner = scene_root
	_undo_redo.clear_history()
	var result := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverridePanel",
		"slot": "panel",
		"patch": {"bg_color": {"r": 0.2, "g": 0.1, "b": 0.1, "a": 1.0}, "border": {"all": 0}},
	})
	assert_has_key(result, "data")
	assert_false(result.data.overrode_existing, "the node had no override before")
	assert_true(panel.has_theme_stylebox_override("panel"),
		"the override must be present after the call")
	var resolved: StyleBox = panel.get_theme_stylebox("panel")
	assert_true(resolved is StyleBoxFlat, "the override must be a StyleBoxFlat")
	assert_true(
		(resolved as StyleBoxFlat).bg_color.is_equal_approx(Color(0.2, 0.1, 0.1, 1.0)),
		"patched bg_color must be stored"
	)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_false(panel.has_theme_stylebox_override("panel"),
		"undo must remove an override the node did not have before")
	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_stylebox_override_restores_previous_override() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var panel := Panel.new()
	panel.name = "OverridePanelExisting"
	var existing := StyleBoxFlat.new()
	existing.bg_color = Color(0.0, 0.5, 0.0, 1.0)
	panel.add_theme_stylebox_override("panel", existing)
	scene_root.add_child(panel)
	panel.owner = scene_root
	_undo_redo.clear_history()
	var result := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverridePanelExisting",
		"slot": "panel",
		"patch": {"bg_color": {"r": 0.9, "g": 0.0, "b": 0.0, "a": 1.0}},
	})
	assert_has_key(result, "data")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	var restored: StyleBox = panel.get_theme_stylebox("panel")
	assert_true(restored is StyleBoxFlat)
	assert_true(
		(restored as StyleBoxFlat).bg_color.is_equal_approx(Color(0.0, 0.5, 0.0, 1.0)),
		"undo must restore the previous override, got %s" % str((restored as StyleBoxFlat).bg_color)
	)
	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_stylebox_override_preserves_unpatched_shadow_offset() -> void:
	## A patch that sets only one shadow-offset axis must keep the other axis
	## from the resolved stylebox instead of silently resetting it to 0.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var panel := Panel.new()
	panel.name = "OverrideShadowAxis"
	var existing := StyleBoxFlat.new()
	existing.shadow_offset = Vector2(3.0, 5.0)
	existing.shadow_size = 4
	panel.add_theme_stylebox_override("panel", existing)
	scene_root.add_child(panel)
	panel.owner = scene_root
	_undo_redo.clear_history()
	var result := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideShadowAxis",
		"slot": "panel",
		"patch": {"shadow": {"offset_x": 7.0}},
	})
	assert_has_key(result, "data")
	var resolved: StyleBoxFlat = panel.get_theme_stylebox("panel")
	assert_true(absf(resolved.shadow_offset.x - 7.0) < 0.001, "the patched axis must apply")
	assert_true(
		absf(resolved.shadow_offset.y - 5.0) < 0.001,
		"the unpatched axis must keep the resolved stylebox's value, got %s" % str(resolved.shadow_offset)
	)
	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_stylebox_override_rejects_non_control_and_non_flat_slot() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var node3d := Node3D.new()
	node3d.name = "OverrideNotControl"
	scene_root.add_child(node3d)
	node3d.owner = scene_root
	var non_control := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideNotControl",
		"slot": "panel",
		"patch": {},
	})
	assert_is_error(non_control, ErrorCodes.WRONG_TYPE)
	node3d.get_parent().remove_child(node3d)
	node3d.queue_free()

	var label := RichTextLabel.new()
	label.name = "OverrideNonFlat"
	scene_root.add_child(label)
	label.owner = scene_root
	var non_flat := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideNonFlat",
		"slot": "normal",
		"patch": {"bg_color": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}},
	})
	assert_is_error(non_flat, ErrorCodes.WRONG_TYPE)
	assert_contains(non_flat.error.message, "StyleBoxFlat")
	label.get_parent().remove_child(label)
	label.queue_free()


func test_stylebox_override_rejects_unknown_patch_key() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var panel := Panel.new()
	panel.name = "OverrideBadPatch"
	scene_root.add_child(panel)
	panel.owner = scene_root
	var result := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideBadPatch",
		"slot": "panel",
		"patch": {"shadow": {"wobble": 1}},
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "wobble")
	assert_false(panel.has_theme_stylebox_override("panel"),
		"a refused patch must not leave an override")
	panel.get_parent().remove_child(panel)
	panel.queue_free()


func test_stylebox_override_rejects_invalid_patch_numbers() -> void:
	## dsarno's repro on the override path: a valid bg_color plus a non-numeric
	## border must refuse without attaching an override or committing an action.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var panel := Panel.new()
	panel.name = "OverrideInvalidPatch"
	scene_root.add_child(panel)
	panel.owner = scene_root
	_undo_redo.clear_history()
	var result := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideInvalidPatch",
		"slot": "panel",
		"patch": {
			"bg_color": {"r": 0.9, "g": 0.0, "b": 0.0, "a": 1.0},
			"border": {"all": {"bad": true}},
		},
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "border.all")
	assert_false(panel.has_theme_stylebox_override("panel"),
		"a refused patch must not leave an override")
	assert_false(editor_undo(_undo_redo), "a refused patch must not commit an undo action")

	## A pre-existing override must survive a refused patch untouched.
	var existing := StyleBoxFlat.new()
	existing.bg_color = Color(0.0, 0.5, 0.0, 1.0)
	panel.add_theme_stylebox_override("panel", existing)
	var refused := _handler.stylebox_override({
		"path": "/" + scene_root.name + "/OverrideInvalidPatch",
		"slot": "panel",
		"patch": {"shadow": {"size": {"bad": true}}},
	})
	assert_is_error(refused, ErrorCodes.WRONG_TYPE)
	assert_contains(refused.error.message, "shadow.size")
	assert_true(panel.has_theme_stylebox_override("panel"))
	var resolved: StyleBoxFlat = panel.get_theme_stylebox("panel")
	assert_true(
		resolved.bg_color.is_equal_approx(Color(0.0, 0.5, 0.0, 1.0)),
		"a refused patch must not modify the existing override"
	)
	panel.get_parent().remove_child(panel)
	panel.queue_free()
