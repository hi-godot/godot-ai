@tool
extends McpTestSuite

const ProjectHandler := preload("res://addons/godot_ai/handlers/project_handler.gd")

## Tests for ProjectHandler — project settings and filesystem search.

var _handler: ProjectHandler


func suite_name() -> String:
	return "project"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = ProjectHandler.new()


# ----- get_project_setting -----

func test_get_project_setting_returns_value() -> void:
	var result := _handler.get_project_setting({"key": "application/config/name"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "key")
	assert_eq(result.data.key, "application/config/name")
	assert_has_key(result.data, "value")
	assert_has_key(result.data, "type")


func test_get_project_setting_missing_key() -> void:
	var result := _handler.get_project_setting({})
	assert_is_error(result)


func test_get_project_setting_unknown_key() -> void:
	var result := _handler.get_project_setting({"key": "nonexistent/setting/key"})
	assert_is_error(result)


func test_get_project_setting_viewport_width() -> void:
	var result := _handler.get_project_setting({"key": "display/window/size/viewport_width"})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "int")


# ----- set_project_setting -----

func test_set_project_setting_roundtrip() -> void:
	## Read the current name, set a new one, then restore
	var original := _handler.get_project_setting({"key": "application/config/name"})
	var old_name = original.data.value

	var result := _handler.set_project_setting({
		"key": "application/config/name",
		"value": "_McpTestName",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.key, "application/config/name")
	assert_eq(result.data.value, "_McpTestName")
	assert_has_key(result.data, "old_value")

	## Restore
	_handler.set_project_setting({"key": "application/config/name", "value": old_name})


func test_set_project_setting_preserves_int_type() -> void:
	## Issue #31: JSON has no int type, so whole-number values arrive as floats.
	## When the existing setting is TYPE_INT, the handler must coerce back to int
	## so we don't silently flip typed-int settings to floats on disk.
	var original := _handler.get_project_setting({"key": "display/window/size/viewport_width"})
	var old_width = original.data.value

	# Send a float value that would naturally come from JSON-encoded `1920`.
	var result := _handler.set_project_setting({
		"key": "display/window/size/viewport_width",
		"value": 1920.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "int", "Whole-number float on an int setting must be stored as int")
	assert_eq(result.data.value, 1920)

	## Restore
	_handler.set_project_setting({"key": "display/window/size/viewport_width", "value": old_width})


func test_set_project_setting_missing_key() -> void:
	var result := _handler.set_project_setting({})
	assert_is_error(result)


func test_set_project_setting_missing_value() -> void:
	var result := _handler.set_project_setting({"key": "application/config/name"})
	assert_is_error(result)


# ----- search_filesystem -----

func test_search_filesystem_by_name() -> void:
	var result := _handler.search_filesystem({"name": "main"})
	assert_has_key(result, "data")
	assert_has_key(result.data, "files")
	assert_has_key(result.data, "count")
	assert_gt(result.data.count, 0, "Should find at least one file matching 'main'")


func test_search_filesystem_by_type() -> void:
	var result := _handler.search_filesystem({"type": "PackedScene"})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should find at least one PackedScene")
	for file in result.data.files:
		assert_eq(file.type, "PackedScene")


func test_search_filesystem_by_path() -> void:
	var result := _handler.search_filesystem({"path": "tests/"})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should find files in tests/ directory")


func test_search_filesystem_no_filter_error() -> void:
	var result := _handler.search_filesystem({})
	assert_is_error(result)


func test_search_filesystem_no_results() -> void:
	var result := _handler.search_filesystem({"name": "zzz_nonexistent_file_xyz"})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 0)


# ----- run_project -----

## NOTE: test_run_project_rejects_when_already_playing removed — it was an
## empty test (just `pass`) that requires the project to actually be running,
## which can't happen from within the test runner. Covered by Python tests.


func test_run_project_invalid_mode() -> void:
	var result := _handler.run_project({"mode": "invalid_mode"})
	assert_is_error(result)


func test_run_project_invalid_mode_restores_connection_pause() -> void:
	var conn := McpConnection.new()
	var handler := ProjectHandler.new(conn)
	assert_false(conn.pause_processing, "precondition: connection processing starts unpaused")

	var result := handler.run_project({"mode": "invalid_mode"})

	assert_is_error(result)
	assert_false(conn.pause_processing, "validation errors must not leave processing paused")
	conn.free()


func test_run_project_validation_error_does_not_rotate_capture_run() -> void:
	var plugin := McpDebuggerPlugin.new()
	var handler := ProjectHandler.new(null, plugin)

	var result := handler.run_project({"mode": "invalid_mode"})

	assert_is_error(result)
	assert_eq(plugin._game_run_token, 0, "invalid runs must not clear or advance game capture readiness")


func test_run_project_custom_missing_scene() -> void:
	var result := _handler.run_project({"mode": "custom"})
	assert_is_error(result)


func test_run_project_custom_empty_scene() -> void:
	var result := _handler.run_project({"mode": "custom", "scene": ""})
	assert_is_error(result)


func test_run_project_autosave_false_restores_editor_setting() -> void:
	## Issue #81: autosave=false must restore run/auto_save/save_before_running
	## to its prior value even on the validation-error path (mode invalid).
	## Guards against future refactors dropping the restore branch.
	var autosave_key := "run/auto_save/save_before_running"
	var editor_settings := EditorInterface.get_editor_settings()
	if editor_settings == null or not editor_settings.has_setting(autosave_key):
		return  ## setting not present in this engine build; skip
	var prior = editor_settings.get_setting(autosave_key)
	editor_settings.set_setting(autosave_key, true)

	var result := _handler.run_project({"mode": "invalid_mode", "autosave": false})
	assert_is_error(result)
	assert_eq(
		bool(editor_settings.get_setting(autosave_key)),
		true,
		"save_before_running must be restored after run_project returns",
	)

	editor_settings.set_setting(autosave_key, prior)


# ----- stop_project -----

func test_stop_project_rejects_when_not_playing() -> void:
	var result := _handler.stop_project({})
	assert_is_error(result)
