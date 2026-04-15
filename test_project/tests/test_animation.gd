@tool
extends McpTestSuite

## Tests for AnimationHandler — AnimationPlayer authoring.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: AnimationHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "animation"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = AnimationHandler.new(_undo_redo)


func suite_teardown() -> void:
	pass


# ─── Helpers ──────────────────────────────────────────────────────────────────

## Add an AnimationPlayer to the scene root and return its path.
## Caller is responsible for removing the node in teardown.
func _add_player(player_name: String = "TestAnimPlayer") -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ""
	var result := _handler.create_player({"parent_path": "/" + scene_root.name, "name": player_name})
	if result.has("error"):
		return ""
	return result.data.path


func _remove_node(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := ScenePath.resolve(path, scene_root)
	if node != null:
		node.get_parent().remove_child(node)
		node.queue_free()


# ─── animation_player_create ──────────────────────────────────────────────────

func test_player_create_returns_path() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var result := _handler.create_player({
		"parent_path": "/" + scene_root.name,
		"name": "TestPlayerCreate",
	})
	assert_has_key(result, "data")
	assert_true(result.data.path.ends_with("TestPlayerCreate"))
	assert_true(result.data.undoable)
	_remove_node(result.data.path)


func test_player_create_attaches_default_library() -> void:
	var path := _add_player("TestPlayerLib")
	if path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(path, scene_root) as AnimationPlayer
	assert_true(player != null, "Node should exist")
	assert_true(player.has_animation_library(""), "Default library should be attached")
	_remove_node(path)


func test_player_create_missing_parent() -> void:
	var result := _handler.create_player({"parent_path": "/DoesNotExist"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not found")


func test_player_create_is_undoable() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var before_count := scene_root.get_child_count()
	var result := _handler.create_player({
		"parent_path": "/" + scene_root.name,
		"name": "TestPlayerUndo",
	})
	assert_has_key(result, "data")
	assert_eq(scene_root.get_child_count(), before_count + 1)
	_undo_redo.undo()
	assert_eq(scene_root.get_child_count(), before_count, "Undo should remove the player")


# ─── animation_create ─────────────────────────────────────────────────────────

func test_animation_create_basic() -> void:
	var player_path := _add_player("TestAnimCreate")
	if player_path.is_empty():
		return
	var result := _handler.create_animation({
		"player_path": player_path,
		"name": "idle",
		"length": 2.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "idle")
	assert_eq(result.data.length, 2.0)
	assert_eq(result.data.loop_mode, "none")
	assert_true(result.data.undoable)
	_remove_node(player_path)


func test_animation_create_with_loop_mode() -> void:
	var player_path := _add_player("TestAnimLoop")
	if player_path.is_empty():
		return
	var result := _handler.create_animation({
		"player_path": player_path,
		"name": "pulse",
		"length": 0.5,
		"loop_mode": "pingpong",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.loop_mode, "pingpong")

	# Verify actual Animation resource was created with correct settings.
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	assert_true(player.has_animation("pulse"))
	var anim: Animation = player.get_animation("pulse")
	assert_eq(anim.length, 0.5)
	assert_eq(anim.loop_mode, Animation.LOOP_PINGPONG)
	_remove_node(player_path)


func test_animation_create_rejects_duplicate_name() -> void:
	var player_path := _add_player("TestAnimDup")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "walk", "length": 1.0})
	var result := _handler.create_animation({"player_path": player_path, "name": "walk", "length": 1.0})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "already exists")
	_remove_node(player_path)


func test_animation_create_rejects_invalid_loop_mode() -> void:
	var player_path := _add_player("TestAnimBadLoop")
	if player_path.is_empty():
		return
	var result := _handler.create_animation({
		"player_path": player_path,
		"name": "test",
		"length": 1.0,
		"loop_mode": "bogus",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "loop_mode")
	_remove_node(player_path)


func test_animation_create_is_undoable() -> void:
	var player_path := _add_player("TestAnimUndoCreate")
	if player_path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer

	_handler.create_animation({"player_path": player_path, "name": "fade", "length": 0.3})
	assert_true(player.has_animation("fade"), "Animation should exist after create")
	_undo_redo.undo()
	assert_true(not player.has_animation("fade"), "Undo should remove animation")
	_undo_redo.redo()
	assert_true(player.has_animation("fade"), "Redo should restore animation")
	_remove_node(player_path)


# ─── animation_add_property_track ────────────────────────────────────────────

func test_add_property_track_basic() -> void:
	var player_path := _add_player("TestPropTrack")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})

	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:modulate",
		"keyframes": [
			{"time": 0.0, "value": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.0}},
			{"time": 1.0, "value": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}},
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.keyframe_count, 2)
	assert_true(result.data.undoable)

	# Verify track was actually added to the Animation.
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")
	assert_eq(anim.get_track_count(), 1)
	_remove_node(player_path)


func test_add_property_track_requires_colon_in_path() -> void:
	var player_path := _add_player("TestPropTrackNoColon")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": "Panel",
		"keyframes": [{"time": 0.0, "value": 1.0}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "':property'")
	_remove_node(player_path)


func test_add_property_track_is_undoable() -> void:
	var player_path := _add_player("TestPropTrackUndo")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")

	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:modulate",
		"keyframes": [{"time": 0.0, "value": 1.0}, {"time": 1.0, "value": 0.0}],
	})
	assert_eq(anim.get_track_count(), 1)
	_undo_redo.undo()
	assert_eq(anim.get_track_count(), 0, "Undo should remove the track")
	_remove_node(player_path)


func test_add_property_track_transition_named() -> void:
	var player_path := _add_player("TestTransNamed")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:position",
		"keyframes": [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0}, "transition": "ease_out"},
			{"time": 1.0, "value": {"x": 100.0, "y": 0.0}, "transition": "ease_out"},
		],
	})
	assert_has_key(result, "data")
	# Named transition should not cause an error.
	assert_true(result.data.undoable)
	_remove_node(player_path)


func test_add_property_track_transition_raw_float() -> void:
	var player_path := _add_player("TestTransFloat")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:position",
		"keyframes": [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0}, "transition": 3.0},
			{"time": 1.0, "value": {"x": 100.0, "y": 0.0}, "transition": 3.0},
		],
	})
	assert_has_key(result, "data")
	_remove_node(player_path)


# ─── animation_add_method_track ──────────────────────────────────────────────

func test_add_method_track_basic() -> void:
	var player_path := _add_player("TestMethodTrack")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 2.0})
	var result := _handler.add_method_track({
		"player_path": player_path,
		"animation_name": "anim",
		"target_node_path": ".",
		"keyframes": [
			{"time": 1.0, "method": "queue_free", "args": []},
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.keyframe_count, 1)
	assert_true(result.data.undoable)

	# Verify track was added as a method track.
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")
	assert_eq(anim.get_track_count(), 1)
	assert_eq(anim.track_get_type(0), Animation.TYPE_METHOD)
	_remove_node(player_path)


func test_add_method_track_requires_method_key() -> void:
	var player_path := _add_player("TestMethodNoMethod")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_method_track({
		"player_path": player_path,
		"animation_name": "anim",
		"target_node_path": ".",
		"keyframes": [{"time": 0.5}],  # Missing "method"
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "method")
	_remove_node(player_path)


# ─── animation_set_autoplay ───────────────────────────────────────────────────

func test_set_autoplay_basic() -> void:
	var player_path := _add_player("TestAutoplay")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "idle", "length": 1.0})
	var result := _handler.set_autoplay({
		"player_path": player_path,
		"animation_name": "idle",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.animation_name, "idle")
	assert_true(result.data.undoable)

	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	assert_eq(player.autoplay, "idle")
	_remove_node(player_path)


func test_set_autoplay_validates_unknown_name() -> void:
	var player_path := _add_player("TestAutoplayBad")
	if player_path.is_empty():
		return
	var result := _handler.set_autoplay({
		"player_path": player_path,
		"animation_name": "nonexistent",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not found")
	_remove_node(player_path)


func test_set_autoplay_empty_clears() -> void:
	var player_path := _add_player("TestAutoplayClear")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "idle", "length": 1.0})
	_handler.set_autoplay({"player_path": player_path, "animation_name": "idle"})
	var result := _handler.set_autoplay({"player_path": player_path, "animation_name": ""})
	assert_has_key(result, "data")
	assert_true(result.data.cleared)

	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	assert_eq(player.autoplay, "")
	_remove_node(player_path)


# ─── animation_play / animation_stop ─────────────────────────────────────────

func test_play_stop_are_not_undoable() -> void:
	var player_path := _add_player("TestPlayStop")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "idle", "length": 1.0})

	var play_result := _handler.play({"player_path": player_path, "animation_name": "idle"})
	assert_has_key(play_result, "data")
	assert_eq(play_result.data.undoable, false)

	var stop_result := _handler.stop({"player_path": player_path})
	assert_has_key(stop_result, "data")
	assert_eq(stop_result.data.undoable, false)
	_remove_node(player_path)


func test_play_validates_unknown_animation() -> void:
	var player_path := _add_player("TestPlayBad")
	if player_path.is_empty():
		return
	var result := _handler.play({"player_path": player_path, "animation_name": "nope"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ─── animation_list / animation_get ──────────────────────────────────────────

func test_list_returns_created_animations() -> void:
	var player_path := _add_player("TestList")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "walk", "length": 1.0})
	_handler.create_animation({"player_path": player_path, "name": "run", "length": 0.5})

	var result := _handler.list_animations({"player_path": player_path})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 2)
	var names: Array[String] = []
	for a in result.data.animations:
		names.append(a.name)
	assert_true(names.has("walk"))
	assert_true(names.has("run"))
	_remove_node(player_path)


func test_get_returns_track_detail() -> void:
	var player_path := _add_player("TestGet")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "fade", "length": 1.0})
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "fade",
		"track_path": ".:modulate",
		"keyframes": [
			{"time": 0.0, "value": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.0}},
			{"time": 1.0, "value": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0}},
		],
	})

	var result := _handler.get_animation({"player_path": player_path, "animation_name": "fade"})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "fade")
	assert_eq(result.data.track_count, 1)
	assert_eq(result.data.tracks[0].type, "value")
	assert_eq(result.data.tracks[0].key_count, 2)
	_remove_node(player_path)


# ─── animation_create_simple ──────────────────────────────────────────────────

func test_create_simple_auto_length() -> void:
	var player_path := _add_player("TestSimple")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "slide",
		"tweens": [
			{
				"target": ".",
				"property": "position",
				"from": {"x": -400.0, "y": 0.0},
				"to": {"x": 0.0, "y": 0.0},
				"duration": 0.4,
				"delay": 0.1,
			}
		],
	})
	assert_has_key(result, "data")
	# Auto length should be delay + duration = 0.5
	assert_eq(result.data.length, 0.5)
	assert_eq(result.data.track_count, 1)
	assert_true(result.data.undoable)
	_remove_node(player_path)


func test_create_simple_explicit_length() -> void:
	var player_path := _add_player("TestSimpleExplicit")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "fade",
		"length": 2.0,
		"tweens": [
			{
				"target": ".",
				"property": "modulate",
				"from": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 0.0},
				"to": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
				"duration": 0.5,
			}
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.length, 2.0)
	_remove_node(player_path)


func test_create_simple_multiple_tweens() -> void:
	var player_path := _add_player("TestSimpleMulti")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "combo",
		"tweens": [
			{"target": ".", "property": "modulate", "from": {"r":1,"g":1,"b":1,"a":0}, "to": {"r":1,"g":1,"b":1,"a":1}, "duration": 0.5},
			{"target": ".", "property": "position", "from": {"x": -200.0, "y": 0.0}, "to": {"x": 0.0, "y": 0.0}, "duration": 0.3, "delay": 0.1},
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.track_count, 2)
	_remove_node(player_path)


func test_create_simple_is_undoable() -> void:
	var player_path := _add_player("TestSimpleUndo")
	if player_path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer

	_handler.create_simple({
		"player_path": player_path,
		"name": "pulse",
		"loop_mode": "pingpong",
		"tweens": [
			{"target": ".", "property": "modulate", "from": "white", "to": "red", "duration": 0.5},
		],
	})
	assert_true(player.has_animation("pulse"))
	_undo_redo.undo()
	assert_true(not player.has_animation("pulse"), "Undo should remove the composed animation")
	_undo_redo.redo()
	assert_true(player.has_animation("pulse"), "Redo should restore the composed animation")
	_remove_node(player_path)


func test_create_simple_rejects_missing_tween_fields() -> void:
	var player_path := _add_player("TestSimpleMissing")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "bad",
		"tweens": [{"target": ".", "property": "modulate"}],  # Missing from/to/duration
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
