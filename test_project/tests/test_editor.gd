@tool
extends McpTestSuite

## Tests for EditorHandler — editor state, selection, and logs.

var _handler: EditorHandler


func suite_name() -> String:
	return "editor"


func suite_setup(ctx: Dictionary) -> void:
	var log_buffer: McpLogBuffer = ctx.get("log_buffer")
	if log_buffer == null:
		log_buffer = McpLogBuffer.new()
	_handler = EditorHandler.new(log_buffer)


# ----- get_editor_state -----

func test_editor_state_has_version() -> void:
	var result := _handler.get_editor_state({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "godot_version")
	assert_ne(result.data.godot_version, "", "Version should not be empty")


func test_editor_state_has_project_name() -> void:
	var result := _handler.get_editor_state({})
	assert_has_key(result.data, "project_name")


func test_editor_state_has_scene() -> void:
	var result := _handler.get_editor_state({})
	assert_has_key(result.data, "current_scene")
	assert_contains(result.data.current_scene, "main.tscn", "Should have main.tscn open")


func test_editor_state_has_play_status() -> void:
	var result := _handler.get_editor_state({})
	assert_has_key(result.data, "is_playing")


# ----- get_selection -----

func test_selection_returns_data() -> void:
	var result := _handler.get_selection({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "selected_paths")
	assert_has_key(result.data, "count")
	assert_true(result.data.selected_paths is Array, "selected_paths should be Array")


# ----- get_logs -----

func test_logs_returns_lines() -> void:
	var result := _handler.get_logs({"count": 10})
	assert_has_key(result, "data")
	assert_has_key(result.data, "lines")
	assert_has_key(result.data, "total_count")
	assert_has_key(result.data, "returned_count")


func test_logs_respects_count() -> void:
	var result := _handler.get_logs({"count": 1})
	assert_true(result.data.returned_count <= 1, "Should return at most 1 line")


# ----- clear_logs -----

func test_clear_logs_returns_count() -> void:
	var result := _handler.clear_logs({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "cleared_count")


func test_clear_logs_empties_buffer() -> void:
	## Log some lines, clear, then verify empty
	var buf := McpLogBuffer.new()
	buf.log("test line 1")
	buf.log("test line 2")
	var handler := EditorHandler.new(buf)
	var result := handler.clear_logs({})
	assert_eq(result.data.cleared_count, 2)
	assert_eq(buf.total_count(), 0)


# ----- get_performance_monitors -----

# ----- take_screenshot -----

func test_screenshot_invalid_source() -> void:
	var result := _handler.take_screenshot({"source": "invalid"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_screenshot_game_not_playing() -> void:
	var result := _handler.take_screenshot({"source": "game"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_debugger_plugin_capture_prefix() -> void:
	var plugin := McpDebuggerPlugin.new()
	assert_true(plugin._has_capture("mcp"), "Should accept 'mcp' prefix")
	assert_true(not plugin._has_capture("foo"), "Should reject other prefixes")


func test_debugger_plugin_ignores_unknown_messages() -> void:
	var plugin := McpDebuggerPlugin.new()
	assert_true(not plugin._capture("mcp:not_a_real_message", [], 0), "Unknown mcp message returns false")


func test_debugger_plugin_screenshot_error_unknown_request() -> void:
	## _on_screenshot_error for an unknown request_id must silently drop
	## (the request already timed out or was reaped) without crashing.
	var plugin := McpDebuggerPlugin.new()
	plugin._on_screenshot_error(["unknown-id", "whatever"])
	assert_true(true, "No crash when replying to unknown request_id")


func test_screenshot_view_target_not_found() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "view_target": "/Main/NonExistent"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_screenshot_view_target_all_invalid_comma() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "view_target": "/Main/X,/Main/Y"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_screenshot_view_target_duplicates() -> void:
	## Duplicate paths should be deduplicated — only one target resolved.
	## We can't easily assert view_target_count without a real Node3D in the
	## scene, so verify the dedup path doesn't error on a valid single node.
	## Use a known node from main.tscn.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	## Find the first Node3D child to use as a test target
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var dupe_target := target_path + "," + target_path
	var result := _handler.take_screenshot({"source": "viewport", "view_target": dupe_target})
	if result.has("data"):
		assert_eq(result.data.view_target_count, 1, "Duplicate paths should resolve to 1 target")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_view_target_single_path_unchanged() -> void:
	## Single-path input should still work as before.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path})
	if result.has("data"):
		assert_has_key(result.data, "view_target")
		assert_has_key(result.data, "view_target_count")
		assert_eq(result.data.view_target_count, 1)
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_viewport_returns_image() -> void:
	var result := _handler.take_screenshot({"source": "viewport"})
	## This should succeed if a 3D viewport is available in the editor
	if result.has("data"):
		assert_has_key(result.data, "image_base64")
		assert_has_key(result.data, "width")
		assert_has_key(result.data, "height")
		assert_has_key(result.data, "source")
		assert_eq(result.data.source, "viewport")
		assert_eq(result.data.format, "png")
		assert_gt(result.data.width, 0, "Width should be positive")
		assert_gt(result.data.height, 0, "Height should be positive")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_with_max_resolution() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "max_resolution": 64})
	if result.has("data"):
		assert_true(result.data.width <= 64, "Width should be <= max_resolution")
		assert_true(result.data.height <= 64, "Height should be <= max_resolution")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_coverage_without_view_target() -> void:
	## coverage=true but no view_target → normal single-shot, no 'images' key
	var result := _handler.take_screenshot({"source": "viewport", "coverage": true})
	if result.has("data"):
		assert_true(not result.data.has("images"), "Should not have images array without view_target")
		assert_has_key(result.data, "image_base64")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_coverage_with_view_target() -> void:
	## coverage=true with a valid target → images array + AABB metadata.
	## Prefer a Node3D with visible geometry so the ortho shot has content;
	## fall back to any Node3D if no preferred target is present.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var target_path := ""
	var preferred := scene_root.get_node_or_null("SnowGroup")
	if preferred != null and preferred is Node3D:
		target_path = ScenePath.from_node(preferred, scene_root)
	else:
		for child in scene_root.get_children():
			if child is Node3D:
				target_path = ScenePath.from_node(child, scene_root)
				break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path, "coverage": true})
	if result.has("data"):
		assert_eq(result.data.coverage, true, "Should have coverage=true")
		assert_has_key(result.data, "images")
		assert_eq(result.data.images.size(), 2, "Should have 2 coverage images")
		## Verify geometry-informed labels
		assert_eq(result.data.images[0].label, "establishing")
		assert_eq(result.data.images[1].label, "top")
		for img in result.data.images:
			assert_has_key(img, "elevation")
			assert_has_key(img, "azimuth")
			assert_has_key(img, "fov")
			assert_has_key(img, "image_base64")
		## Verify AABB metadata
		assert_has_key(result.data, "aabb_center")
		assert_has_key(result.data, "aabb_size")
		assert_has_key(result.data, "aabb_longest_ground_axis")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_view_target_has_aabb_metadata() -> void:
	## Any view_target screenshot should include AABB geometry metadata
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path})
	if result.has("data"):
		assert_has_key(result.data, "aabb_center")
		assert_has_key(result.data, "aabb_size")
		assert_has_key(result.data, "aabb_longest_ground_axis")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_custom_angles() -> void:
	## Explicit elevation/azimuth with valid target → single image with those angles
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path, "elevation": 45.0, "azimuth": 90.0})
	if result.has("data"):
		assert_has_key(result.data, "elevation")
		assert_has_key(result.data, "azimuth")
		assert_eq(result.data.elevation, 45.0, "Elevation should match requested")
		assert_eq(result.data.azimuth, 90.0, "Azimuth should match requested")
		assert_has_key(result.data, "image_base64")
	else:
		skip("Viewport not available in headless mode")


func test_screenshot_custom_fov() -> void:
	## Explicit fov with valid target → single image with fov in response
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		skip("No Node3D target found in scene")
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path, "fov": 30.0})
	if result.has("data"):
		assert_has_key(result.data, "fov")
		assert_eq(result.data.fov, 30.0, "FOV should match requested")
		assert_has_key(result.data, "image_base64")
	else:
		skip("Viewport not available in headless mode")


# ----- get_performance_monitors -----

func test_performance_monitors_returns_all() -> void:
	var result := _handler.get_performance_monitors({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "monitors")
	assert_has_key(result.data, "monitor_count")
	assert_gt(result.data.monitor_count, 0, "Should return at least one monitor")
	assert_has_key(result.data.monitors, "time/fps")


func test_performance_monitors_filtered() -> void:
	var result := _handler.get_performance_monitors({"monitors": ["time/fps", "object/count"]})
	assert_has_key(result, "data")
	assert_eq(result.data.monitor_count, 2)
	assert_has_key(result.data.monitors, "time/fps")
	assert_has_key(result.data.monitors, "object/count")


func test_performance_monitors_unknown_filtered_out() -> void:
	var result := _handler.get_performance_monitors({"monitors": ["time/fps", "fake/monitor"]})
	assert_eq(result.data.monitor_count, 1)
	assert_has_key(result.data.monitors, "time/fps")


# ----- Friction fix: screenshot source="game" -----

func test_screenshot_game_not_running_returns_error() -> void:
	# When the game is not running, source="game" should return an error.
	if EditorInterface.is_playing_scene():
		return  # Can't test this path while game is running.
	var result := _handler.take_screenshot({"source": "game"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not running")


func test_screenshot_bogus_source() -> void:
	var result := _handler.take_screenshot({"source": "bogus"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Invalid source")


# ----- GameLogBuffer (issue #73) -----

func test_game_log_buffer_append_and_get_range() -> void:
	var buf := GameLogBuffer.new()
	buf.append("info", "hello")
	buf.append("warn", "almost out of fuel")
	buf.append("error", "boom")
	var entries := buf.get_range(0, 10)
	assert_eq(entries.size(), 3)
	assert_eq(entries[0].source, "game")
	assert_eq(entries[0].level, "info")
	assert_eq(entries[0].text, "hello")
	assert_eq(entries[1].level, "warn")
	assert_eq(entries[2].level, "error")
	assert_eq(buf.total_count(), 3)


func test_game_log_buffer_get_range_offset_and_count() -> void:
	var buf := GameLogBuffer.new()
	for i in range(5):
		buf.append("info", "line %d" % i)
	var page := buf.get_range(2, 2)
	assert_eq(page.size(), 2)
	assert_eq(page[0].text, "line 2")
	assert_eq(page[1].text, "line 3")


func test_game_log_buffer_unknown_level_coerces_to_info() -> void:
	var buf := GameLogBuffer.new()
	buf.append("not-a-level", "weird")
	var entries := buf.get_range(0, 10)
	assert_eq(entries[0].level, "info", "Unknown level should coerce to info")


func test_game_log_buffer_ring_evicts_and_tracks_dropped() -> void:
	var buf := GameLogBuffer.new()
	var cap := GameLogBuffer.MAX_LINES
	for i in range(cap + 5):
		buf.append("info", "n %d" % i)
	assert_eq(buf.total_count(), cap, "Buffer should cap at MAX_LINES")
	assert_eq(buf.dropped_count(), 5, "Should record 5 evictions")
	## Oldest 5 dropped: first remaining entry should be index 5.
	var first := buf.get_range(0, 1)
	assert_eq(first[0].text, "n 5")


func test_game_log_buffer_clear_for_new_run_rotates_run_id() -> void:
	var buf := GameLogBuffer.new()
	buf.append("info", "before")
	## Time.get_ticks_msec changes between calls — guarantees distinct ids.
	var first_id := buf.clear_for_new_run()
	assert_ne(first_id, "", "Initial clear should return a non-empty run id")
	assert_eq(buf.total_count(), 0, "Buffer should be empty after clear")
	OS.delay_msec(2)
	buf.append("info", "after")
	var second_id := buf.clear_for_new_run()
	assert_ne(first_id, second_id, "Each clear should rotate the run id")
	assert_eq(buf.dropped_count(), 0, "dropped_count resets on new run")


func test_game_log_buffer_preserves_order_after_multiple_wraps() -> void:
	## Post O(1)-circular-buffer rewrite: verify that two full wraps still
	## leave entries in correct logical order, and that get_range across the
	## wrap boundary doesn't return the physical-slot order by mistake.
	var buf := GameLogBuffer.new()
	var cap := GameLogBuffer.MAX_LINES
	## Fill cap, then wrap 1.5 times: total 2.5 * cap writes.
	var total := cap * 5 / 2
	for i in range(total):
		buf.append("info", "n %d" % i)
	assert_eq(buf.total_count(), cap, "Buffer caps at MAX_LINES after many wraps")
	assert_eq(buf.dropped_count(), total - cap, "dropped_count tracks every eviction")
	## Oldest retained entry should be the first one that survived the drop.
	var oldest := buf.get_range(0, 1)
	assert_eq(oldest[0].text, "n %d" % (total - cap), "Oldest is first post-drop entry")
	## Newest retained entry should be the last append.
	var newest := buf.get_range(cap - 1, 1)
	assert_eq(newest[0].text, "n %d" % (total - 1), "Newest is last append")
	## Sanity — logical ordering is contiguous across the physical wrap.
	var page := buf.get_range(0, cap)
	for i in range(cap):
		var expected := total - cap + i
		assert_eq(page[i].text, "n %d" % expected, "Entry %d should be 'n %d'" % [i, expected])


func test_game_log_buffer_get_recent_works_after_wrap() -> void:
	var buf := GameLogBuffer.new()
	var cap := GameLogBuffer.MAX_LINES
	for i in range(cap + 10):
		buf.append("info", "w %d" % i)
	var tail := buf.get_recent(3)
	assert_eq(tail.size(), 3)
	assert_eq(tail[0].text, "w %d" % (cap + 10 - 3))
	assert_eq(tail[1].text, "w %d" % (cap + 10 - 2))
	assert_eq(tail[2].text, "w %d" % (cap + 10 - 1))


# ----- get_logs source routing -----

func test_get_logs_source_invalid_returns_error() -> void:
	var result := _handler.get_logs({"source": "bogus"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Invalid source")


func test_get_logs_coerces_float_count_and_offset() -> void:
	## JSON numbers decode to float in Godot — make sure typed locals
	## don't blow up before the validator can report INVALID_PARAMS.
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("a")
	plugin_buf.log("b")
	plugin_buf.log("c")
	var handler := EditorHandler.new(plugin_buf)
	var result := handler.get_logs({"count": 2.0, "offset": 1.0, "source": "plugin"})
	assert_has_key(result, "data")
	assert_eq(result.data.lines.size(), 2)
	assert_contains(result.data.lines[0].text, "b")


func test_get_logs_negative_count_floored_to_zero() -> void:
	## maxi(0, ...) on count means a negative/garbage count returns an
	## empty page instead of crashing or returning negative-index junk.
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("only line")
	var handler := EditorHandler.new(plugin_buf)
	var result := handler.get_logs({"count": -5, "source": "plugin"})
	assert_has_key(result, "data")
	assert_eq(result.data.lines.size(), 0, "Negative count yields empty page")


func test_get_logs_null_source_falls_through_to_invalid() -> void:
	## Explicit null source after coercion becomes the string "<null>",
	## which fails the VALID_LOG_SOURCES check — user gets INVALID_PARAMS
	## rather than a GDScript type error.
	var handler := EditorHandler.new(McpLogBuffer.new())
	var result := handler.get_logs({"source": null})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Invalid source")


func test_get_logs_source_plugin_returns_structured_lines() -> void:
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("first")
	plugin_buf.log("second")
	var handler := EditorHandler.new(plugin_buf)
	var result := handler.get_logs({"source": "plugin", "count": 10})
	assert_has_key(result, "data")
	assert_eq(result.data.source, "plugin")
	assert_eq(result.data.lines.size(), 2)
	assert_eq(result.data.lines[0].source, "plugin")
	assert_eq(result.data.lines[0].level, "info")
	assert_contains(result.data.lines[0].text, "first")


func test_get_logs_source_game_empty_when_no_buffer() -> void:
	var handler := EditorHandler.new(McpLogBuffer.new())
	var result := handler.get_logs({"source": "game", "count": 10})
	assert_has_key(result, "data")
	assert_eq(result.data.source, "game")
	assert_eq(result.data.lines.size(), 0)
	assert_eq(result.data.run_id, "")
	assert_has_key(result.data, "is_running")
	assert_has_key(result.data, "dropped_count")


func test_get_logs_source_game_returns_buffered_entries() -> void:
	var game_buf := GameLogBuffer.new()
	game_buf.clear_for_new_run()
	game_buf.append("info", "spawned 12 blocks")
	game_buf.append("error", "null deref")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf)
	var result := handler.get_logs({"source": "game", "count": 10})
	assert_eq(result.data.source, "game")
	assert_eq(result.data.lines.size(), 2)
	assert_eq(result.data.lines[0].text, "spawned 12 blocks")
	assert_eq(result.data.lines[1].level, "error")
	assert_ne(result.data.run_id, "", "run_id should be set after clear_for_new_run")


func test_get_logs_source_game_offset_applies() -> void:
	var game_buf := GameLogBuffer.new()
	for i in range(5):
		game_buf.append("info", "g %d" % i)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf)
	var result := handler.get_logs({"source": "game", "count": 2, "offset": 2})
	assert_eq(result.data.returned_count, 2)
	assert_eq(result.data.lines[0].text, "g 2")
	assert_eq(result.data.lines[1].text, "g 3")
	assert_eq(result.data.offset, 2)
	assert_eq(result.data.total_count, 5)


func test_get_logs_source_all_includes_both_streams() -> void:
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("plugin-a")
	plugin_buf.log("plugin-b")
	var game_buf := GameLogBuffer.new()
	game_buf.append("warn", "game-c")
	var handler := EditorHandler.new(plugin_buf, null, null, game_buf)
	var result := handler.get_logs({"source": "all", "count": 10})
	assert_eq(result.data.source, "all")
	assert_eq(result.data.lines.size(), 3)
	## Plugin lines come first, then game.
	assert_eq(result.data.lines[0].source, "plugin")
	assert_eq(result.data.lines[1].source, "plugin")
	assert_eq(result.data.lines[2].source, "game")
	assert_eq(result.data.lines[2].level, "warn")
	assert_eq(result.data.lines[2].text, "game-c")


# ----- McpDebuggerPlugin: log batch capture (issue #73) -----

func test_debugger_plugin_log_batch_appends_to_buffer() -> void:
	var game_buf := GameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin._capture("mcp:log_batch", [[
		["info", "alpha"],
		["error", "beta"],
	]], 0)
	assert_eq(game_buf.total_count(), 2)
	var entries := game_buf.get_range(0, 10)
	assert_eq(entries[0].text, "alpha")
	assert_eq(entries[1].level, "error")


func test_debugger_plugin_hello_rotates_run_id() -> void:
	var game_buf := GameLogBuffer.new()
	game_buf.append("info", "stale from previous run")
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin._capture("mcp:hello", [], 0)
	assert_eq(game_buf.total_count(), 0, "hello should clear the game buffer")
	assert_ne(game_buf.run_id(), "", "hello should set a run_id")


func test_debugger_plugin_log_batch_no_buffer_is_safe() -> void:
	## Plugin started without a game buffer should silently no-op on
	## log batches rather than crash — defensive for partial init.
	var plugin := McpDebuggerPlugin.new(null, null)
	plugin._capture("mcp:log_batch", [[["info", "x"]]], 0)
	assert_true(true, "No crash when no game buffer is wired")


# ----- GameLogger._log_error arg routing (PR #78 smoke bug) -----

const _GAME_LOGGER_PATH := "res://addons/godot_ai/runtime/game_logger.gd"


func test_game_logger_single_arg_push_warning_preserves_user_message() -> void:
	## push_warning("warn-game") → code="warn-game", rationale="". The user's
	## message must survive; before the fix, rationale was the only source and
	## the text was discarded.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = load(_GAME_LOGGER_PATH).new()
	logger._log_error("push_warning", "core/variant/variant_utility.cpp", 1034, "warn-game", "", false, 1, [])
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_eq(pending[0][0], "warn")
	assert_contains(pending[0][1], "warn-game", "User's message text must survive single-arg push_warning")


func test_game_logger_single_arg_push_error_preserves_user_message() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = load(_GAME_LOGGER_PATH).new()
	logger._log_error("push_error", "core/variant/variant_utility.cpp", 1000, "err-game", "", false, 0, [])
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_eq(pending[0][0], "error")
	assert_contains(pending[0][1], "err-game", "User's message text must survive single-arg push_error")


func test_game_logger_two_arg_push_error_prefers_rationale() -> void:
	## push_error(code, rationale) — rationale wins, code is not surfaced.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = load(_GAME_LOGGER_PATH).new()
	logger._log_error("my_func", "res://foo.gd", 42, "ERR_CODE", "detailed reason", false, 0, [])
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_eq(pending[0][0], "error")
	assert_contains(pending[0][1], "detailed reason", "Rationale should be used when present")
	assert_true(not pending[0][1].contains("ERR_CODE"), "Code should not appear when rationale is present")


func test_game_logger_printerr_routes_to_error_level() -> void:
	## _log_message is the print/printerr channel — sanity-check it still works.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = load(_GAME_LOGGER_PATH).new()
	logger._log_message("oops", true)
	logger._log_message("hi", false)
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 2)
	assert_eq(pending[0][0], "error")
	assert_eq(pending[0][1], "oops")
	assert_eq(pending[1][0], "info")
	assert_eq(pending[1][1], "hi")
