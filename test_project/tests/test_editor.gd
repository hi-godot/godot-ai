@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const DiagnosticsCapture := preload("res://addons/godot_ai/utils/diagnostics_capture.gd")
const EditorHandler := preload("res://addons/godot_ai/handlers/editor_handler.gd")
const StubBacktrace := preload("res://addons/godot_ai/testing/stub_backtrace.gd")

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


func test_editor_state_game_capture_ready_false_without_debugger_plugin() -> void:
	## Default _handler has no debugger plugin injected — field must still be
	## present and false so callers can poll unconditionally.
	var result := _handler.get_editor_state({})
	assert_has_key(result.data, "game_capture_ready")
	assert_eq(result.data.game_capture_ready, false)


func test_editor_state_game_capture_ready_tracks_debugger_plugin_flag() -> void:
	var plugin := McpDebuggerPlugin.new()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, plugin)
	var result := handler.get_editor_state({})
	assert_eq(result.data.game_capture_ready, false, "starts false before mcp:hello")
	plugin.begin_game_run()
	plugin._setup_session(101)
	plugin._capture("mcp:hello", [], 101)
	result = handler.get_editor_state({})
	assert_eq(result.data.game_capture_ready, true, "flips true once beacon arrives")
	plugin.begin_game_run()
	result = handler.get_editor_state({})
	assert_eq(result.data.game_capture_ready, false, "new project_run clears stale readiness immediately")


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


func test_clear_logs_leaves_debugger_errors_tree_by_default() -> void:
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, tree)
	var result := handler.clear_logs({})
	assert_eq(result.data.cleared_count, 0)
	assert_false(result.data.has("debugger_errors_cleared"), "Errors-tab clear is opt-in")
	var logs := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(logs.data.total_count, 2, "Visible Errors rows must survive a default clear_logs")
	tree.free()


func test_clear_logs_clears_debugger_errors_tree_on_opt_in() -> void:
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, tree)
	var result := handler.clear_logs({"clear_debugger_errors": true})
	assert_eq(result.data.cleared_count, 0)
	assert_eq(result.data.debugger_errors_cleared, 2)
	var logs := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(logs.data.total_count, 0)
	tree.free()


class DebuggerClearStub:
	extends RefCounted
	var tree: Tree
	var pressed_count := 0

	func _clear_errors_list() -> void:
		pressed_count += 1
		tree.clear()


func test_clear_logs_routes_through_debugger_clear_button() -> void:
	## The real Errors panel must be cleared via its own Clear button so the
	## engine resets error_count/warning_count, the tab badge, and button
	## states — model the panel as button + tree under one container and
	## assert the button's pressed path ran instead of a raw Tree.clear().
	var panel := VBoxContainer.new()
	var toolbar := HBoxContainer.new()
	panel.add_child(toolbar)
	var clear_button := Button.new()
	toolbar.add_child(clear_button)
	var tree := _make_debugger_errors_tree()
	panel.add_child(tree)
	var stub := DebuggerClearStub.new()
	stub.tree = tree
	clear_button.pressed.connect(stub._clear_errors_list)

	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, panel)
	var result := handler.clear_logs({"clear_debugger_errors": true})
	assert_eq(result.data.debugger_errors_cleared, 2)
	assert_eq(stub.pressed_count, 1, "Clear must go through the panel's own Clear button")
	assert_true(tree.get_root() == null, "Button handler should have emptied the tree")
	panel.free()


# ----- get_performance_monitors -----

# ----- take_screenshot -----

func test_screenshot_invalid_source() -> void:
	var result := _handler.take_screenshot({"source": "invalid"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_screenshot_game_not_playing() -> void:
	var result := _handler.take_screenshot({"source": "game"})
	assert_is_error(result)


# ----- game_command -----

func test_game_command_missing_op() -> void:
	var result := _handler.game_command({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_game_command_not_playing() -> void:
	var plugin := McpDebuggerPlugin.new()
	var handler := EditorHandler.new(McpLogBuffer.new(), McpConnection.new(), plugin)
	var result := handler.game_command({"op": "get_scene_tree"})
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)


func test_debugger_plugin_game_command_response_unknown_request() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin._on_game_command_response(["unknown-id", "{\"ok\":true}"])
	assert_true(true, "Unknown responses should be ignored without crashing")


# ----- viewport_screenshot_precheck (#456: stop returning INTERNAL_ERROR on 2D) -----

func test_viewport_precheck_passes_for_node3d_root() -> void:
	## Happy path: scene_root is Node3D, precheck returns empty dict so
	## take_screenshot falls through to its normal capture path.
	var root := Node3D.new()
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_eq(result, {}, "Node3D root should return {} (no error)")


func test_viewport_precheck_rejects_node2d_root() -> void:
	var root := Node2D.new()
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_has_key(result.error, "data")
	assert_eq(result.error.data.editor_state, "viewport_not_3d")
	assert_eq(result.error.data.scene_root_type, "Node2D")
	## The message must mention the 2D nature, cinematic alternative, and
	## scene_get_hierarchy so the LLM can actually act on it.
	assert_contains(result.error.message, "Node2D")
	assert_contains(result.error.message, "cinematic")
	assert_contains(result.error.message, "scene_get_hierarchy")


func test_viewport_precheck_rejects_control_root() -> void:
	var root := Control.new()
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(result.error.data.editor_state, "viewport_not_3d")
	assert_eq(result.error.data.scene_root_type, "Control")


func test_viewport_precheck_rejects_plain_node_root_with_no_3d_descendants() -> void:
	## A scene rooted at a plain Node with no Node3D anywhere in the tree
	## leaves the 3D viewport empty — reject with the generic non-3D hint.
	var root := Node.new()
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(result.error.data.editor_state, "viewport_not_3d")
	assert_eq(result.error.data.scene_root_type, "Node")
	assert_contains(result.error.message, "no Node3D content")


func test_viewport_precheck_passes_for_plain_node_root_with_3d_descendant() -> void:
	## Common pattern: scene root is a plain Node (or scene-organizing
	## wrapper) with a Node3D child. The 3D viewport CAN render the
	## descendant, so don't reject.
	var root := Node.new()
	var child := Node3D.new()
	root.add_child(child)
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_eq(result, {}, "plain Node root with Node3D descendant should pass")


func test_viewport_precheck_passes_for_node2d_root_with_3d_descendant() -> void:
	## Less common but valid: a Node2D root containing a Node3D descendant
	## (e.g. a UI scene that embeds a 3D preview). The 3D viewport has
	## content to render — don't reject on root type alone.
	var root := Node2D.new()
	var child := Node3D.new()
	root.add_child(child)
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_eq(result, {}, "Node2D root with Node3D descendant should pass")


func test_viewport_precheck_rejects_node2d_root_with_only_2d_descendants() -> void:
	## A Node2D scene with only Node2D / Control descendants still has
	## no 3D content. Must reject (the original 2D-scene problem).
	var root := Node2D.new()
	var child := Sprite2D.new()
	root.add_child(child)
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(result.error.data.editor_state, "viewport_not_3d")
	assert_eq(result.error.data.scene_root_type, "Node2D")


func test_viewport_precheck_walks_deep_descendants() -> void:
	## DFS must reach Node3D content nested multiple levels deep, not
	## just direct children.
	var root := Node.new()
	var mid := Node.new()
	var deep := Node3D.new()
	root.add_child(mid)
	mid.add_child(deep)
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_eq(result, {}, "deeply-nested Node3D should be discovered")


func test_viewport_precheck_rejects_null_scene() -> void:
	var result := EditorHandler.viewport_screenshot_precheck(null)
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(result.error.data.editor_state, "viewport_not_3d")
	assert_eq(result.error.data.scene_root_type, "")
	assert_contains(result.error.message, "no scene is open")


func test_viewport_precheck_passes_for_node3d_subclass() -> void:
	## Camera3D extends Node3D — a scene rooted at any Node3D subclass
	## should pass the precheck (the 3D viewport will render it).
	var root := Camera3D.new()
	var result := EditorHandler.viewport_screenshot_precheck(root)
	root.free()
	assert_eq(result, {}, "Node3D subclass root should pass")


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


func test_debugger_plugin_clear_pending_disconnects_timer() -> void:
	## Audit blind spot from #297: on screenshot success, _clear_pending used
	## to only erase the dict entry, leaving the SceneTreeTimer + bound
	## timeout lambda alive until the timer naturally fired (up to 8s).
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		skip("No SceneTree available")
		return
	var plugin := McpDebuggerPlugin.new()
	var rid := "rid-clear-pending"
	var cb := func() -> void: pass
	var timer := tree.create_timer(60.0)
	timer.timeout.connect(cb)
	plugin._pending[rid] = {
		"connection": null,
		"timer": timer,
		"timeout_callable": cb,
	}
	assert_true(timer.timeout.is_connected(cb), "precondition: timer connected before clear")
	plugin._clear_pending(rid)
	assert_false(plugin._pending.has(rid), "_clear_pending should erase the request entry")
	assert_false(timer.timeout.is_connected(cb), "_clear_pending should disconnect timeout signal")


func test_screenshot_view_target_not_found() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "view_target": "/Main/NonExistent"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_screenshot_view_target_all_invalid_comma() -> void:
	var result := _handler.take_screenshot({"source": "viewport", "view_target": "/Main/X,/Main/Y"})
	assert_is_error(result)


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
			target_path = McpScenePath.from_node(child, scene_root)
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
			target_path = McpScenePath.from_node(child, scene_root)
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
		target_path = McpScenePath.from_node(preferred, scene_root)
	else:
		for child in scene_root.get_children():
			if child is Node3D:
				target_path = McpScenePath.from_node(child, scene_root)
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
			target_path = McpScenePath.from_node(child, scene_root)
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
			target_path = McpScenePath.from_node(child, scene_root)
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
			target_path = McpScenePath.from_node(child, scene_root)
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
	assert_is_error(result)
	assert_contains(result.error.message, "not running")


func test_screenshot_bogus_source() -> void:
	var result := _handler.take_screenshot({"source": "bogus"})
	assert_is_error(result)
	assert_contains(result.error.message, "Invalid source")


# ----- source="cinematic" (issue #143) -----

func test_screenshot_cinematic_no_camera_returns_error() -> void:
	## Main scene has a camera in most configurations; this path only runs
	## when a cameraless scene happens to be open. Acceptance: INVALID_PARAMS
	## with a descriptive message, not a silent fallback.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var cameras := _collect_cameras(scene_root)
	if cameras.is_empty():
		## Scene already has no cameras — exercise directly.
		var result := _handler.take_screenshot({"source": "cinematic"})
		assert_is_error(result)
		assert_contains(result.error.message, "No current Camera3D")
		return
	skip("Scene has cameras — no-camera branch covered only in cameraless scenes")


func test_screenshot_cinematic_returns_image() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var cameras := _collect_cameras(scene_root)
	if cameras.is_empty():
		skip("No Camera3D in scene to render from")
		return
	var result := _handler.take_screenshot({"source": "cinematic"})
	if not result.has("data"):
		skip("Cinematic render not available in headless mode")
		return
	assert_eq(result.data.source, "cinematic")
	assert_eq(result.data.format, "png")
	assert_gt(result.data.width, 0, "Width should be positive")
	assert_gt(result.data.height, 0, "Height should be positive")
	assert_has_key(result.data, "image_base64")
	assert_gt(result.data.image_base64.length(), 0, "PNG payload should be non-empty")
	assert_has_key(result.data, "camera_path")
	assert_true(result.data.camera_path.begins_with("/"), "camera_path should be scene-rooted")


func test_screenshot_cinematic_prefers_current_camera() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var cameras := _collect_cameras(scene_root)
	if cameras.size() < 2:
		skip("Need ≥2 Camera3Ds to verify `current` preference")
		return
	## Temporarily mark the last camera as current and verify it wins over
	## the first (which would be returned by the fallback order).
	var prior_current: Camera3D = null
	for cam in cameras:
		if cam.current:
			prior_current = cam
			cam.current = false
	var chosen: Camera3D = cameras[cameras.size() - 1]
	chosen.current = true
	var result := _handler.take_screenshot({"source": "cinematic"})
	chosen.current = false
	if prior_current != null:
		prior_current.current = true
	if not result.has("data"):
		skip("Cinematic render not available in headless mode")
		return
	var expected := McpScenePath.from_node(chosen, scene_root)
	assert_eq(result.data.camera_path, expected)


func test_screenshot_cinematic_respects_max_resolution() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	if _collect_cameras(scene_root).is_empty():
		skip("No Camera3D in scene to render from")
		return
	var result := _handler.take_screenshot({"source": "cinematic", "max_resolution": 64})
	if not result.has("data"):
		skip("Cinematic render not available in headless mode")
		return
	assert_true(result.data.width <= 64, "Width should be <= max_resolution")
	assert_true(result.data.height <= 64, "Height should be <= max_resolution")


func _collect_cameras(root: Node) -> Array[Camera3D]:
	var out: Array[Camera3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Camera3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# ----- McpGameLogBuffer (issue #73) -----

func test_game_log_buffer_append_and_get_range() -> void:
	var buf := McpGameLogBuffer.new()
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
	var buf := McpGameLogBuffer.new()
	for i in range(5):
		buf.append("info", "line %d" % i)
	var page := buf.get_range(2, 2)
	assert_eq(page.size(), 2)
	assert_eq(page[0].text, "line 2")
	assert_eq(page[1].text, "line 3")


func test_game_log_buffer_unknown_level_coerces_to_info() -> void:
	var buf := McpGameLogBuffer.new()
	buf.append("not-a-level", "weird")
	var entries := buf.get_range(0, 10)
	assert_eq(entries[0].level, "info", "Unknown level should coerce to info")


func test_game_log_buffer_preserves_details() -> void:
	var buf := McpGameLogBuffer.new()
	buf.append("error", "boom", {
		"code": "boom",
		"frames": [{"path": "res://player.gd", "line": 8, "function": "_ready"}],
	})
	var entries := buf.get_range(0, 10)
	assert_has_key(entries[0], "details")
	assert_eq(entries[0].details.code, "boom")
	assert_eq(entries[0].details.frames[0].path, "res://player.gd")


func test_game_log_buffer_ring_evicts_and_tracks_dropped() -> void:
	var buf := McpGameLogBuffer.new()
	var cap := McpGameLogBuffer.MAX_LINES
	for i in range(cap + 5):
		buf.append("info", "n %d" % i)
	assert_eq(buf.total_count(), cap, "Buffer should cap at MAX_LINES")
	assert_eq(buf.dropped_count(), 5, "Should record 5 evictions")
	## Oldest 5 dropped: first remaining entry should be index 5.
	var first := buf.get_range(0, 1)
	assert_eq(first[0].text, "n 5")


func test_game_log_buffer_clear_for_new_run_rotates_run_id_without_dropping_lines() -> void:
	var buf := McpGameLogBuffer.new()
	buf.append("info", "before")
	## Run ids include a sequence so fast back-to-back rotations differ.
	var first_id := buf.clear_for_new_run()
	assert_ne(first_id, "", "Initial clear should return a non-empty run id")
	assert_eq(buf.total_count(), 1, "Rotating should preserve prior lines")
	assert_eq(buf.get_range(0, 1)[0].run_id, "", "Pre-run lines keep their original empty run id")
	buf.append("info", "after")
	var second_id := buf.clear_for_new_run()
	assert_ne(first_id, second_id, "Each clear should rotate the run id")
	assert_eq(buf.total_count(), 2, "Second rotation should still preserve history")
	assert_eq(buf.get_run_range(first_id, 0, 10).size(), 1)
	assert_eq(buf.get_run_range(first_id, 0, 10)[0].text, "after")
	assert_eq(buf.get_run_range(second_id, 0, 10).size(), 0)


func test_game_log_buffer_preserves_order_after_multiple_wraps() -> void:
	## Post O(1)-circular-buffer rewrite: verify that two full wraps still
	## leave entries in correct logical order, and that get_range across the
	## wrap boundary doesn't return the physical-slot order by mistake.
	var buf := McpGameLogBuffer.new()
	var cap := McpGameLogBuffer.MAX_LINES
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
	var buf := McpGameLogBuffer.new()
	var cap := McpGameLogBuffer.MAX_LINES
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
	assert_is_error(result)
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
	assert_is_error(result)
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
	var game_buf := McpGameLogBuffer.new()
	game_buf.clear_for_new_run()
	game_buf.append("info", "spawned 12 blocks", {"code": "spawned"})
	game_buf.append("error", "null deref")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf)
	var result := handler.get_logs({"source": "game", "count": 10})
	assert_eq(result.data.source, "game")
	assert_eq(result.data.lines.size(), 2)
	assert_eq(result.data.lines[0].text, "spawned 12 blocks")
	assert_false(result.data.lines[0].has("details"), "Details are opt-in")
	assert_eq(result.data.lines[1].level, "error")
	assert_ne(result.data.run_id, "", "run_id should be set after clear_for_new_run")


func test_get_logs_source_game_defaults_to_current_run_only() -> void:
	var game_buf := McpGameLogBuffer.new()
	var first_id := game_buf.clear_for_new_run()
	game_buf.append("info", "first run")
	var second_id := game_buf.clear_for_new_run()
	game_buf.append("info", "second run")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf)

	var result := handler.get_logs({"source": "game", "count": 10})

	assert_eq(result.data.run_id, second_id)
	assert_eq(result.data.current_run_id, second_id)
	assert_eq(result.data.total_count, 1)
	assert_eq(result.data.lines.size(), 1)
	assert_eq(result.data.lines[0].text, "second run")
	assert_eq(result.data.lines[0].run_id, second_id)
	assert_false(result.data.stale_run_id)
	assert_eq(game_buf.get_run_range(first_id, 0, 10).size(), 1, "prior run remains retrievable")


func test_get_logs_source_game_since_run_id_reads_prior_run() -> void:
	var game_buf := McpGameLogBuffer.new()
	var first_id := game_buf.clear_for_new_run()
	game_buf.append("info", "first run")
	var second_id := game_buf.clear_for_new_run()
	game_buf.append("info", "second run")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf)

	var result := handler.get_logs({"source": "game", "since_run_id": first_id, "count": 10})

	assert_eq(result.data.run_id, first_id)
	assert_eq(result.data.current_run_id, second_id)
	assert_eq(result.data.lines.size(), 1)
	assert_eq(result.data.lines[0].text, "first run")
	assert_true(result.data.stale_run_id)


func test_get_logs_source_game_no_hello_run_reports_not_live_without_stale_lines() -> void:
	var game_buf := McpGameLogBuffer.new()
	var previous_id := game_buf.clear_for_new_run()
	game_buf.append("info", "previous run")
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin.begin_game_run(0, true)
	var current_id := game_buf.run_id()
	plugin._game_run_started_msec -= int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0) + 1
	var handler := EditorHandler.new(McpLogBuffer.new(), null, plugin, game_buf)

	var current := handler.get_logs({"source": "game", "count": 10})
	var previous := handler.get_logs({"source": "game", "since_run_id": previous_id, "count": 10})

	assert_eq(current.data.run_id, current_id)
	assert_eq(current.data.lines.size(), 0, "current no-hello run must not inherit prior lines")
	assert_eq(current.data.total_count, 0)
	assert_eq(current.data.game_status.status, "not_live")
	assert_eq(current.data.is_running, false)
	assert_eq(previous.data.lines.size(), 1, "previous run is still retrievable explicitly")
	assert_eq(previous.data.lines[0].text, "previous run")
	assert_true(previous.data.stale_run_id)


func test_get_logs_source_game_no_helper_counts_as_running() -> void:
	var game_buf := McpGameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin.begin_game_run(0, false)
	plugin._game_run_started_msec -= int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0) + 1
	var handler := EditorHandler.new(McpLogBuffer.new(), null, plugin, game_buf)

	var result := handler.get_logs({"source": "game", "count": 10})

	assert_eq(result.data.game_status.status, "no_helper")
	assert_eq(result.data.is_running, true)


func test_get_logs_source_game_live_run_counts_as_running() -> void:
	var game_buf := McpGameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin.begin_game_run(0, true)
	var current_id := game_buf.run_id()
	plugin._capture("mcp:hello", [], -1)
	game_buf.append("info", "ready")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, plugin, game_buf)

	var result := handler.get_logs({"source": "game", "count": 10})

	assert_eq(result.data.game_status.status, "live")
	assert_eq(result.data.is_running, true)
	assert_eq(result.data.lines.size(), 1)
	assert_eq(result.data.lines[0].run_id, current_id)


func test_get_logs_include_details_returns_buffered_metadata() -> void:
	var game_buf := McpGameLogBuffer.new()
	game_buf.append("error", "game boom", {
		"code": "ERR_GAME",
		"frames": [{"path": "res://game.gd", "line": 5, "function": "_tick"}],
	})
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append("error", "editor boom", "res://tool.gd", 9, "_run", {
		"code": "ERR_EDITOR",
		"frames": [{"path": "res://tool.gd", "line": 9, "function": "_run"}],
	})
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf, ed_buf)

	var compact := handler.get_logs({"source": "all", "count": 10})
	assert_false(compact.data.lines[0].has("details"), "Compact all-source logs strip details")
	assert_false(compact.data.lines[1].has("details"), "Compact all-source logs strip details")

	var detailed := handler.get_logs({"source": "all", "count": 10, "include_details": true})
	assert_eq(detailed.data.lines[0].details.code, "ERR_EDITOR")
	assert_eq(detailed.data.lines[0].details.frames[0].path, "res://tool.gd")
	assert_eq(detailed.data.lines[1].details.code, "ERR_GAME")
	assert_eq(detailed.data.lines[1].details.frames[0].function, "_tick")


func test_get_logs_source_game_offset_applies() -> void:
	var game_buf := McpGameLogBuffer.new()
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
	var game_buf := McpGameLogBuffer.new()
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


func test_get_logs_source_all_scopes_game_entries_to_current_run() -> void:
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("plugin")
	var game_buf := McpGameLogBuffer.new()
	game_buf.clear_for_new_run()
	game_buf.append("info", "old game")
	var current_id := game_buf.clear_for_new_run()
	game_buf.append("info", "current game")
	var handler := EditorHandler.new(plugin_buf, null, null, game_buf)

	var result := handler.get_logs({"source": "all", "count": 10})

	assert_eq(result.data.run_id, current_id)
	assert_eq(result.data.lines.size(), 2)
	assert_contains(result.data.lines[0].text, "plugin")
	assert_eq(result.data.lines[1].text, "current game")
	assert_eq(result.data.lines[1].run_id, current_id)


# ----- McpEditorLogBuffer (issue #231) -----

func test_editor_log_buffer_append_and_get_range() -> void:
	var buf := McpEditorLogBuffer.new()
	buf.append("error", "Parse Error", "res://broken.gd", 12, "")
	buf.append("warn", "deprecation", "res://foo.gd", 4, "_ready")
	var entries := buf.get_range(0, 10)
	assert_eq(entries.size(), 2)
	assert_eq(entries[0].source, "editor")
	assert_eq(entries[0].level, "error")
	assert_eq(entries[0].text, "Parse Error")
	assert_eq(entries[0].path, "res://broken.gd")
	assert_eq(entries[0].line, 12)
	assert_eq(entries[1].level, "warn")
	assert_eq(entries[1].function, "_ready")
	assert_eq(buf.total_count(), 2)


func test_editor_log_buffer_unknown_level_coerces_to_info() -> void:
	var buf := McpEditorLogBuffer.new()
	buf.append("fatal", "huh")
	assert_eq(buf.get_range(0, 1)[0].level, "info", "Unknown level should coerce to info")


func test_editor_log_buffer_missing_fields_default_to_empty() -> void:
	## A logger that omits structured fields (e.g. printerr without script
	## context) should still produce a well-formed entry — callers iterating
	## response shape never KeyError.
	var buf := McpEditorLogBuffer.new()
	buf.append("error", "bare")
	var e := buf.get_range(0, 1)[0]
	assert_eq(e.path, "")
	assert_eq(e.line, 0)
	assert_eq(e.function, "")


func test_editor_log_buffer_preserves_details() -> void:
	var buf := McpEditorLogBuffer.new()
	buf.append("error", "Parse Error", "res://broken.gd", 12, "", {
		"code": "Parse Error",
		"frames": [{"path": "res://broken.gd", "line": 12, "function": ""}],
	})
	var e := buf.get_range(0, 1)[0]
	assert_has_key(e, "details")
	assert_eq(e.details.code, "Parse Error")
	assert_eq(e.details.frames[0].line, 12)


func test_editor_log_buffer_ring_evicts_and_tracks_dropped() -> void:
	var buf := McpEditorLogBuffer.new()
	var cap := McpEditorLogBuffer.MAX_LINES
	for i in range(cap + 7):
		buf.append("error", "n %d" % i, "res://x.gd", i)
	assert_eq(buf.total_count(), cap, "Buffer should cap at MAX_LINES")
	assert_eq(buf.dropped_count(), 7, "Should record 7 evictions")
	assert_eq(buf.appended_total(), cap + 7, "Cursor should advance for every append")
	## Oldest 7 dropped: first remaining entry should be index 7.
	var first := buf.get_range(0, 1)
	assert_eq(first[0].text, "n 7")


func test_editor_log_buffer_get_since_returns_entries_after_cursor() -> void:
	var buf := McpEditorLogBuffer.new()
	buf.append("error", "before-a", "res://a.gd", 1)
	buf.append("error", "before-b", "res://b.gd", 2)
	var cursor := buf.appended_total()
	buf.append("error", "after-a", "res://a.gd", 3)
	buf.append("warn", "after-b", "res://b.gd", 4)

	var result := buf.get_since(cursor)
	assert_eq(result.cursor, cursor)
	assert_eq(result.entries.size(), 2)
	assert_eq(result.entries[0].text, "after-a")
	assert_eq(result.entries[1].text, "after-b")
	assert_eq(result.next_cursor, buf.appended_total())
	assert_false(result.truncated)
	assert_false(result.has_more)


func test_editor_log_buffer_get_since_reports_overflow_truncation() -> void:
	var buf := McpEditorLogBuffer.new()
	var cap := McpEditorLogBuffer.MAX_LINES
	var cursor := buf.appended_total()
	for i in range(cap + 3):
		buf.append("error", "storm %d" % i, "res://storm.gd", i)

	var result := buf.get_since(cursor)
	assert_true(result.truncated, "Overflow after the cursor must be visible")
	assert_eq(result.entries.size(), cap)
	assert_eq(result.entries[0].text, "storm 3")
	assert_eq(result.entries[cap - 1].text, "storm %d" % (cap + 2))
	assert_eq(result.oldest_cursor, 3)
	assert_eq(result.next_cursor, buf.appended_total())


func test_editor_log_buffer_get_since_limit_paginates_without_losing_cursor() -> void:
	var buf := McpEditorLogBuffer.new()
	for i in range(5):
		buf.append("error", "page %d" % i)

	var first := buf.get_since(0, 2)
	assert_eq(first.entries.size(), 2)
	assert_eq(first.entries[0].text, "page 0")
	assert_eq(first.next_cursor, 2)
	assert_true(first.has_more)

	var second := buf.get_since(first.next_cursor, 10)
	assert_eq(second.entries.size(), 3)
	assert_eq(second.entries[0].text, "page 2")
	assert_eq(second.next_cursor, 5)
	assert_false(second.has_more)


func test_editor_log_buffer_get_since_future_cursor_clamps_to_tail() -> void:
	var buf := McpEditorLogBuffer.new()
	for i in range(3):
		buf.append("error", "future %d" % i)

	var result := buf.get_since(99)
	assert_false(result.truncated)
	assert_eq(result.entries.size(), 0)
	assert_eq(result.next_cursor, buf.appended_total())
	assert_false(result.has_more)


func test_editor_log_buffer_clear_resets_retained_counts_but_preserves_cursor() -> void:
	var buf := McpEditorLogBuffer.new()
	for i in range(5):
		buf.append("error", "n %d" % i)
	var cursor := buf.appended_total()
	var cleared := buf.clear()
	assert_eq(cleared, 5, "clear() should report cleared count")
	assert_eq(buf.total_count(), 0)
	assert_eq(buf.dropped_count(), 0)
	assert_eq(buf.appended_total(), cursor, "clear() must not reset the cursor")


func test_editor_log_buffer_get_since_reports_clear_truncation() -> void:
	var buf := McpEditorLogBuffer.new()
	for i in range(5):
		buf.append("error", "before-clear %d" % i)
	var stale_cursor := 2
	buf.clear()
	buf.append("error", "after-clear", "res://after.gd", 9)

	var result := buf.get_since(stale_cursor)
	assert_true(result.truncated, "Clear after the cursor should degrade the window")
	assert_eq(result.entries.size(), 1)
	assert_eq(result.entries[0].text, "after-clear")
	assert_eq(result.oldest_cursor, 5)
	assert_eq(result.next_cursor, 6)


# ----- Diagnostics capture -----

func test_diagnostics_capture_uses_details_source_for_target_match() -> void:
	var buf := McpEditorLogBuffer.new()
	var target := "res://scripts/player.gd"
	var result := DiagnosticsCapture.capture_this_file(buf, target, func() -> Dictionary:
		buf.append("error", "Parse Error: Expected statement", "res://addons/godot_ai/handlers/script_handler.gd", 55, "_validate", {
			"source": {"path": target, "line": 7, "function": "GDScript::reload"},
			"resolved": {"path": "res://addons/godot_ai/handlers/script_handler.gd", "line": 55, "function": "_validate"},
		})
		return {"ok": false, "error_code": ERR_PARSE_ERROR}
	)

	assert_eq(result.diagnostics_scope, "this_file")
	assert_eq(result.diagnostics_status, "checked")
	assert_eq(result.diagnostics_detail, "log_capture")
	assert_eq(result.diagnostics.size(), 1)
	assert_eq(result.diagnostics[0].path, target)
	assert_eq(result.diagnostics[0].line, 7)
	assert_eq(result.diagnostics[0].function, "GDScript::reload")
	assert_eq(result.diagnostics[0].details.source.path, target)
	assert_eq(result.diagnostics[0].details.resolved.path, "res://addons/godot_ai/handlers/script_handler.gd")


func test_diagnostics_capture_excludes_load_wrapper_and_keeps_multiple_parse_errors() -> void:
	var buf := McpEditorLogBuffer.new()
	var target := "res://scripts/player.gd"
	var result := DiagnosticsCapture.capture_this_file(buf, target, func() -> Dictionary:
		buf.append("error", "Parse Error: first", "res://addons/godot_ai/handlers/script_handler.gd", 40, "_validate", {
			"source": {"path": target, "line": 4, "function": "GDScript::reload"},
		})
		buf.append("error", "Failed to load script \"res://scripts/player.gd\" with error \"Parse error\".", "res://addons/godot_ai/handlers/script_handler.gd", 40, "_validate", {
			"source": {"path": "modules/gdscript/gdscript.cpp", "line": 2907, "function": "load"},
		})
		buf.append("error", "Parse Error: second", "res://addons/godot_ai/handlers/script_handler.gd", 40, "_validate", {
			"source": {"path": target, "line": 8, "function": "GDScript::reload"},
		})
		return {"ok": false, "error_code": ERR_PARSE_ERROR}
	)

	assert_eq(result.diagnostics_detail, "log_capture")
	assert_eq(result.diagnostics.size(), 2)
	assert_eq(result.diagnostics[0].text, "Parse Error: first")
	assert_eq(result.diagnostics[0].line, 4)
	assert_eq(result.diagnostics[1].text, "Parse Error: second")
	assert_eq(result.diagnostics[1].line, 8)


func test_diagnostics_capture_rejects_pathless_entries_for_other_files() -> void:
	var buf := McpEditorLogBuffer.new()
	var target := "res://scripts/player.gd"
	var result := DiagnosticsCapture.capture_this_file(buf, target, func() -> Dictionary:
		buf.append("error", "unrelated parse error", "", 0, "", {
			"source": {"path": "res://scripts/other.gd", "line": 12},
			"frames": [{"path": "res://scripts/other.gd", "line": 12, "function": "_ready"}],
		})
		return {"ok": false, "error_code": ERR_PARSE_ERROR}
	)

	assert_eq(result.diagnostics_detail, "none")
	assert_eq(result.diagnostics, [])


func test_diagnostics_capture_reports_partial_when_window_overflows() -> void:
	var buf := McpEditorLogBuffer.new()
	var cap := McpEditorLogBuffer.MAX_LINES
	var target := "res://scripts/storm.gd"
	var result := DiagnosticsCapture.capture_this_file(buf, target, func() -> Dictionary:
		for i in range(cap + 2):
			buf.append("error", "storm %d" % i, "res://addons/godot_ai/handlers/script_handler.gd", i, "_validate", {
				"source": {"path": target, "line": i, "function": "GDScript::reload"},
			})
		return {"ok": false, "error_code": ERR_PARSE_ERROR}
	)

	assert_eq(result.diagnostics_status, "partial")
	assert_eq(result.diagnostics_detail, "log_capture")
	assert_eq(result.diagnostics_scope, "this_file")
	assert_eq(result.diagnostics.size(), cap)
	assert_eq(result.diagnostics[0].text, "storm 2")


# ----- get_logs source="editor" routing (issue #231) -----

func test_get_logs_source_editor_empty_when_no_buffer() -> void:
	## Plugin started without an editor buffer (e.g. Godot 4.4 where the
	## logger never attached) should still answer the source — empty page,
	## no crash — so `logs_read(source="editor")` is unconditionally safe
	## to call.
	var handler := EditorHandler.new(McpLogBuffer.new())
	var result := handler.get_logs({"source": "editor", "count": 10})
	assert_has_key(result, "data")
	assert_eq(result.data.source, "editor")
	assert_eq(result.data.lines.size(), 0)
	assert_eq(result.data.total_count, 0)
	assert_eq(result.data.dropped_count, 0)


func test_get_logs_source_editor_returns_buffered_entries() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append("error", "Parse Error: Expected statement", "res://broken.gd", 17, "")
	ed_buf.append("warn", "Integer division", "res://math.gd", 3, "_compute")
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, null, ed_buf)
	var result := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(result.data.source, "editor")
	assert_eq(result.data.lines.size(), 2)
	assert_eq(result.data.lines[0].text, "Parse Error: Expected statement")
	assert_eq(result.data.lines[0].path, "res://broken.gd")
	assert_eq(result.data.lines[0].line, 17)
	assert_eq(result.data.lines[1].level, "warn")
	assert_eq(result.data.lines[1].function, "_compute")


func test_get_logs_source_editor_reads_debugger_errors_tree() -> void:
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, tree)
	var result := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(result.data.source, "editor")
	assert_eq(result.data.total_count, 2)
	assert_eq(result.data.lines[0].level, "warn")
	assert_eq(result.data.lines[0].text, "GDScript::reload: The variable \"hash\" has the same name as a built-in function.")
	assert_eq(result.data.lines[0].path, "res://scripts/player.gd")
	assert_eq(result.data.lines[0].line, 21)
	assert_eq(result.data.lines[0].function, "GDScript::reload")
	assert_eq(result.data.lines[1].level, "error")
	assert_eq(result.data.lines[1].path, "res://scripts/broken.gd")


func test_get_logs_source_editor_details_include_debugger_errors_children() -> void:
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, tree)
	var result := handler.get_logs({"source": "editor", "count": 1, "include_details": true})
	var details: Dictionary = result.data.lines[0].details
	assert_eq(details.debugger_tab, "Errors")
	assert_eq(details.time, "0:00:00:776")
	assert_eq(details.source.path, "res://scripts/player.gd")
	assert_eq(details.children[0].label, "<GDScript Error>")
	assert_eq(details.children[1].label, "<GDScript Source>")
	assert_eq(details.frames.size(), 2, "Every stack row must land in frames, not just the labeled first one")
	assert_eq(details.frames[0].path, "res://scripts/player.gd")
	assert_eq(details.frames[0].function, "_ready")
	assert_eq(details.frames[1].path, "res://scripts/main.gd")
	assert_eq(details.frames[1].line, 12)
	assert_eq(details.frames[1].function, "_start")
	tree.free()


func test_get_logs_details_frames_survive_translated_stack_trace_label() -> void:
	## The "<Stack Trace>" label is TTR-translated, so frame detection must
	## not depend on the English text: frames past the first are the only
	## rows with an empty label and a real location, and the row before the
	## first of those is the labeled first frame.
	var tree := Tree.new()
	tree.set_columns(2)
	tree.set_hide_root(true)
	var root := tree.create_item()
	var error := tree.create_item(root)
	error.set_meta("_is_error", true)
	error.set_text(0, "0:00:01:002")
	error.set_text(1, "_ready: boom")
	error.set_metadata(0, ["res://scripts/player.gd", 8])
	var source := tree.create_item(error)
	source.set_text(0, "<GDScript-Quelle>")
	source.set_text(1, "player.gd:8 @ _ready()")
	source.set_metadata(0, ["res://scripts/player.gd", 8])
	var frame_0 := tree.create_item(error)
	frame_0.set_text(0, "<Stapelverfolgung>")
	frame_0.set_text(1, "player.gd:8 @ _ready()")
	frame_0.set_metadata(0, ["res://scripts/player.gd", 8])
	var frame_1 := tree.create_item(error)
	frame_1.set_text(1, "main.gd:3 @ _init()")
	frame_1.set_metadata(0, ["res://scripts/main.gd", 3])

	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, null, tree)
	var result := handler.get_logs({"source": "editor", "count": 1, "include_details": true})
	var frames: Array = result.data.lines[0].details.frames
	assert_eq(frames.size(), 2)
	assert_eq(frames[0].function, "_ready")
	assert_eq(frames[1].function, "_init")
	tree.free()


func test_get_logs_source_editor_dedupes_debugger_errors_tree() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append(
		"warn",
		"GDScript::reload: The variable \"hash\" has the same name as a built-in function.",
		"res://scripts/player.gd",
		21,
		"GDScript::reload",
	)
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, ed_buf, tree)
	var result := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(result.data.total_count, 2, "duplicate debugger row should not repeat the buffered warning")
	assert_eq(result.data.lines[0].text, "GDScript::reload: The variable \"hash\" has the same name as a built-in function.")
	assert_eq(result.data.lines[1].text, "Parse Error: Expected statement")


func test_get_logs_source_editor_offset_applies() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	for i in range(5):
		ed_buf.append("error", "e %d" % i, "res://x.gd", i)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, null, ed_buf)
	var result := handler.get_logs({"source": "editor", "count": 2, "offset": 2})
	assert_eq(result.data.returned_count, 2)
	assert_eq(result.data.lines[0].text, "e 2")
	assert_eq(result.data.lines[1].text, "e 3")
	assert_eq(result.data.offset, 2)
	assert_eq(result.data.total_count, 5)


func test_get_logs_source_editor_regular_read_returns_next_cursor() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append("error", "before", "res://x.gd", 1)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, null, ed_buf)
	var result := handler.get_logs({"source": "editor", "count": 10})
	assert_eq(result.data.lines.size(), 1)
	assert_eq(result.data.next_cursor, ed_buf.appended_total())
	assert_eq(result.data.appended_total, ed_buf.appended_total())


func test_get_logs_source_editor_since_cursor_returns_incremental_entries() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append("error", "before-a", "res://before.gd", 1)
	ed_buf.append("error", "before-b", "res://before.gd", 2)
	var cursor := ed_buf.appended_total()
	ed_buf.append("error", "after-a", "res://after.gd", 3)
	ed_buf.append("warn", "after-b", "res://after.gd", 4)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, null, ed_buf)
	var result := handler.get_logs({"source": "editor", "since_cursor": cursor, "count": 1})
	assert_eq(result.data.lines.size(), 1)
	assert_eq(result.data.lines[0].text, "after-a")
	assert_eq(result.data.cursor, cursor)
	assert_eq(result.data.next_cursor, cursor + 1)
	assert_eq(result.data.appended_total, ed_buf.appended_total())
	assert_true(result.data.has_more)
	assert_false(result.data.truncated)


func test_get_logs_source_editor_since_cursor_reports_truncation() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	var cap := McpEditorLogBuffer.MAX_LINES
	for i in range(cap + 2):
		ed_buf.append("error", "storm %d" % i, "res://storm.gd", i)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, null, ed_buf)
	var result := handler.get_logs({"source": "editor", "since_cursor": 0, "count": 10})
	assert_true(result.data.truncated)
	assert_eq(result.data.oldest_cursor, 2)
	assert_eq(result.data.lines[0].text, "storm 2")
	assert_eq(result.data.next_cursor, 12)
	assert_true(result.data.has_more)


func test_get_logs_source_editor_since_cursor_excludes_debugger_errors_tree() -> void:
	var ed_buf := McpEditorLogBuffer.new()
	var cursor := ed_buf.appended_total()
	var tree := _make_debugger_errors_tree()
	var handler := EditorHandler.new(McpLogBuffer.new(), null, McpDebuggerPlugin.new(), null, ed_buf, tree)
	var result := handler.get_logs({"source": "editor", "since_cursor": cursor, "count": 10})
	assert_eq(result.data.lines.size(), 0, "Cursor mode is scoped to Logger-backed editor entries")
	assert_eq(result.data.next_cursor, cursor)
	assert_false(result.data.has_more)
	tree.free()


func test_get_logs_source_all_includes_editor_between_plugin_and_game() -> void:
	var plugin_buf := McpLogBuffer.new()
	plugin_buf.log("plugin-a")
	var ed_buf := McpEditorLogBuffer.new()
	ed_buf.append("error", "parse err", "res://x.gd", 1, "")
	var game_buf := McpGameLogBuffer.new()
	game_buf.append("info", "game-runtime")
	var handler := EditorHandler.new(plugin_buf, null, null, game_buf, ed_buf)
	var result := handler.get_logs({"source": "all", "count": 10})
	assert_eq(result.data.lines.size(), 3)
	## Order: plugin → editor → game.
	assert_eq(result.data.lines[0].source, "plugin")
	assert_eq(result.data.lines[1].source, "editor")
	assert_eq(result.data.lines[1].text, "parse err")
	assert_eq(result.data.lines[2].source, "game")


func test_get_logs_source_all_dropped_count_includes_editor() -> void:
	## The dropped_count surfaced by source="all" should aggregate across
	## both ring buffers so a caller polling for "are we losing entries"
	## doesn't have to read each source separately.
	var ed_buf := McpEditorLogBuffer.new()
	for i in range(McpEditorLogBuffer.MAX_LINES + 3):
		ed_buf.append("error", "x %d" % i)
	var game_buf := McpGameLogBuffer.new()
	for i in range(McpGameLogBuffer.MAX_LINES + 4):
		game_buf.append("info", "g %d" % i)
	var handler := EditorHandler.new(McpLogBuffer.new(), null, null, game_buf, ed_buf)
	var result := handler.get_logs({"source": "all", "count": 1})
	assert_eq(result.data.dropped_count, 7, "Editor (3) + game (4) drops should sum")


func test_get_logs_source_invalid_message_lists_editor() -> void:
	## After adding the new source, the validator's error message should
	## list it so users see a complete option set in their typo correction.
	var handler := EditorHandler.new(McpLogBuffer.new())
	var result := handler.get_logs({"source": "bogus"})
	assert_is_error(result)
	assert_contains(result.error.message, "editor")


## Mirrors ScriptEditorDebugger's real Errors-tab layout (verified against
## script_editor_debugger.cpp on 4.3 and 4.6): children of an error item are
## flat — optional "<X Error>" row, one "<X Source>" row, then one row per
## stack frame. Only frame 0 carries the "<Stack Trace>" label; later frames
## have an empty label. Frame text uses the file *name*, not the res:// path.
func _make_debugger_errors_tree() -> Tree:
	var tree := Tree.new()
	tree.set_columns(2)
	tree.set_hide_root(true)
	var root := tree.create_item()

	var warning := tree.create_item(root)
	warning.set_meta("_is_warning", true)
	warning.set_text(0, "0:00:00:776")
	warning.set_text(1, "GDScript::reload: The variable \"hash\" has the same name as a built-in function.")
	warning.set_metadata(0, ["res://scripts/player.gd", 21])
	var warning_condition := tree.create_item(warning)
	warning_condition.set_text(0, "<GDScript Error>")
	warning_condition.set_text(1, "BUILTIN_SHADOWED")
	warning_condition.set_metadata(0, ["res://scripts/player.gd", 21])
	var warning_source := tree.create_item(warning)
	warning_source.set_text(0, "<GDScript Source>")
	warning_source.set_text(1, "player.gd:21 @ GDScript::reload()")
	warning_source.set_metadata(0, ["res://scripts/player.gd", 21])
	var warning_frame := tree.create_item(warning)
	warning_frame.set_text(0, "<Stack Trace>")
	warning_frame.set_text(1, "player.gd:21 @ _ready()")
	warning_frame.set_metadata(0, ["res://scripts/player.gd", 21])
	var warning_frame_2 := tree.create_item(warning)
	warning_frame_2.set_text(1, "main.gd:12 @ _start()")
	warning_frame_2.set_metadata(0, ["res://scripts/main.gd", 12])

	var error := tree.create_item(root)
	error.set_meta("_is_error", true)
	error.set_text(0, "0:00:00:790")
	error.set_text(1, "Parse Error: Expected statement")
	error.set_metadata(0, ["res://scripts/broken.gd", 12])
	return tree


func test_log_backtrace_resolve_error_preserves_all_frames() -> void:
	var bt := StubBacktrace.new("", 0, "", [
		{"path": "res://player.gd", "line": 44, "function": "_take_damage"},
		{"path": "res://main.gd", "line": 12, "function": "_ready"},
	])
	var resolved := McpLogBacktrace.resolve_error(
		"push_error",
		"core/variant/variant_utility.cpp",
		1000,
		"hp went negative",
		"",
		2,
		[bt],
	)
	assert_eq(resolved.path, "res://player.gd")
	assert_eq(resolved.details.error_type_name, "script")
	assert_eq(resolved.details.source.path, "core/variant/variant_utility.cpp")
	assert_eq(resolved.details.frames.size(), 2)
	assert_eq(resolved.details.frames[1].function, "_ready")


# ----- EditorLogger filtering (issue #231) -----

const _LoggerLoader := preload("res://addons/godot_ai/runtime/logger_loader.gd")


func test_editor_logger_captures_user_script_parse_error() -> void:
	## Simulate Godot's parser firing _log_error with the offending .gd
	## file as `file`. The buffer should receive a structured entry with
	## the path/line/level so the LLM can navigate straight to the bug.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error(
		"_parse",
		"res://broken.gd",
		42,
		"Parse Error: Expected statement, got 'EOF' instead.",
		"",
		false,
		2,  ## SCRIPT
		[],
	)
	var entries := ed_buf.get_range(0, 10)
	assert_eq(entries.size(), 1, "User script parse error should be captured")
	assert_eq(entries[0].level, "error")
	assert_eq(entries[0].path, "res://broken.gd")
	assert_eq(entries[0].line, 42)
	assert_contains(entries[0].text, "Parse Error")


func test_editor_logger_warn_error_type_maps_to_warn_level() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error("_run", "res://x.gd", 3, "deprecated", "", false, 1, [])
	var entries := ed_buf.get_range(0, 10)
	assert_eq(entries.size(), 1)
	assert_eq(entries[0].level, "warn")


func test_editor_logger_drops_internal_godot_cpp_noise() -> void:
	## Errors that originate in Godot's C++ code with no script backtrace
	## (e.g. "scene/main/scene_tree.cpp" warnings) should be filtered —
	## otherwise the editor's normal startup chatter buries the parse
	## errors callers actually want.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error("foo", "scene/main/scene_tree.cpp", 1234, "noise", "", false, 0, [])
	assert_eq(ed_buf.total_count(), 0, "C++-source errors with no script backtrace should be filtered")


func test_editor_logger_captures_engine_resource_error_with_res_path() -> void:
	## ResourceLoader failures can be emitted by engine C++ with no
	## ScriptBacktrace even when the message names a project resource.
	## Those red editor/terminal lines should still be visible through
	## logs_read(source="editor").
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error(
		"_load",
		"core/io/resource_loader.cpp",
		222,
		"Failed loading resource: res://does/not/exist.tres.",
		"",
		false,
		0,
		[],
	)
	var entries := ed_buf.get_range(0, 10)
	assert_eq(entries.size(), 1, "Engine resource errors naming res:// paths should be captured")
	assert_eq(entries[0].path, "res://does/not/exist.tres")
	assert_eq(entries[0].line, 0, "Engine resource errors have no recoverable script line")
	assert_eq(entries[0].function, "_load")
	assert_contains(entries[0].text, "Failed loading resource")


func test_editor_logger_drops_engine_resource_error_for_godot_ai_addon() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error(
		"_load",
		"core/io/resource_loader.cpp",
		222,
		"Failed loading resource: res://addons/godot_ai/missing.tres.",
		"",
		false,
		0,
		[],
	)
	assert_eq(ed_buf.total_count(), 0, "Engine resource errors inside addons/godot_ai/ should be filtered")


func test_editor_logger_drops_godot_ai_addon_to_avoid_feedback_loop() -> void:
	## We push_warning ourselves from plugin.gd. Capturing those would
	## amplify on every reload and pollute the buffer the dock reads.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	logger._log_error("_start_server", "res://addons/godot_ai/plugin.gd", 100, "self-noise", "", false, 1, [])
	assert_eq(ed_buf.total_count(), 0, "addons/godot_ai/ paths should be filtered")


func test_editor_logger_uses_script_backtrace_for_push_error() -> void:
	## push_error/push_warning fire with file=core/variant/variant_utility.cpp;
	## the actual user location lives in the first script_backtrace frame.
	## Without this remapping, every push_error from user code would be
	## filtered as C++ noise.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)

	## Build a stub backtrace object with the same getter shape Godot
	## passes via _log_error. ScriptBacktrace can't be constructed in
	## tests, so a minimal duck-typed stub stands in.
	var bt := StubBacktrace.new("res://user_tool.gd", 17, "_handle_event")
	logger._log_error(
		"push_error",
		"core/variant/variant_utility.cpp",
		1000,
		"user-flagged-bug",
		"",
		false,
		0,
		[bt],
	)
	var entries := ed_buf.get_range(0, 10)
	assert_eq(entries.size(), 1, "push_error from user code should be captured via backtrace")
	assert_eq(entries[0].path, "res://user_tool.gd")
	assert_eq(entries[0].line, 17)
	assert_eq(entries[0].function, "_handle_event")
	assert_contains(entries[0].text, "user-flagged-bug")
	assert_eq(entries[0].details.error_type_name, "error")
	assert_eq(entries[0].details.source.path, "core/variant/variant_utility.cpp")
	assert_eq(entries[0].details.resolved.path, "res://user_tool.gd")
	assert_eq(entries[0].details.frames[0].function, "_handle_event")


func test_editor_logger_drops_push_error_from_plugin_via_backtrace() -> void:
	## A push_warning called from inside addons/godot_ai/ should be filtered
	## even though file points at variant_utility.cpp — the backtrace gives
	## us the real source path, and that's the path we filter on.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var ed_buf := McpEditorLogBuffer.new()
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new(ed_buf)
	var bt := StubBacktrace.new("res://addons/godot_ai/plugin.gd", 50, "_attach_editor_logger")
	logger._log_error(
		"push_warning",
		"core/variant/variant_utility.cpp",
		1000,
		"internal noise",
		"",
		false,
		1,
		[bt],
	)
	assert_eq(ed_buf.total_count(), 0, "Backtrace inside godot_ai addon should still filter")


func test_editor_logger_no_op_when_buffer_unset() -> void:
	## Defensive: instantiated without a buffer (the default), the logger
	## must silently no-op rather than crash. Covers the brief window
	## during plugin shutdown after `_detach_editor_logger` has run but a
	## stray Logger virtual is still in flight.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH).new()
	logger._log_error("f", "res://x.gd", 1, "msg", "", false, 0, [])
	assert_true(true, "No crash when buffer is null")


func test_editor_logger_is_user_script_predicate() -> void:
	## Static helper — script `extends Logger` so it only parses on
	## Godot 4.5+. Skip on older where load() returns null.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var script = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH)
	assert_true(script._is_user_script("res://foo.gd"))
	assert_true(script._is_user_script("res://Bar.cs"))
	assert_true(script._is_user_script("/abs/path/foo.gd"))
	assert_true(script._is_user_script("foo.GD"), "Case-insensitive .gd match")
	assert_false(script._is_user_script(""))
	assert_false(script._is_user_script("scene/main/scene_tree.cpp"))
	assert_false(script._is_user_script("res://image.png"))


func test_editor_logger_extract_user_res_path_predicate() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var script = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH)
	assert_eq(
		script._extract_user_res_path("Cannot open file 'res://does/not/exist.tres'."),
		"res://does/not/exist.tres",
	)
	assert_eq(
		script._extract_user_res_path("Failed loading resource: res://folder/with spaces/file.tres."),
		"res://folder/with spaces/file.tres",
	)
	assert_eq(script._extract_user_res_path("Failed loading resource: res://addons/godot_ai/x.tres."), "")
	assert_eq(script._extract_user_res_path("scene/main/scene_tree.cpp noise"), "")


func test_editor_logger_is_in_godot_ai_addon_predicate() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var script = _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH)
	assert_true(script._is_in_godot_ai_addon("res://addons/godot_ai/plugin.gd"))
	assert_true(script._is_in_godot_ai_addon("/abs/project/addons/godot_ai/handler.gd"))
	assert_false(script._is_in_godot_ai_addon("res://user_script.gd"))
	assert_false(script._is_in_godot_ai_addon("res://addons/other_plugin/foo.gd"))


# ----- McpDebuggerPlugin: log batch capture (issue #73) -----

func test_debugger_plugin_log_batch_appends_to_buffer() -> void:
	var game_buf := McpGameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin._capture("mcp:log_batch", [[
		["info", "alpha"],
		["error", "beta"],
	]], 0)
	assert_eq(game_buf.total_count(), 2)
	var entries := game_buf.get_range(0, 10)
	assert_eq(entries[0].text, "alpha")
	assert_eq(entries[1].level, "error")


func test_debugger_plugin_log_batch_preserves_details() -> void:
	var game_buf := McpGameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin._capture("mcp:log_batch", [[
		["error", "boom", {
			"code": "ERR",
			"frames": [{"path": "res://game.gd", "line": 21, "function": "_ready"}],
		}],
		{"level": "warn", "text": "dict-entry", "details": {"code": "WARN"}},
	]], 0)
	var entries := game_buf.get_range(0, 10)
	assert_eq(entries.size(), 2)
	assert_eq(entries[0].details.frames[0].path, "res://game.gd")
	assert_eq(entries[1].level, "warn")
	assert_eq(entries[1].details.code, "WARN")


func test_debugger_plugin_begin_game_run_rotates_run_id() -> void:
	var game_buf := McpGameLogBuffer.new()
	game_buf.append("info", "stale from previous run")
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin.begin_game_run()
	var run_id := game_buf.run_id()
	assert_ne(run_id, "", "begin_game_run should set a run_id")
	assert_eq(game_buf.total_count(), 1, "begin_game_run should preserve prior lines")
	plugin._capture("mcp:hello", [], 0)
	assert_eq(game_buf.run_id(), run_id, "hello should confirm liveness without rotating run identity")


func test_debugger_plugin_readiness_is_scoped_to_current_run() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin.begin_game_run()
	plugin._setup_session(11)
	plugin._capture("mcp:hello", [], 11)
	assert_true(plugin.is_game_capture_ready(), "hello for active run should mark capture ready")

	plugin.begin_game_run()
	assert_false(plugin.is_game_capture_ready(), "starting the next run must clear stale readiness")
	plugin._game_ready = true
	assert_false(plugin.is_game_capture_ready(), "raw ready flag without current run token is stale")
	plugin._capture("mcp:hello", [], -1)
	assert_true(plugin.is_game_capture_ready(), "hello without a session still readies active direct-test run")
	plugin.end_game_run()
	assert_false(plugin.is_game_capture_ready(), "stopping the run clears capture readiness")
	plugin._capture("mcp:hello", [], -1)
	assert_false(plugin.is_game_capture_ready(), "late hello after stop must not restore readiness")


func test_debugger_plugin_game_status_tracks_run_lifecycle() -> void:
	var plugin := McpDebuggerPlugin.new()
	var status := plugin.get_game_status()
	assert_eq(status.status, "stopped")
	assert_eq(status.active, false)
	assert_eq(status.ready, false)

	plugin.begin_game_run(42, true)
	status = plugin.get_game_status(plugin._game_run_started_msec)
	assert_eq(status.status, "launching")
	assert_eq(status.run_token, 1)
	assert_eq(status.active, true)
	assert_eq(status.ready, false)
	assert_eq(status.helper_expected, true)
	assert_eq(status.editor_log_cursor, 42)

	plugin._capture("mcp:hello", [], -1)
	status = plugin.get_game_status()
	assert_eq(status.status, "live")
	assert_eq(status.ready, true)

	plugin.begin_game_run(99, true)
	status = plugin.get_game_status(plugin._game_run_started_msec)
	assert_eq(status.status, "launching")
	plugin._game_ready = true
	status = plugin.get_game_status(plugin._game_run_started_msec)
	assert_eq(status.status, "launching", "raw ready flag without the current token is stale")

	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	status = plugin.get_game_status(after_window - 1)
	assert_eq(status.status, "launching", "run stays launching until the wait window is exhausted")
	status = plugin.get_game_status(after_window)
	assert_eq(status.status, "not_live", "wait window boundary is inclusive")
	assert_eq(status.editor_log_cursor, 99)

	plugin.end_game_run()
	status = plugin.get_game_status()
	assert_eq(status.status, "stopped")
	assert_eq(status.active, false)
	assert_eq(status.ready, false)


func test_debugger_plugin_game_status_reports_no_helper_when_not_expected() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin.begin_game_run(7, false)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window)
	assert_eq(status.status, "no_helper")
	assert_eq(status.helper_expected, false)
	assert_eq(status.editor_log_cursor, 7)


func test_debugger_plugin_explain_not_live_includes_run_scoped_editor_errors() -> void:
	var editor_buf := McpEditorLogBuffer.new()
	var cursor := editor_buf.appended_total()
	editor_buf.append("error", "Parse Error: Expected expression", "res://broken.gd", 5, "")
	var plugin := McpDebuggerPlugin.new(null, null, editor_buf)
	plugin.begin_game_run(cursor, true)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.EVAL_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.EVAL_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.EVAL_GAME_NOT_READY)

	assert_eq(err.error.code, ErrorCodes.EVAL_GAME_NOT_READY)
	assert_contains(err.error.message, "failed to load or crashed")
	assert_contains(err.error.message, "Parse Error: Expected expression")
	assert_contains(err.error.message, "res://broken.gd:5")
	assert_contains(err.error.message, "logs_read(source='editor'")
	assert_eq(err.error.data.recent_errors.size(), 1)
	assert_eq(err.error.data.recent_errors[0].path, "res://broken.gd")
	assert_eq(err.error.data.recent_errors[0].line, 5)
	assert_eq(err.error.data.recent_errors_scope, "run")
	assert_eq(err.error.data.recent_errors_may_predate_run, false)
	assert_eq(err.error.data.game_status.status, "not_live")


func test_debugger_plugin_explain_not_live_without_error_stays_soft() -> void:
	var editor_buf := McpEditorLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, null, editor_buf)
	plugin.begin_game_run(editor_buf.appended_total(), true)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_contains(err.error.message, "not responding")
	assert_contains(err.error.message, "reported no load errors")
	assert_false(err.error.message.contains("crashed"), "no correlated error must not claim a crash")
	assert_eq(err.error.data.recent_errors.size(), 0)
	assert_eq(err.error.data.recent_errors_scope, "none")


func test_debugger_plugin_explain_not_live_surfaces_retained_editor_error_softly() -> void:
	var editor_buf := McpEditorLogBuffer.new()
	editor_buf.append("error", "Parse Error: Expected expression", "res://broken_before_run.gd", 9, "")
	var plugin := McpDebuggerPlugin.new(null, null, editor_buf)
	plugin.begin_game_run(editor_buf.appended_total(), true)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_contains(err.error.message, "not responding")
	assert_contains(err.error.message, "may be related")
	assert_contains(err.error.message, "may predate this run")
	assert_contains(err.error.message, "res://broken_before_run.gd:9")
	assert_false(err.error.message.contains("failed to load or crashed"), "retained errors must not claim run causation")
	assert_eq(err.error.data.recent_errors.size(), 1)
	assert_eq(err.error.data.recent_errors[0].path, "res://broken_before_run.gd")
	assert_eq(err.error.data.recent_errors_scope, "retained_recent")
	assert_eq(err.error.data.recent_errors_may_predate_run, true)


func test_debugger_plugin_explain_not_live_ignores_retained_test_errors() -> void:
	var editor_buf := McpEditorLogBuffer.new()
	editor_buf.append("error", "Parse Error: Expected conditional expression", "res://tests/test_runner.gd", 86, "")
	var plugin := McpDebuggerPlugin.new(null, null, editor_buf)
	plugin.begin_game_run(editor_buf.appended_total(), true)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_contains(err.error.message, "reported no load errors")
	assert_eq(err.error.data.recent_errors.size(), 0)
	assert_eq(err.error.data.recent_errors_scope, "none")


func test_debugger_plugin_explain_not_live_preserves_no_helper_guidance() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin.begin_game_run(0, false)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_contains(err.error.message, "_mcp_game_helper")
	assert_contains(err.error.message, "source='viewport'")
	assert_false(err.error.message.contains("failed to load"), "no-helper projects must not be framed as load failures")
	assert_eq(err.error.data.game_status.status, "no_helper")


func test_debugger_plugin_explain_not_live_launching_asks_to_retry() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin.begin_game_run(0, true)
	var status := plugin.get_game_status(plugin._game_run_started_msec, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_contains(err.error.message, "still starting")
	assert_contains(err.error.message, "Retry shortly")
	assert_eq(err.error.data.game_status.status, "launching")


func test_debugger_plugin_explain_not_live_marks_truncated_editor_errors() -> void:
	var editor_buf := McpEditorLogBuffer.new()
	var cursor := 0
	for i in range(McpEditorLogBuffer.MAX_LINES + 2):
		editor_buf.append("error", "Parse Error %d" % i, "res://broken_%d.gd" % i, i + 1, "")
	var plugin := McpDebuggerPlugin.new(null, null, editor_buf)
	plugin.begin_game_run(cursor, true)
	var after_window := plugin._game_run_started_msec + int(McpDebuggerPlugin.GAME_READY_WAIT_SEC * 1000.0)
	var status := plugin.get_game_status(after_window, McpDebuggerPlugin.GAME_READY_WAIT_SEC)

	var err := plugin._explain_not_live(status, ErrorCodes.INTERNAL_ERROR)

	assert_eq(err.error.data.recent_errors_truncated, true)
	assert_contains(err.error.message, "may be truncated")
	assert_eq(err.error.data.recent_errors.size(), 5, "recent errors are capped")


func test_debugger_plugin_ignores_hello_from_stale_session() -> void:
	var game_buf := McpGameLogBuffer.new()
	var plugin := McpDebuggerPlugin.new(null, game_buf)
	plugin.begin_game_run()
	var run_id := game_buf.run_id()
	plugin._setup_session(22)
	plugin._capture("mcp:hello", [], 21)
	assert_false(plugin.is_game_capture_ready(), "hello from an old debugger session must not ready current run")
	assert_eq(game_buf.run_id(), run_id, "stale hello must not rotate logs for current run")

	plugin._capture("mcp:hello", [], 22)
	assert_true(plugin.is_game_capture_ready(), "hello from current session should ready capture")
	assert_eq(game_buf.run_id(), run_id, "current hello confirms the existing run identity")


func test_debugger_plugin_log_batch_no_buffer_is_safe() -> void:
	## Plugin started without a game buffer should silently no-op on
	## log batches rather than crash — defensive for partial init.
	var plugin := McpDebuggerPlugin.new(null, null)
	plugin._capture("mcp:log_batch", [[["info", "x"]]], 0)
	assert_true(true, "No crash when no game buffer is wired")


# ----- GameLogger._log_error arg routing (PR #78 smoke bug) -----

# game_logger lives in the .gdignore'd runtime/loggers/ folder and is built
# from source by LoggerLoader (see _LoggerLoader above) — load() won't resolve
# a .gdignore'd path, so these tests go through the loader too.


func test_game_logger_single_arg_push_warning_preserves_user_message() -> void:
	## push_warning("warn-game") → code="warn-game", rationale="". The user's
	## message must survive; before the fix, rationale was the only source and
	## the text was discarded.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
	logger._log_error("push_warning", "core/variant/variant_utility.cpp", 1034, "warn-game", "", false, 1, [])
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_eq(pending[0][0], "warn")
	assert_contains(pending[0][1], "warn-game", "User's message text must survive single-arg push_warning")


func test_game_logger_single_arg_push_error_preserves_user_message() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
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
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
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
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
	logger._log_message("oops", true)
	logger._log_message("hi", false)
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 2)
	assert_eq(pending[0][0], "error")
	assert_eq(pending[0][1], "oops")
	assert_eq(pending[1][0], "info")
	assert_eq(pending[1][1], "hi")


func test_game_logger_uses_script_backtrace_for_push_error() -> void:
	## push_error from game-side .gd lands with file=variant_utility.cpp;
	## the queued text must report the user's GDScript location (from the
	## first backtrace frame), not the C++ wrapper. Mirrors the
	## editor_logger backtrace-remap test — game_logger went uncovered
	## until the McpLogBacktrace.resolve_error extraction.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
	var bt := StubBacktrace.new("res://player.gd", 88, "_take_damage")
	logger._log_error(
		"push_error",
		"core/variant/variant_utility.cpp",
		1000,
		"hp went negative",
		"",
		false,
		0,
		[bt],
	)
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_eq(pending[0][0], "error")
	assert_contains(pending[0][1], "hp went negative")
	assert_contains(pending[0][1], "res://player.gd:88", "Backtrace path:line should land in the formatted text")
	assert_contains(pending[0][1], "_take_damage", "Backtrace function should land in the formatted text")
	assert_true(not pending[0][1].contains("variant_utility.cpp"), "C++ wrapper path should be replaced by the backtrace")
	assert_eq(pending[0].size(), 3, "Runtime log batches carry optional details")
	assert_eq(pending[0][2].source.path, "core/variant/variant_utility.cpp")
	assert_eq(pending[0][2].resolved.path, "res://player.gd")
	assert_eq(pending[0][2].frames[0].line, 88)


func test_game_logger_falls_back_to_original_file_when_no_backtrace() -> void:
	## A two-arg push_error from a real .gd file (rationale-form) reports
	## file=res://foo.gd directly with no backtrace; the formatted loc
	## suffix should still appear so users can navigate to the source.
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH).new()
	logger._log_error("my_func", "res://foo.gd", 42, "ERR_CODE", "detailed reason", false, 0, [])
	var pending: Array = logger.drain()
	assert_eq(pending.size(), 1)
	assert_contains(pending[0][1], "res://foo.gd:42", "Fallback path:line should appear when no backtrace is present")


# ----- game_eval -----

func test_game_eval_missing_code_returns_error() -> void:
	var result := _handler.game_eval({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_game_eval_without_debugger_plugin_returns_error() -> void:
	## _handler is constructed without a debugger plugin in suite_setup,
	## so game_eval should return INTERNAL_ERROR.
	var result := _handler.game_eval({"code": "return 42"})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)


func test_game_eval_silently_drops_unknown_eval_response() -> void:
	## _on_eval_response for an unknown request_id must silently drop
	## without crashing (same pattern as screenshot_error_unknown_request).
	var plugin := McpDebuggerPlugin.new()
	plugin._on_eval_response(["unknown-id", "42"])
	assert_true(true, "No crash when replying to unknown eval request_id")


func test_game_eval_silently_drops_unknown_eval_error() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin._on_eval_error(["unknown-id", "some error"])
	assert_true(true, "No crash when replying to unknown eval request_id")
