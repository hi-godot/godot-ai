@tool
extends McpTestSuite

const AnimationHandler := preload("res://addons/godot_ai/handlers/animation_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const DOOR_PATH := "Door:rotation_degrees:y"

var _handler: AnimationHandler
var _undo_redo: EditorUndoRedoManager
var _scene_root: Node
var _player: AnimationPlayer
var _player_path: String
var _door: MeshInstance3D
var _clip: Animation
var _named_clip: Animation


func suite_name() -> String:
	return "animation_bezier"


func suite_setup(ctx: Dictionary) -> void:
	_scene_root = EditorInterface.get_edited_scene_root()
	if _scene_root == null:
		skip_suite("Open an edited scene to run Bézier track tests")
		return
	_undo_redo = ctx.get("undo_redo")
	_handler = AnimationHandler.new(_undo_redo)


func setup() -> void:
	var fixture := Node3D.new()
	fixture.name = "BezierTestFixture"
	track(fixture)
	_scene_root.add_child(fixture, true)
	fixture.owner = _scene_root
	var rig := Node3D.new()
	rig.name = "Rig"
	fixture.add_child(rig)
	rig.owner = _scene_root
	_door = MeshInstance3D.new()
	_door.name = "Door"
	_door.material_override = StandardMaterial3D.new()
	rig.add_child(_door)
	_door.owner = _scene_root
	_player = AnimationPlayer.new()
	_player.name = "Animator"
	fixture.add_child(_player)
	_player.owner = _scene_root
	_player.root_node = NodePath("../Rig")
	_player_path = McpScenePath.from_node(_player, _scene_root)
	_clip = _add_clip("")
	_named_clip = _add_clip("doors")


func _add_clip(library_name: String) -> Animation:
	var lib := AnimationLibrary.new()
	var clip := Animation.new()
	clip.length = 1.0
	lib.add_animation("Swing", clip)
	_player.add_animation_library(library_name, lib)
	return clip


func _params(keyframes: Variant, path: String = DOOR_PATH, name: String = "Swing") -> Dictionary:
	return {"player_path": _player_path, "animation_name": name, "track_path": path, "keyframes": keyframes}


func test_named_library_and_live_door_easing_with_native_readback() -> void:
	var keys := [
		{"time": 1, "value": 90, "in_handle": [-1.0 / 3, 0]},
		{"time": 0, "value": 0, "out_handle": [1.0 / 3, 0]},
	]
	var params := _params(keys, DOOR_PATH, "doors/Swing")
	var result := _handler.add_bezier_track(params)
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(result.data.track_type, "bezier")
	assert_eq(result.data.keyframe_count, 2)
	assert_true(result.data.undoable)
	assert_eq(_clip.get_track_count(), 0)
	assert_eq(_named_clip.track_get_type(0), Animation.TYPE_BEZIER)
	assert_eq(_named_clip.track_get_path(0), NodePath(DOOR_PATH))
	assert_true(absf(_named_clip.bezier_track_interpolate(0, 0.25) - 14.0625) < 0.04)
	assert_true(absf(_named_clip.bezier_track_interpolate(0, 0.75) - 75.9375) < 0.04)
	_player.play("doors/Swing")
	_player.seek(0.25, true)
	assert_true(absf(_door.rotation_degrees.y - 14.0625) < 0.04)
	_player.seek(0.75, true)
	assert_true(absf(_door.rotation_degrees.y - 75.9375) < 0.04)
	_player.stop()

	var inspected := _handler.get_animation({"player_path": _player_path, "animation_name": "doors/Swing"})
	assert_has_key(inspected, "data")
	if inspected.has("data"):
		var key: Dictionary = inspected.data.tracks[0].keys[0]
		assert_eq(key.scalar_value, 0.0)
		assert_eq(key.transition, 1.0)
		assert_eq(key.in_handle, [0.0, 0.0])
		assert_eq(key.value, [0.0, 0.0, 0.0, key.out_handle[0], 0.0])
		assert_true(absf(key.out_handle[0] - 1.0 / 3) < 0.00001)


func test_accepts_nested_and_dynamic_writable_scalar_properties() -> void:
	var nested := _handler.add_bezier_track(_params(
		[{"time": 2.0, "value": 0.33}], "Door:material_override:roughness"
	))
	assert_has_key(nested, "data")
	if nested.has("data"):
		assert_eq(nested.data.track_path, "Door:material_override:roughness")
		assert_eq(_clip.track_get_key_time(0, 0), 2.0)
		assert_eq(_clip.bezier_track_get_key_in_handle(0, 0), Vector2.ZERO)
		assert_eq(_clip.bezier_track_get_key_out_handle(0, 0), Vector2.ZERO)
		assert_eq(_clip.length, 1.0)
	_door.set_meta("amount", 0.25)
	var dynamic_property := _handler.add_bezier_track(_params(
		[{"time": 0.0, "value": 0.5}], "Door:metadata/amount"
	))
	assert_has_key(dynamic_property, "data")
	if dynamic_property.has("data"):
		assert_eq(_clip.track_get_path(1), NodePath("Door:metadata/amount"))


func test_refuses_non_scalar_unresolved_absolute_and_read_only_targets() -> void:
	var keyframes := [{"time": 0, "value": 1.0}]
	for path in [
		"Missing:rotation_degrees:y", "Door:rotation_degrees", "Door:rotation_degrees:w",
		"Door:visible", "Door:", "Door::rotation_degrees:y", "/root/Outside:foo",
	]:
		assert_is_error(_handler.add_bezier_track(_params(keyframes, path)), "", path)
	var read_only := _handler.add_bezier_track(_params(keyframes, "../Animator:current_animation_position"))
	assert_is_error(read_only, ErrorCodes.VALUE_OUT_OF_RANGE)
	if read_only.has("error"):
		assert_contains(read_only.error.message, "read-only")
	_player.root_node = NodePath("../UnknownRoot")
	assert_is_error(_handler.add_bezier_track(_params(keyframes)), ErrorCodes.NODE_NOT_FOUND)
	assert_eq(_clip.get_track_count(), 0)


func test_refuses_invalid_numeric_keys_handles_and_native_time_collisions() -> void:
	for key in [
		{"time": -1.0, "value": 1.0},
		{"time": true, "value": 1.0},
		{"time": INF, "value": 1.0},
		{"time": 1e40, "value": 1.0},
		{"time": 0.0, "value": "1"},
		{"time": 0.0, "value": NAN},
		{"time": 0.0, "value": 1e40},
		{"time": 0.0, "value": 1.0, "in_handle": [0.1, 0.0]},
		{"time": 0.0, "value": 1.0, "out_handle": [-0.1, 0.0]},
		{"time": 0.0, "value": 1.0, "in_handle": [0.0, 1e40]},
		{"time": 0.0, "value": 1.0, "out_handle": [0.0]},
		{"time": 0.0, "value": 1.0, "out_handle": "0,0"},
		{"time": 0.0, "value": 1.0, "transition": 1},
	]:
		assert_is_error(_handler.add_bezier_track(_params([key])), ErrorCodes.VALUE_OUT_OF_RANGE, str(key))
	assert_is_error(_handler.add_bezier_track(_params([{"time": 0}])), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_handler.add_bezier_track(_params([])), ErrorCodes.WRONG_TYPE)
	for conflicting_time in [1.0, 1.000001]:
		var result := _handler.add_bezier_track(_params(
			[{"time": conflicting_time, "value": 2}, {"time": 1.0, "value": 1}]
		))
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		if result.has("error"):
			assert_contains(result.error.message, "conflicts")
	assert_eq(_clip.get_track_count(), 0)


func test_refuses_control_points_that_overflow_native_segments() -> void:
	for keys in [
		[{"time": 0, "value": 3e38, "out_handle": [0.3, 3e38]}, {"time": 1, "value": 0.0}],
		[{"time": 0, "value": 0.0}, {"time": 1, "value": -3e38, "in_handle": [-0.3, -3e38]}],
	]:
		var result := _handler.add_bezier_track(_params(keys))
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		if result.has("error"):
			assert_contains(result.error.message, "plus the key value")
	assert_eq(_clip.get_track_count(), 0)


func test_scene_undo_and_redo_preserve_interleaved_tracks_on_same_path() -> void:
	var initial := _clip.add_track(Animation.TYPE_BEZIER)
	_clip.track_set_path(initial, NodePath(DOOR_PATH))
	_clip.bezier_track_insert_key(initial, 0.0, -5.0)
	var params := _params([{"time": 0.0, "value": 10.0}])
	var result := _handler.add_bezier_track(params)
	assert_has_key(result, "data")
	if not result.has("data"):
		return

	var later := _clip.add_track(Animation.TYPE_BEZIER, 0)
	_clip.track_set_path(later, NodePath(DOOR_PATH))
	_clip.bezier_track_insert_key(later, 0.0, -10.0)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_scene_root))
	assert_true(history != null)
	if history == null:
		return
	assert_true(history.undo())
	assert_eq(_clip.get_track_count(), 2)
	assert_eq(_clip.bezier_track_get_key_value(0, 0), -10.0)
	assert_eq(_clip.bezier_track_get_key_value(1, 0), -5.0)
	assert_true(history.redo())
	assert_eq(_clip.get_track_count(), 3)
	assert_eq(_clip.bezier_track_get_key_value(0, 0), -10.0)
	assert_eq(_clip.bezier_track_get_key_value(1, 0), -5.0)
	assert_eq(_clip.bezier_track_get_key_value(2, 0), 10.0)
	assert_is_error(_handler.add_bezier_track(params), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_eq(_clip.get_track_count(), 3)
