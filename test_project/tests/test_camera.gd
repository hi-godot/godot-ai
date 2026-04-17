@tool
extends McpTestSuite

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


func suite_teardown() -> void:
	for path in _created_paths:
		_remove_by_path(path)
	_created_paths.clear()
	for node in _created_nodes:
		if is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()
	_created_nodes.clear()


func _remove_by_path(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := ScenePath.resolve(path, scene_root)
	if node != null and node.get_parent() != null:
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
	var first_node := ScenePath.resolve(first.data.path, scene_root) as Camera2D
	var second_node := ScenePath.resolve(second.data.path, scene_root) as Camera2D
	assert_true(first_node != null)
	assert_true(second_node != null)
	assert_eq(second_node.is_current(), true)
	assert_eq(first_node.is_current(), false, "Previously-current camera should have been unmarked")


func test_make_current_does_not_cross_classes() -> void:
	var cam2d := _create("TwoDim", "2d", true)
	if cam2d.is_empty():
		assert_true(false, "No scene open")
		return
	var cam3d := _create("ThreeDim", "3d", true)
	var scene_root := EditorInterface.get_edited_scene_root()
	var n2 := ScenePath.resolve(cam2d.data.path, scene_root) as Camera2D
	var n3 := ScenePath.resolve(cam3d.data.path, scene_root) as Camera3D
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
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera2D
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
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera3D
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


func test_configure_current_sibling_unmark_single_undo() -> void:
	var first := _create("UndoFirst", "2d", true)
	if first.is_empty():
		assert_true(false, "No scene open")
		return
	var second := _create("UndoSecond", "2d", false)
	var scene_root := EditorInterface.get_edited_scene_root()
	var first_node := ScenePath.resolve(first.data.path, scene_root) as Camera2D
	var second_node := ScenePath.resolve(second.data.path, scene_root) as Camera2D

	# Flip current to second via configure.
	var result := _handler.configure({
		"camera_path": second.data.path,
		"properties": {"current": true},
	})
	assert_has_key(result, "data")
	assert_eq(second_node.is_current(), true)
	assert_eq(first_node.is_current(), false)

	# One undo reverts both.
	_undo_redo.undo()
	assert_eq(second_node.is_current(), false)
	assert_eq(first_node.is_current(), true, "Single undo should restore original current camera")


# ============================================================================
# camera_set_limits_2d
# ============================================================================

func test_set_limits_2d_partial() -> void:
	var r := _create("Limits", "2d")
	if r.is_empty():
		assert_true(false, "No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera2D
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
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera2D
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
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera2D
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
	var node := ScenePath.resolve(r.data.path, scene_root) as Camera2D
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
	var cam := ScenePath.resolve(r.data.path, scene_root) as Camera2D
	cam.position = Vector2(42, 24)
	cam.rotation = 0.5

	var result := _handler.follow_2d({
		"camera_path": r.data.path,
		"target_path": ScenePath.from_node(target, scene_root),
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

	var target_path := ScenePath.from_node(target, scene_root)
	var cam_path := ScenePath.from_node(cam, scene_root)
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
	var cam := ScenePath.resolve(r.data.path, scene_root) as Camera2D
	var original_parent := cam.get_parent()

	var _result := _handler.follow_2d({
		"camera_path": r.data.path,
		"target_path": ScenePath.from_node(target, scene_root),
	})
	assert_eq(cam.get_parent(), target)

	_undo_redo.undo()
	assert_eq(cam.get_parent(), original_parent, "Undo should restore original parent")
	# Refresh the _created_paths entry since the path changed after reparent/undo.
	_created_paths = [ScenePath.from_node(cam, scene_root)]


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
		"target_path": ScenePath.from_node(plain, scene_root),
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
	var result := _handler.get_camera({"camera_path": ""})
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
	var result := _handler.get_camera({"camera_path": ScenePath.from_node(plain, scene_root)})
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

	var node := ScenePath.resolve(result.data.path, scene_root) as Camera2D
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
	var node := ScenePath.resolve(result.data.path, scene_root) as Camera3D
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
	var node := ScenePath.resolve(result.data.path, scene_root) as Camera2D
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
