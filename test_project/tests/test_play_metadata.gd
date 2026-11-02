@tool
extends McpTestSuite

const StubSessionPlugin := preload("res://tests/stub_debugger_session_plugin.gd")
const GameHelper := preload("res://addons/godot_ai/runtime/game_helper.gd")


func suite_name() -> String:
	return "play_metadata"


func test_mcp_origin_elapsed_and_stopped_state() -> void:
	var plugin := StubSessionPlugin.new()
	assert_eq(plugin.get_game_status().started_by, null)
	plugin.begin_game_run()
	var started := plugin.get_game_status(plugin._game_run_started_msec + 2500)
	assert_eq(started.started_by, "mcp")
	assert_eq(started.elapsed_s, 2.5)
	assert_gt(started.started_at, 0.0)
	assert_eq(started.last_input_age_s, null)
	plugin.note_editor_play_started()
	assert_eq(plugin.get_game_status().started_by, "mcp", "play-state edge must not relabel MCP run")
	plugin.end_game_run()
	var stopped := plugin.get_game_status()
	assert_eq(stopped.started_by, null)
	assert_eq(stopped.started_at, null)
	assert_eq(stopped.elapsed_s, 0.0)
	assert_eq(stopped.last_input_age_s, null)


func test_editor_origin_survives_early_helper_beacon() -> void:
	var plugin := StubSessionPlugin.new()
	plugin._setup_session(72)
	plugin._capture("mcp:hello", [], 72)
	plugin.note_editor_play_started()
	var status := plugin.get_game_status()
	assert_eq(status.started_by, "editor")
	assert_eq(status.status, "live")
	var token: int = status.run_token
	plugin.note_editor_play_started()
	assert_eq(plugin.get_game_status().run_token, token)
	plugin.end_game_run()
	plugin.begin_game_run()
	assert_eq(plugin.get_game_status().started_by, "mcp")


func test_input_age_is_session_bound_and_cleared_per_run() -> void:
	var plugin := StubSessionPlugin.new()
	plugin.begin_game_run()
	plugin._setup_session(72)
	plugin._capture("mcp:input_activity", [1000], 72)
	assert_eq(plugin.get_game_status().last_input_age_s, null, "no sample accepted before helper hello")
	plugin._capture("mcp:hello", [], 72)
	for value in [[], [-1], ["1000"], [1000.0], [true], [1000, 1]]:
		plugin._capture("mcp:input_activity", value, 72)
		assert_eq(plugin.get_game_status().last_input_age_s, null)
	plugin._capture("mcp:input_activity", [1000], 73)
	assert_eq(plugin.get_game_status().last_input_age_s, null, "foreign session cannot supply input metadata")
	plugin._capture("mcp:input_activity", [3000], 72)
	var status := plugin.get_game_status(plugin._input_sample_received_msec + 1500)
	assert_eq(status.last_input_age_s, 4.5)
	assert_eq(status.input_sample_age_s, 1.5)
	plugin.end_game_run()
	plugin._capture("mcp:input_activity", [0], 72)
	assert_eq(plugin.get_game_status().last_input_age_s, null)
	plugin.begin_game_run()
	assert_eq(plugin.get_game_status().last_input_age_s, null)


func test_helper_records_events_without_collecting_input_content() -> void:
	var helper := GameHelper.new()
	helper._last_input_msec = -1
	var event := InputEventKey.new()
	event.keycode = KEY_A
	helper._input(event)
	assert_true(helper._last_input_msec >= 0)
	assert_eq(helper._input_age_msec(helper._last_input_msec + 1234), 1234)
	var before: int = helper._last_input_msec
	event.set_meta(GameHelper.MCP_INJECTED_INPUT, true)
	helper._input(event)
	assert_eq(helper._last_input_msec, before, "MCP-injected events must not reset the idle clock")
	helper.free()
