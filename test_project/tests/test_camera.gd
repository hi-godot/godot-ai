@tool
extends McpTestSuite

const CameraHandler := preload("res://addons/godot_ai/handlers/camera_handler.gd")

## Tests for CameraHandler — Camera2D/Camera3D authoring, configure,
## limits, damping, follow, presets.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: CameraHandler
var _undo_redo: EditorUndoRedoManager
var _created_paths: Array[String] = []
var _created_nodes: Array[Node] = []


func suite_name() -> String:
	return "camera"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = CameraHandler.new(_undo_redo)


func teardown() -> void:
	_cleanup_created()


func suite_teardown() -> void:
	_cleanup_created()


func _cleanup_created() -> void:
	for path in _created_paths:
		_remove_by_path(path)
	_created_paths.clear()
	for node in _created_nodes:
		if is_instance_valid(node) and node.get_parent() != null:
			_clear_camera_current_for_removal(node)
			node.get_parent().remove_child(node)
			node.queue_free()
	_created_nodes.clear()


func _remove_by_path(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := McpScenePath.resolve(path, scene_root)
	if node != null and node.get_parent() != null:
		_clear_camera_current_for_removal(node)
		node.get_parent().remove_child(node)
		node.queue_free()


func _create(node_name: String, type_str: String = "2d", make_current: bool = false) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var result := _handler.create_camera({
		"parent_path": "/" + scene_root.name,
		"name": node_name,
		"type": type_str,
		"make_current": make_current,
	})
	if result.has("data"):
		_created_paths.append(result.data.path)
	return result


func _track_node(node: Node) -> void:
	_created_nodes.append(node)


func _clear_camera_current_for_removal(node: Node) -> void:
	if node == null or not is_instance_valid(node) or not node.has_method("clear_current"):
		return
	var viewport_matches := false
	if node is Camera2D:
		var viewport_2d := node.get_viewport()
		viewport_matches = viewport_2d != null and viewport_2d.get_camera_2d() == node
	elif node is Camera3D:
		var viewport_3d := node.get_viewport()
		viewport_matches = viewport_3d != null and viewport_3d.get_camera_3d() == node
	if node.has_method("is_current") and (bool(node.is_current()) or viewport_matches):
		node.clear_current()
	if node is Camera2D:
		(node as Camera2D).force_update_scroll()


func _camera_current_settled(cam: Node, expected: bool) -> bool:
	if cam == null or not is_instance_valid(cam):
		return not expected
	if not cam.has_method("is_current"):
		return false
	var viewport_matches := false
	if cam is Camera2D:
		var viewport_2d := cam.get_viewport()
		viewport_matches = viewport_2d != null and viewport_2d.get_camera_2d() == cam
	elif cam is Camera3D:
		var viewport_3d := cam.get_viewport()
		viewport_matches = viewport_3d != null and viewport_3d.get_camera_3d() == cam
	if expected:
		return bool(cam.is_current()) and viewport_matches
	return not bool(cam.is_current()) and not viewport_matches


func _wait_for_camera_current(cam: Node, expected: bool) -> bool:
	for _i in range(20):
		if _camera_current_settled(cam, expected):
			return true
		OS.delay_msec(10)
	return _camera_current_settled(cam, expected)


func _wait_for_camera_current_report(cam: Node, expected: bool) -> Dictionary:
	var start := Time.get_ticks_msec()
	var attempts := 0
	for i in range(20):
		attempts = i + 1
		if _camera_current_settled(cam, expected):
			return {
				"settled": true,
				"attempts": attempts,
				"elapsed_msec": Time.get_ticks_msec() - start,
				"message": _camera_current_wait_timeout_message(cam, expected, attempts, Time.get_ticks_msec() - start),
			}
		OS.delay_msec(10)
	var settled := _camera_current_settled(cam, expected)
	var elapsed := Time.get_ticks_msec() - start
	return {
		"settled": settled,
		"attempts": attempts,
		"elapsed_msec": elapsed,
		"message": _camera_current_wait_timeout_message(cam, expected, attempts, elapsed),
	}


func _camera_current_wait_timeout_message(cam: Node, expected: bool, attempts: int, elapsed_msec: int) -> String:
	return "Timed out waiting for camera current=%s after %d attempts/%dms. %s" % [
		expected,
		attempts,
		elapsed_msec,
		_camera_current_diag(cam, expected, attempts, elapsed_msec),
	]


func _camera_current_diag(cam: Node, expected: bool, attempts: int, elapsed_msec: int) -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam_path := "<null>"
	var cam_name := "<null>"
	var cam_class := "<null>"
	var inside_tree := false
	var node_is_current: Variant = "<missing>"
	var viewport_cam_path := "<none>"
	var viewport_matches := false
	var handler_current: Variant = "<unavailable>"
	var handler_empty_path := "<unavailable>"
	## Viewport identity captured so a post-reload-churn failure can prove
	## whether `cam.get_viewport()` still points at the live edited-scene
	## viewport or at a stale one from a previous editor lifecycle. If
	## `cam_viewport_id` differs from `scene_root_viewport_id`, every
	## `make_current()` lands on a viewport the engine's current-camera
	## tracking has already moved past — see #316 comment thread for the
	## reload-related theory this field exists to confirm.
	var cam_viewport_id: Variant = "<unavailable>"
	var scene_root_viewport_id: Variant = "<unavailable>"
	var cam_viewport_matches_scene: Variant = "<unavailable>"
	if scene_root != null:
		var scene_viewport := scene_root.get_viewport()
		if scene_viewport != null:
			scene_root_viewport_id = scene_viewport.get_instance_id()
	if cam != null and is_instance_valid(cam):
		cam_name = String(cam.name)
		cam_class = cam.get_class()
		inside_tree = cam.is_inside_tree()
		if scene_root != null and scene_root.is_ancestor_of(cam):
			cam_path = McpScenePath.from_node(cam, scene_root)
		if cam.has_method("is_current"):
			node_is_current = bool(cam.is_current())
		var cam_viewport: Viewport = null
		if cam is Camera2D:
			cam_viewport = cam.get_viewport()
			if cam_viewport != null:
				var viewport_cam_2d := cam_viewport.get_camera_2d()
				viewport_matches = viewport_cam_2d == cam
				if viewport_cam_2d != null and scene_root != null and scene_root.is_ancestor_of(viewport_cam_2d):
					viewport_cam_path = McpScenePath.from_node(viewport_cam_2d, scene_root)
				elif viewport_cam_2d != null:
					viewport_cam_path = str(viewport_cam_2d)
		elif cam is Camera3D:
			cam_viewport = cam.get_viewport()
			if cam_viewport != null:
				var viewport_cam_3d := cam_viewport.get_camera_3d()
				viewport_matches = viewport_cam_3d == cam
				if viewport_cam_3d != null and scene_root != null and scene_root.is_ancestor_of(viewport_cam_3d):
					viewport_cam_path = McpScenePath.from_node(viewport_cam_3d, scene_root)
				elif viewport_cam_3d != null:
					viewport_cam_path = str(viewport_cam_3d)
		if cam_viewport != null:
			cam_viewport_id = cam_viewport.get_instance_id()
			if scene_root_viewport_id is int:
				cam_viewport_matches_scene = (cam_viewport_id == scene_root_viewport_id)
		if cam_path != "<null>":
			var per_path := _handler.get_camera({"camera_path": cam_path})
			if per_path.has("data"):
				handler_current = bool(per_path.data.get("current", false))
			var empty_path := _handler.get_camera({"camera_path": ""})
			if empty_path.has("data"):
				handler_empty_path = "%s current=%s" % [
					empty_path.data.get("path", "<missing>"),
					empty_path.data.get("current", "<missing>"),
				]
	return (
		"camera_state expected_current=%s attempts=%d elapsed_msec=%d "
		+ "camera=%s path=%s class=%s in_tree=%s node_is_current=%s "
		+ "viewport_camera=%s viewport_matches=%s handler_current=%s handler_empty_path=%s "
		+ "cam_viewport_id=%s scene_root_viewport_id=%s cam_viewport_matches_scene=%s"
	) % [
		expected,
		attempts,
		elapsed_msec,
		cam_name,
		cam_path,
		cam_class,
		inside_tree,
		node_is_current,
		viewport_cam_path,
		viewport_matches,
		handler_current,
		handler_empty_path,
		cam_viewport_id,
		scene_root_viewport_id,
		cam_viewport_matches_scene,
	]


# ============================================================================
# camera_create
# ============================================================================

func test_create_2d() -> void:
	var result := _create("TestCam2D", "2d")
	if result.is_empty():
		assert_true(false, "No scene open")
		return
	assert_has_key(result, "data")
	assert_eq(result.data.class, "Camera2D")
	assert_eq(result.data.type, "2d")
	assert_eq(result.data.current, false)
	assert_true(result.data.undoable)


func test_create_3d() -> void:
	var result := _create("TestCam3D", "3d")
	if result.is_empty():
		assert_true(false, "No scene open")
		return
	assert_eq(result.data.class, "Camera3D")
	assert_eq(result.data.type, "3d")


func test_create_invalid_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var result := _handler.create_camera({
		"parent_path": "/" + scene_root.name,
		"name": "BadType",
		"type": "nonsense",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_with_make_current_unmarks_sibling() -> void:
	var first := _create("CamFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("CamSecond", "2d", true)
	var scene_root := EditorInterface.get_edited_scene_root()
	var first_node := McpScenePath.resolve(first.data.path, scene_root) as Camera2D
	var second_node := McpScenePath.resolve(second.data.path, scene_root) as Camera2D
	assert_true(first_node != null, "First camera should resolve from %s" % first.data.path)
	assert_true(second_node != null, "Second camera should resolve from %s" % second.data.path)
	var second_current := _wait_for_camera_current_report(second_node, true)
	assert_true(second_current.settled, second_current.message)
	var first_not_current := _wait_for_camera_current_report(first_node, false)
	assert_true(first_not_current.settled, first_not_current.message)
	assert_eq(second_node.is_current(), true, "Direct is_current mismatch after wait succeeded. %s" % _camera_current_diag(second_node, true, second_current.attempts, second_current.elapsed_msec))
	assert_eq(first_node.is_current(), false, "Previously-current camera should have been unmarked. Direct is_current mismatch after wait succeeded. %s" % _camera_current_diag(first_node, false, first_not_current.attempts, first_not_current.elapsed_msec))


func test_make_current_does_not_cross_classes() -> void:
	var cam2d := _create("TwoDim", "2d", true)
	if cam2d.is_empty():
		assert_true(false, "No scene open")
		return
	var cam3d := _create("ThreeDim", "3d", true)
	var scene_root := EditorInterface.get_edited_scene_root()
	var n2 := McpScenePath.resolve(cam2d.data.path, scene_root) as Camera2D
	var n3 := McpScenePath.resolve(cam3d.data.path, scene_root) as Camera3D
	assert_true(_wait_for_camera_current(n2, true))
	assert_true(_wait_for_camera_current(n3, true))
	assert_eq(n2.is_current(), true, "Camera2D current should not be touched when Camera3D becomes current")
	assert_eq(n3.is_current(), true)


# ============================================================================
# camera_configure
# ============================================================================

func test_configure_applies_zoom_vector() -> void:
	var r := _create("ConfZoom", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.configure({
		"camera_path": r.data.path,
		"properties": {"zoom": {"x": 2.0, "y": 2.0}},
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	assert_eq(node.zoom, Vector2(2.0, 2.0))


func test_configure_enum_by_name() -> void:
	var r := _create("ConfEnum", "3d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.configure({
		"camera_path": r.data.path,
		"properties": {"keep_aspect": "keep_height", "projection": "orthogonal"},
	})
	assert_has_key(result, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera3D
	assert_eq(node.keep_aspect, Camera3D.KEEP_HEIGHT)
	assert_eq(node.projection, Camera3D.PROJECTION_ORTHOGONAL)


func test_configure_rejects_3d_key_on_2d() -> void:
	var r := _create("RejectKey", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.configure({
		"camera_path": r.data.path,
		"properties": {"fov": 60.0},  # Camera3D-only key
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_configure_empty_dict() -> void:
	var r := _create("EmptyConf", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.configure({
		"camera_path": r.data.path,
		"properties": {},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_configure_transform_key_suggests_node_set_property() -> void:
	# Transform-shaped keys live on the Node, not in the camera config schema.
	# Rejecting them must point at node_set_property explicitly — otherwise
	# an agent falls back to fuzzy-matching the listed camera keys.
	var r := _create("RejectPos", "3d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	for bad_key in ["position", "rotation", "scale", "transform", "global_position"]:
		var result := _handler.configure({
			"camera_path": r.data.path,
			"properties": {bad_key: 0},
		})
		assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
		assert_contains(result.error.message, "node_set_property",
			"Rejecting camera_configure(%s) should suggest node_set_property" % bad_key)
		assert_contains(result.error.message, bad_key)


func test_configure_current_sibling_unmark_single_undo() -> void:
	var first := _create("UndoFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("UndoSecond", "2d", false)
	var scene_root := EditorInterface.get_edited_scene_root()
	var first_node := McpScenePath.resolve(first.data.path, scene_root) as Camera2D
	var second_node := McpScenePath.resolve(second.data.path, scene_root) as Camera2D

	# Flip current to second via configure.
	var result := _handler.configure({
		"camera_path": second.data.path,
		"properties": {"current": true},
	})
	assert_has_key(result, "data")
	var forward_second_current := _wait_for_camera_current_report(second_node, true)
	assert_true(forward_second_current.settled, forward_second_current.message)
	var forward_first_not_current := _wait_for_camera_current_report(first_node, false)
	assert_true(forward_first_not_current.settled, forward_first_not_current.message)
	assert_eq(second_node.is_current(), true, "Direct is_current mismatch after forward configure wait succeeded. %s" % _camera_current_diag(second_node, true, forward_second_current.attempts, forward_second_current.elapsed_msec))
	assert_eq(first_node.is_current(), false, "Direct is_current mismatch after forward configure wait succeeded. %s" % _camera_current_diag(first_node, false, forward_first_not_current.attempts, forward_first_not_current.elapsed_msec))

	# One undo reverts both. Use editor_undo() so we explicitly target the
	# scene's UndoRedo — EditorUndoRedoManager.undo() picks "newest" across
	# histories by timestamp, which ties on fast runs.
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "editor_undo returned false — no action was undone")
	# Diagnostic detail if this ever regresses (#316): report viewport state,
	# direct Camera current state, handler/logical current reads, and wait budget.
	var undo_second_not_current := _wait_for_camera_current_report(second_node, false)
	assert_true(undo_second_not_current.settled, undo_second_not_current.message)
	var undo_first_current := _wait_for_camera_current_report(first_node, true)
	assert_true(undo_first_current.settled, undo_first_current.message)
	assert_eq(second_node.is_current(), false, "After undo second should not be current. %s" % _camera_current_diag(second_node, false, undo_second_not_current.attempts, undo_second_not_current.elapsed_msec))
	assert_eq(first_node.is_current(), true, "Single undo should restore original current camera. %s" % _camera_current_diag(first_node, true, undo_first_current.attempts, undo_first_current.elapsed_msec))


# ============================================================================
# camera_set_limits_2d
# ============================================================================

func test_set_limits_2d_partial() -> void:
	var r := _create("Limits", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	var original_top: int = node.limit_top
	var original_bottom: int = node.limit_bottom
	var result := _handler.set_limits_2d({
		"camera_path": r.data.path,
		"left": -500,
		"right": 500,
	})
	assert_has_key(result, "data")
	assert_eq(node.limit_left, -500)
	assert_eq(node.limit_right, 500)
	assert_eq(node.limit_top, original_top, "top should be untouched")
	assert_eq(node.limit_bottom, original_bottom, "bottom should be untouched")


func test_set_limits_2d_empty() -> void:
	var r := _create("NoLimits", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.set_limits_2d({"camera_path": r.data.path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_limits_2d_errors_on_3d() -> void:
	var r := _create("Limits3D", "3d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.set_limits_2d({
		"camera_path": r.data.path,
		"left": -100,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# camera_set_damping_2d
# ============================================================================

func test_set_damping_2d_enables_smoothing_when_speed_set() -> void:
	var r := _create("Damp", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	assert_eq(node.position_smoothing_enabled, false, "precondition: smoothing off")
	var result := _handler.set_damping_2d({
		"camera_path": r.data.path,
		"position_speed": 4.0,
	})
	assert_has_key(result, "data")
	assert_eq(node.position_smoothing_enabled, true)
	assert_true(abs(node.position_smoothing_speed - 4.0) < 0.001)


func test_set_damping_2d_zero_speed_disables() -> void:
	var r := _create("DampZero", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	node.position_smoothing_enabled = true
	var result := _handler.set_damping_2d({
		"camera_path": r.data.path,
		"position_speed": 0.0,
	})
	assert_has_key(result, "data")
	assert_eq(node.position_smoothing_enabled, false)


func test_set_damping_2d_drag_margins_partial() -> void:
	var r := _create("DampMargins", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	var original_top := node.drag_top_margin
	var original_bottom := node.drag_bottom_margin
	var result := _handler.set_damping_2d({
		"camera_path": r.data.path,
		"drag_margins": {"left": 0.25, "right": 0.25},
	})
	assert_has_key(result, "data")
	assert_true(abs(node.drag_left_margin - 0.25) < 0.001)
	assert_true(abs(node.drag_right_margin - 0.25) < 0.001)
	assert_true(abs(node.drag_top_margin - original_top) < 0.001, "top margin should be untouched")
	assert_true(abs(node.drag_bottom_margin - original_bottom) < 0.001, "bottom margin should be untouched")


func test_set_damping_2d_margin_out_of_range() -> void:
	var r := _create("DampBadMargin", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.set_damping_2d({
		"camera_path": r.data.path,
		"drag_margins": {"left": 1.5},
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_damping_2d_errors_on_3d() -> void:
	var r := _create("Damp3D", "3d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.set_damping_2d({
		"camera_path": r.data.path,
		"position_speed": 5.0,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_damping_2d_empty() -> void:
	var r := _create("DampEmpty", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.set_damping_2d({"camera_path": r.data.path})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# camera_follow_2d
# ============================================================================

func _create_target(target_name: String) -> Node2D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var target := Node2D.new()
	target.name = target_name
	target.position = Vector2(100, 50)
	scene_root.add_child(target, true)
	target.owner = scene_root
	_track_node(target)
	return target


func test_follow_2d_reparents_and_zeros() -> void:
	var r := _create("FollowCam", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var target := _create_target("Player")
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	cam.position = Vector2(42, 24)
	cam.rotation = 0.5

	var result := _handler.follow_2d({
		"camera_path": r.data.path,
		"target_path": McpScenePath.from_node(target, scene_root),
		"smoothing_speed": 6.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.reparented, true)
	assert_eq(cam.get_parent(), target)
	assert_eq(cam.position, Vector2.ZERO)
	assert_true(abs(cam.rotation) < 0.001)
	assert_eq(cam.position_smoothing_enabled, true)
	assert_true(abs(cam.position_smoothing_speed - 6.0) < 0.001)


func test_follow_2d_noop_when_already_child() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var target := _create_target("Player2")
	var cam := Camera2D.new()
	cam.name = "ChildCam"
	target.add_child(cam, true)
	cam.owner = scene_root
	_track_node(cam)

	var target_path := McpScenePath.from_node(target, scene_root)
	var cam_path := McpScenePath.from_node(cam, scene_root)
	var result := _handler.follow_2d({
		"camera_path": cam_path,
		"target_path": target_path,
		"smoothing_speed": 7.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.reparented, false)
	assert_eq(cam.get_parent(), target)
	assert_true(abs(cam.position_smoothing_speed - 7.0) < 0.001)


func test_follow_2d_undo_restores_parent() -> void:
	var r := _create("FollowUndo", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var target := _create_target("Player3")
	var scene_root := EditorInterface.get_edited_scene_root()
	var cam := McpScenePath.resolve(r.data.path, scene_root) as Camera2D
	var original_parent := cam.get_parent()

	var _result := _handler.follow_2d({
		"camera_path": r.data.path,
		"target_path": McpScenePath.from_node(target, scene_root),
	})
	assert_eq(cam.get_parent(), target)

	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_eq(cam.get_parent(), original_parent, "Undo should restore original parent")
	# Refresh the _created_paths entry since the path changed after reparent/undo.
	_created_paths = [McpScenePath.from_node(cam, scene_root)]


func test_follow_2d_target_not_node2d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var r := _create("FollowBad", "2d")
	if r.is_empty():
		return
	# Make a plain Node (not Node2D).
	var plain := Node.new()
	plain.name = "PlainNode"
	scene_root.add_child(plain, true)
	plain.owner = scene_root
	_track_node(plain)
	var result := _handler.follow_2d({
		"camera_path": r.data.path,
		"target_path": McpScenePath.from_node(plain, scene_root),
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ============================================================================
# camera_get / camera_list
# ============================================================================

func test_get_returns_current_when_path_empty() -> void:
	var r := _create("GetCurrent", "2d", true)
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := {}
	for _i in range(20):
		result = _handler.get_camera({"camera_path": ""})
		if (
			result.has("data")
			and result.data.get("resolved_via", "") == "current"
			and result.data.get("path", "") == r.data.path
			and bool(result.data.get("current", false))
		):
			break
		OS.delay_msec(10)
	assert_has_key(result, "data")
	assert_eq(result.data.resolved_via, "current")
	assert_eq(result.data.path, r.data.path)
	assert_eq(result.data.type, "2d")
	assert_eq(result.data.current, true)


func test_get_fallback_to_first_when_none_current() -> void:
	# Remove the auto-current flag before spawning.
	var r := _create("GetFirst", "2d", false)
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	# Ensure none in scene are current.
	for cam in _all_cameras_in_scene(scene_root):
		if cam.has_method("clear_current"):
			cam.clear_current()
	var result := _handler.get_camera({"camera_path": ""})
	assert_has_key(result, "data")
	assert_contains(["first", "current"], result.data.resolved_via)


func test_get_by_path() -> void:
	var r := _create("GetByPath", "3d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var result := _handler.get_camera({"camera_path": r.data.path})
	assert_has_key(result, "data")
	assert_eq(result.data.path, r.data.path)
	assert_eq(result.data.type, "3d")
	assert_has_key(result.data.properties, "fov")


func test_get_rejects_non_camera() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var plain := Node2D.new()
	plain.name = "NotACamera"
	scene_root.add_child(plain, true)
	plain.owner = scene_root
	_track_node(plain)
	var result := _handler.get_camera({"camera_path": McpScenePath.from_node(plain, scene_root)})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_enumerates_2d_and_3d() -> void:
	var a := _create("ListA", "2d")
	if a.is_empty():
		assert_true(false, "No scene open")
		return
	var b := _create("ListB", "3d")
	var result := _handler.list_cameras({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "cameras")
	var types: Array = []
	for entry in result.data.cameras:
		types.append(entry.type)
	assert_contains(types, "2d")
	assert_contains(types, "3d")


# ============================================================================
# logical-current determinism (#301)
# ============================================================================

# After configure({current: true}) followed by undo, the MCP read layer
# must report the original current camera deterministically — even if
# the viewport slot is still racing under us. This is the read-path
# guarantee #305 was after.
func test_configure_current_undo_mcp_reads_are_deterministic() -> void:
	var first := _create("DetFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("DetSecond", "2d", false)

	var result := _handler.configure({
		"camera_path": second.data.path,
		"properties": {"current": true},
	})
	assert_has_key(result, "data")

	# After flipping current to second, MCP reads must agree on second.
	var got_second := _handler.get_camera({"camera_path": ""})
	assert_eq(got_second.data.path, second.data.path,
		"camera_get('') should resolve to second after configure(current=true)")
	assert_eq(got_second.data.current, true)

	assert_true(editor_undo(_undo_redo), "editor_undo returned false")

	# Logical marker is authoritative — only first reports current.
	var got_first := _handler.get_camera({"camera_path": ""})
	assert_eq(got_first.data.path, first.data.path,
		"camera_get('') should resolve to first after undo")
	assert_eq(got_first.data.current, true)

	var listed := _handler.list_cameras({})
	var current_paths: Array = []
	for entry in listed.data.cameras:
		if bool(entry.current):
			current_paths.append(entry.path)
	assert_eq(current_paths.size(), 1,
		"Exactly one Camera2D should report current after undo, got %s" % [current_paths])
	assert_eq(current_paths[0], first.data.path,
		"list_cameras should report first as current after undo, got %s" % [current_paths])

	# Per-path get_camera must agree with the list view — not OR-stack
	# logical with a still-laggy viewport for second.
	var second_view := _handler.get_camera({"camera_path": second.data.path})
	assert_eq(second_view.data.current, false,
		"camera_get(second) must report current=false after undo")


# Logical-current state must live on the handler, NOT as Node metadata
# on the scene root, because set_meta() persists into .tscn on save.
# Regression guard: walk the scene root's metadata after a make_current
# round-trip and assert no godot_ai/* keys leaked there.
func test_logical_current_does_not_pollute_scene_root_metadata() -> void:
	var first := _create("MetaProbeFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("MetaProbeSecond", "2d", false)
	var _r := _handler.configure({
		"camera_path": second.data.path,
		"properties": {"current": true},
	})
	assert_true(editor_undo(_undo_redo))

	var scene_root := EditorInterface.get_edited_scene_root()
	for meta_key in scene_root.get_meta_list():
		assert_false(String(meta_key).begins_with("godot_ai/"),
			"Scene root metadata polluted with MCP key '%s' — would persist into .tscn on save"
				% [meta_key])


# Two cameras must never both report current=true for the same class,
# even during the headless-CI race window where the viewport lags.
# Construct the scenario, then verify list_cameras invariant directly.
func test_list_cameras_never_reports_two_current_per_class() -> void:
	var first := _create("InvFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("InvSecond", "2d", false)
	var _r := _handler.configure({
		"camera_path": second.data.path,
		"properties": {"current": true},
	})
	assert_true(editor_undo(_undo_redo))

	var listed := _handler.list_cameras({})
	var twod_currents := 0
	var threed_currents := 0
	for entry in listed.data.cameras:
		if not bool(entry.current):
			continue
		if String(entry.type) == "2d":
			twod_currents += 1
		elif String(entry.type) == "3d":
			threed_currents += 1
	assert_true(twod_currents <= 1,
		"At most one Camera2D may be current; got %d" % twod_currents)
	assert_true(threed_currents <= 1,
		"At most one Camera3D may be current; got %d" % threed_currents)


# ============================================================================
# camera_apply_preset
# ============================================================================

func test_apply_preset_topdown_2d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "PresetTopdown",
		"preset": "topdown_2d",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "topdown_2d")
	assert_eq(result.data.type, "2d")
	assert_eq(result.data.class, "Camera2D")
	_created_paths.append(result.data.path)

	var node := McpScenePath.resolve(result.data.path, scene_root) as Camera2D
	assert_true(node != null)
	assert_eq(node.zoom, Vector2(2.0, 2.0))
	assert_eq(node.position_smoothing_enabled, true)
	assert_eq(node.anchor_mode, Camera2D.ANCHOR_MODE_DRAG_CENTER)
	assert_true(abs(node.drag_left_margin - 0.2) < 0.001)


func test_apply_preset_cinematic_3d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "PresetCinema",
		"preset": "cinematic_3d",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.type, "3d")
	_created_paths.append(result.data.path)
	var node := McpScenePath.resolve(result.data.path, scene_root) as Camera3D
	assert_true(abs(node.fov - 40.0) < 0.1)


func test_apply_preset_unknown() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "Bad",
		"preset": "nonsense_preset",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_apply_preset_with_override() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		assert_true(false, "No scene open")
		return
	var result := _handler.apply_preset({
		"parent_path": "/" + scene_root.name,
		"name": "PresetOverride",
		"preset": "topdown_2d",
		"overrides": {"zoom": {"x": 3.5, "y": 3.5}},
	})
	assert_has_key(result, "data")
	_created_paths.append(result.data.path)
	var node := McpScenePath.resolve(result.data.path, scene_root) as Camera2D
	assert_eq(node.zoom, Vector2(3.5, 3.5))


# ============================================================================
# Helpers
# ============================================================================

func _all_cameras_in_scene(root: Node) -> Array:
	var out: Array = []
	_collect(root, out)
	return out


func _collect(node: Node, out: Array) -> void:
	if node is Camera2D or node is Camera3D:
		out.append(node)
	for child in node.get_children():
		_collect(child, out)
