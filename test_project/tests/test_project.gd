@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_set_project_setting_missing_value() -> void:
	var result := _handler.set_project_setting({"key": "application/config/name"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_run_project_invalid_mode_restores_connection_pause() -> void:
	var conn := McpConnection.new()
	var handler := ProjectHandler.new(conn)
	assert_false(conn.pause_processing, "precondition: connection processing starts unpaused")

	var result := handler.run_project({"mode": "invalid_mode"})

	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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
		skip("run/auto_save/save_before_running not present in this engine build")
		return
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


func _run_status(status: String, elapsed_msec: int = 0, ready_wait_msec: int = 3000) -> Dictionary:
	return {
		"status": status,
		"run_token": 1,
		"active": status != "stopped",
		"ready": status == "live",
		"helper_expected": status != "no_helper",
		"run_started_msec": 100,
		"elapsed_msec": elapsed_msec,
		"ready_wait_msec": ready_wait_msec,
		"editor_log_cursor": 7,
	}


func _errors_info(errors: Array[Dictionary] = [], scope: String = "none", truncated: bool = false) -> Dictionary:
	return {
		"errors": errors,
		"scope": scope,
		"truncated": truncated,
	}


func test_run_project_liveness_decision_live_short_circuits() -> void:
	var decision := _handler._run_project_liveness_decision(_run_status("live", 100), _errors_info())
	assert_eq(decision.resolve, true)
	assert_eq(decision.liveness_status, "live")
	assert_contains(decision.message, "live")


func test_run_project_liveness_decision_run_scoped_error_short_circuits() -> void:
	var err := {"text": "Parse Error: Expected expression", "path": "res://broken.gd", "line": 4}
	var decision := _handler._run_project_liveness_decision(
		_run_status("launching", 100),
		_errors_info([err], "run")
	)
	assert_eq(decision.resolve, true)
	assert_eq(decision.liveness_status, "not_live")
	assert_contains(decision.message, "failed to load")
	assert_contains(decision.message, "res://broken.gd:4")
	assert_eq(decision.recent_errors.size(), 1)
	assert_eq(decision.recent_errors_scope, "run")


func test_run_project_liveness_decision_retained_error_does_not_short_circuit_launching() -> void:
	var err := {"text": "Parse Error: Old", "path": "res://old.gd", "line": 2}
	var decision := _handler._run_project_liveness_decision(
		_run_status("launching", 100),
		_errors_info([err], "retained_recent")
	)
	assert_eq(decision.resolve, false)
	assert_eq(decision.recent_errors_may_predate_run, true)


func test_run_project_liveness_decision_not_live_without_errors_is_soft() -> void:
	var decision := _handler._run_project_liveness_decision(_run_status("not_live", 3000), _errors_info())
	assert_eq(decision.resolve, true)
	assert_eq(decision.liveness_status, "not_live")
	assert_contains(decision.message, "did not become live")
	assert_false(decision.message.contains("crashed"), "no correlated error must not claim a crash")


func test_run_project_liveness_decision_not_live_with_retained_error_is_labeled() -> void:
	var err := {"text": "Parse Error: Old", "path": "res://old.gd", "line": 2}
	var decision := _handler._run_project_liveness_decision(
		_run_status("not_live", 3000),
		_errors_info([err], "retained_recent")
	)
	assert_eq(decision.resolve, true)
	assert_contains(decision.message, "may predate this run")
	assert_eq(decision.recent_errors_may_predate_run, true)


func test_run_project_liveness_decision_no_helper_resolves_running() -> void:
	var decision := _handler._run_project_liveness_decision(_run_status("no_helper", 3000), _errors_info())
	assert_eq(decision.resolve, true)
	assert_eq(decision.liveness_status, "no_helper")
	assert_contains(decision.message, "_mcp_game_helper")


func test_run_project_liveness_decision_stopped_resolves_stop_race() -> void:
	var decision := _handler._run_project_liveness_decision(_run_status("stopped", 250), _errors_info())
	assert_eq(decision.resolve, true)
	assert_eq(decision.liveness_status, "stopped")
	assert_contains(decision.message, "stopped")


func test_run_project_response_carries_liveness_shape() -> void:
	var base := {
		"mode": "main",
		"scene": "",
		"autosave": true,
		"was_already_running": false,
		"undoable": false,
		"reason": "Play/stop is a runtime action",
	}
	var decision := _handler._run_project_liveness_decision(_run_status("live", 100), _errors_info())
	var response := _handler._run_project_response(base, decision)
	assert_has_key(response.data, "game_status")
	assert_eq(response.data.game_status.status, "live")
	assert_eq(response.data.game_status.helper_live, true)
	assert_eq(response.data.game_status.session_active, true)
	assert_eq(response.data.helper_live, true)
	assert_eq(response.data.session_active, true)
	assert_false(response.data.has("liveness_status"), "public response uses game_status.status")
	assert_false(response.data.has("game_live"), "public response uses helper_live")
	assert_has_key(response.data, "recent_errors")


func test_run_project_response_splits_run_scoped_errors() -> void:
	var base := _handler._run_project_base_data(
		"main",
		"",
		true,
		false,
		"Play/stop is a runtime action"
	)
	var err := {"text": "Parse Error: Fresh", "path": "res://fresh.gd", "line": 3}
	var decision := _handler._run_project_liveness_decision(
		_run_status("not_live", 3000),
		_errors_info([err], "run")
	)
	var response := _handler._run_project_response(base, decision)

	assert_eq(response.data.recent_errors_scope, "run")
	assert_eq(response.data.current_run_errors, [err])
	assert_eq(response.data.retained_errors, [])


func test_run_project_response_splits_retained_errors() -> void:
	var base := _handler._run_project_base_data(
		"main",
		"",
		true,
		false,
		"Play/stop is a runtime action"
	)
	var err := {"text": "Parse Error: Old", "path": "res://old.gd", "line": 2}
	var decision := _handler._run_project_liveness_decision(
		_run_status("not_live", 3000),
		_errors_info([err], "retained_recent")
	)
	var response := _handler._run_project_response(base, decision)

	assert_eq(response.data.recent_errors_scope, "retained_recent")
	assert_eq(response.data.current_run_errors, [])
	assert_eq(response.data.retained_errors, [err])


func test_run_project_response_carries_liveness_shape_when_already_running() -> void:
	var base := _handler._run_project_base_data(
		"main",
		"",
		true,
		true,
		"Project was already running; no action taken"
	)
	var decision := _handler._run_project_liveness_decision(_run_status("live", 100), _errors_info())
	var response := _handler._run_project_response(base, decision)
	assert_eq(response.data.was_already_running, true)
	assert_has_key(response.data, "game_status")
	assert_eq(response.data.game_status.status, "live")
	assert_eq(response.data.game_status.helper_live, true)
	assert_eq(response.data.game_status.session_active, true)
	assert_eq(response.data.helper_live, true)
	assert_eq(response.data.session_active, true)
	assert_eq(response.data.reason, "Project was already running; the Godot AI game helper is live.")


# ----- stop_project -----

func test_stop_project_idempotent_when_not_playing() -> void:
	## Telemetry: 87 unique installs/day hit INVALID_PARAMS on
	## project_manage(op="stop") because the plugin rejected stop-when-not-running.
	## Calling stop to ensure the project is stopped is a valid intent; the
	## handler now returns success with was_running=false instead of erroring.
	var result := _handler.stop_project({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "stopped")
	assert_eq(result.data.stopped, true)
	assert_has_key(result.data, "was_running")
	assert_eq(result.data.was_running, false)


## NOTE: run_project's was_already_running branch can't be exercised here —
## actually starting playback from the editor test runner would re-enter the
## test loop. End-to-end coverage of that branch lives in the Python integration
## tests. The success/validation paths are covered by the run_project tests above.
