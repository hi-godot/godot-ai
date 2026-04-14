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
		return
	## Find the first Node3D child to use as a test target
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		return
	var dupe_target := target_path + "," + target_path
	var result := _handler.take_screenshot({"source": "viewport", "view_target": dupe_target})
	if result.has("data"):
		assert_eq(result.data.view_target_count, 1, "Duplicate paths should resolve to 1 target")


func test_screenshot_view_target_single_path_unchanged() -> void:
	## Single-path input should still work as before.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path})
	if result.has("data"):
		assert_has_key(result.data, "view_target")
		assert_has_key(result.data, "view_target_count")
		assert_eq(result.data.view_target_count, 1)


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


func test_screenshot_with_max_resolution() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "max_resolution": 64})
	if result.has("data"):
		assert_true(result.data.width <= 64, "Width should be <= max_resolution")
		assert_true(result.data.height <= 64, "Height should be <= max_resolution")


func test_screenshot_coverage_without_view_target() -> void:
	## coverage=true but no view_target → normal single-shot, no 'images' key
	var result := _handler.take_screenshot({"source": "viewport", "coverage": true})
	if result.has("data"):
		assert_true(not result.data.has("images"), "Should not have images array without view_target")
		assert_has_key(result.data, "image_base64")


func test_screenshot_coverage_with_view_target() -> void:
	## coverage=true with a valid target → images array + AABB metadata.
	## Prefer a Node3D with visible geometry so the ortho shot has content;
	## fall back to any Node3D if no preferred target is present.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
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


func test_screenshot_view_target_has_aabb_metadata() -> void:
	## Any view_target screenshot should include AABB geometry metadata
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path})
	if result.has("data"):
		assert_has_key(result.data, "aabb_center")
		assert_has_key(result.data, "aabb_size")
		assert_has_key(result.data, "aabb_longest_ground_axis")


func test_screenshot_custom_angles() -> void:
	## Explicit elevation/azimuth with valid target → single image with those angles
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path, "elevation": 45.0, "azimuth": 90.0})
	if result.has("data"):
		assert_has_key(result.data, "elevation")
		assert_has_key(result.data, "azimuth")
		assert_eq(result.data.elevation, 45.0, "Elevation should match requested")
		assert_eq(result.data.azimuth, 90.0, "Azimuth should match requested")
		assert_has_key(result.data, "image_base64")


func test_screenshot_custom_fov() -> void:
	## Explicit fov with valid target → single image with fov in response
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var target_path := ""
	for child in scene_root.get_children():
		if child is Node3D:
			target_path = ScenePath.from_node(child, scene_root)
			break
	if target_path.is_empty():
		return
	var result := _handler.take_screenshot({"source": "viewport", "view_target": target_path, "fov": 30.0})
	if result.has("data"):
		assert_has_key(result.data, "fov")
		assert_eq(result.data.fov, 30.0, "FOV should match requested")
		assert_has_key(result.data, "image_base64")


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
