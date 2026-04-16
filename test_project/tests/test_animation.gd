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
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}, "transition": "ease_out"},
			{"time": 1.0, "value": {"x": 100.0, "y": 0.0, "z": 0.0}, "transition": "ease_out"},
		],
	})
	assert_has_key(result, "data")
	# Named transition should not cause an error.
	assert_true(result.data.undoable)
	_remove_node(player_path)


func test_add_property_track_coerces_vector3_dict() -> void:
	# Exercises _coerce_value_for_track against a real Node3D property.
	# Scene root is Node3D, so `.position` is a Vector3.
	var player_path := _add_player("TestCoerceVec3")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:position",
		"keyframes": [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}},
			{"time": 1.0, "value": {"x": 1.0, "y": 2.0, "z": 3.0}},
		],
	})
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")
	var k0 = anim.track_get_key_value(0, 0)
	var k1 = anim.track_get_key_value(0, 1)
	assert_true(k0 is Vector3, "keyframe 0 should be coerced to Vector3")
	assert_true(k1 is Vector3, "keyframe 1 should be coerced to Vector3")
	assert_eq(k1.x, 1.0)
	assert_eq(k1.y, 2.0)
	assert_eq(k1.z, 3.0)
	_remove_node(player_path)


func test_create_simple_coerces_vector3() -> void:
	# Auto-length + coerce path in one test.
	var player_path := _add_player("TestCoerceSimple")
	if player_path.is_empty():
		return
	_handler.create_simple({
		"player_path": player_path,
		"name": "slide",
		"tweens": [
			{
				"target": ".",
				"property": "position",
				"from": {"x": 0.0, "y": 0.0, "z": 0.0},
				"to": {"x": 5.0, "y": 0.0, "z": 0.0},
				"duration": 0.5,
			},
		],
	})
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("slide")
	var start = anim.track_get_key_value(0, 0)
	var end = anim.track_get_key_value(0, 1)
	assert_true(start is Vector3, "from value should coerce to Vector3")
	assert_true(end is Vector3, "to value should coerce to Vector3")
	assert_eq(end.x, 5.0)
	_remove_node(player_path)


func test_add_property_track_rejects_unparseable_color() -> void:
	# When the target property exists and has a known type (here, Color on
	# Sprite2D.modulate), an unparseable string value should fail at author
	# time rather than silently ending up as raw text in the keyframe.
	var scene_root := EditorInterface.get_edited_scene_root()
	var sprite := Sprite2D.new()
	sprite.name = "ColorSprite"
	scene_root.add_child(sprite)
	sprite.owner = scene_root

	var player_path := _add_player("TestBadColor")
	if player_path.is_empty():
		sprite.get_parent().remove_child(sprite)
		sprite.queue_free()
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": "ColorSprite:modulate",
		"keyframes": [
			{"time": 0.0, "value": "not_a_color"},
		],
	})
	assert_is_error(result, "", "expected INVALID_PARAMS for unparseable color string")
	_remove_node(player_path)
	sprite.get_parent().remove_child(sprite)
	sprite.queue_free()


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
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}, "transition": 3.0},
			{"time": 1.0, "value": {"x": 100.0, "y": 0.0, "z": 0.0}, "transition": 3.0},
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


func test_add_method_track_rejects_colon_in_target_path() -> void:
	var player_path := _add_player("TestMethodColonPath")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_method_track({
		"player_path": player_path,
		"animation_name": "anim",
		"target_node_path": "Panel:queue_free",  # wrong — method goes in keyframe
		"keyframes": [{"time": 0.0, "method": "queue_free"}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "bare NodePath")
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
				"from": {"x": -400.0, "y": 0.0, "z": 0.0},
				"to": {"x": 0.0, "y": 0.0, "z": 0.0},
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
			{"target": ".", "property": "position", "from": {"x": -200.0, "y": 0.0, "z": 0.0}, "to": {"x": 0.0, "y": 0.0, "z": 0.0}, "duration": 0.3, "delay": 0.1},
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


func test_create_simple_rejects_duplicate_target_property() -> void:
	var player_path := _add_player("TestSimpleDup")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "dup",
		"tweens": [
			{"target": ".", "property": "position", "from": {"x": 0.0, "y": 0.0, "z": 0.0},
			 "to": {"x": 1.0, "y": 0.0, "z": 0.0}, "duration": 0.3},
			{"target": ".", "property": "position", "from": {"x": 1.0, "y": 0.0, "z": 0.0},
			 "to": {"x": 2.0, "y": 0.0, "z": 0.0}, "duration": 0.3},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Duplicate")
	_remove_node(player_path)


# ─── Auto-create default library ─────────────────────────────────────────────

## Helper: create an AnimationPlayer WITHOUT a default library (the vanilla
## state you get from node_create or dragging one in from the inspector).
func _add_bare_player(player_name: String) -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ""
	var player := AnimationPlayer.new()
	player.name = player_name
	scene_root.add_child(player, true)
	player.set_owner(scene_root)
	return ScenePath.from_node(player, scene_root)


func test_create_animation_auto_attaches_default_library() -> void:
	var path := _add_bare_player("TestBarePlayer1")
	if path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(path, scene_root) as AnimationPlayer
	assert_true(not player.has_animation_library(""), "precondition: no default library")

	var result := _handler.create_animation({
		"player_path": path,
		"name": "idle",
		"length": 1.0,
	})
	assert_has_key(result, "data")
	assert_true(result.data.library_created, "library_created should be true on first write")
	assert_true(player.has_animation_library(""), "default library should now exist")
	assert_true(player.has_animation("idle"))

	# Undo should remove both the animation AND the library.
	_undo_redo.undo()
	assert_true(not player.has_animation("idle"))
	assert_true(not player.has_animation_library(""),
		"undo should also remove the auto-created library")

	# Redo should restore both.
	_undo_redo.redo()
	assert_true(player.has_animation_library(""))
	assert_true(player.has_animation("idle"))

	_remove_node(path)


func test_create_simple_auto_attaches_default_library() -> void:
	var path := _add_bare_player("TestBarePlayer2")
	if path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(path, scene_root) as AnimationPlayer

	var result := _handler.create_simple({
		"player_path": path,
		"name": "slide",
		"tweens": [
			{"target": ".", "property": "position",
			 "from": {"x": 0.0, "y": 0.0, "z": 0.0},
			 "to": {"x": 1.0, "y": 0.0, "z": 0.0}, "duration": 0.3},
		],
	})
	assert_has_key(result, "data")
	assert_true(result.data.library_created)
	assert_true(player.has_animation("slide"))

	_undo_redo.undo()
	assert_true(not player.has_animation_library(""))
	_remove_node(path)


func test_create_animation_reports_library_created_false_when_present() -> void:
	var player_path := _add_player("TestLibExists")
	if player_path.is_empty():
		return
	var result := _handler.create_animation({
		"player_path": player_path,
		"name": "idle",
		"length": 1.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.library_created, false,
		"library_created should be false when the player already has one")
	_remove_node(player_path)


# ─── animation_play empty name ───────────────────────────────────────────────

func test_play_with_empty_name_delegates_to_godot() -> void:
	# Empty name is forwarded to AnimationPlayer.play("") which Godot interprets
	# as "resume current, or default"; must not error if an animation exists.
	var player_path := _add_player("TestPlayEmpty")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "idle", "length": 1.0})
	var result := _handler.play({"player_path": player_path, "animation_name": ""})
	assert_has_key(result, "data")
	assert_eq(result.data.undoable, false)
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


# ─── Explicit invalid length rejected (not silently auto-computed) ────────────

func test_create_simple_rejects_zero_length() -> void:
	var player_path := _add_player("TestSimpleZeroLen")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "zerolen",
		"length": 0.0,
		"tweens": [
			{"target": ".", "property": "modulate",
			 "from": "white", "to": "red", "duration": 0.5},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "length")
	_remove_node(player_path)


func test_create_simple_rejects_negative_length() -> void:
	var player_path := _add_player("TestSimpleNegLen")
	if player_path.is_empty():
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "neglen",
		"length": -1.0,
		"tweens": [
			{"target": ".", "property": "modulate",
			 "from": "white", "to": "red", "duration": 0.5},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ─── Library-qualified names round-trip through animation_get ────────────────

func test_get_accepts_library_qualified_name() -> void:
	# When a clip lives in a non-default library, list_animations reports it
	# as "libname/clip". That string should round-trip back into animation_get.
	var player_path := _add_player("TestLibQualified")
	if player_path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer

	# Attach a named library with a clip directly — the handler API targets the
	# default library today; this test covers the read-path robustness only.
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 1.0
	lib.add_animation(&"idle", anim)
	player.add_animation_library(&"moves", lib)

	var result := _handler.get_animation({
		"player_path": player_path,
		"animation_name": "moves/idle",
	})
	assert_has_key(result, "data", "Qualified name should resolve via animation_get")
	assert_eq(result.data.length, 1.0)
	_remove_node(player_path)


# ─── Track type labels — value / method are distinct, other types honest ────

func test_get_labels_value_and_method_tracks_distinctly() -> void:
	# The previous implementation labeled anything not TYPE_VALUE as "method";
	# this verifies value/method are distinct and that bezier reports honestly.
	var player_path := _add_player("TestTrackLabels")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "mixed", "length": 1.0})

	# Attach a value track and a method track via the public API.
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "mixed",
		"track_path": ".:position",
		"keyframes": [{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}}],
	})
	_handler.add_method_track({
		"player_path": player_path,
		"animation_name": "mixed",
		"target_node_path": ".",
		"keyframes": [{"time": 0.5, "method": "queue_free", "args": []}],
	})

	# Attach a bezier track directly — the write API doesn't produce them, but
	# imported resources or future tools will, and get_animation must label
	# them honestly instead of reporting "method".
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("mixed")
	var bezier_idx := anim.add_track(Animation.TYPE_BEZIER)
	anim.track_set_path(bezier_idx, NodePath(".:rotation"))

	var result := _handler.get_animation({"player_path": player_path, "animation_name": "mixed"})
	assert_eq(result.data.track_count, 3)
	var types: Array = []
	for t in result.data.tracks:
		types.append(t.type)
	assert_contains(types, "value")
	assert_contains(types, "method")
	assert_contains(types, "bezier")
	_remove_node(player_path)


# ============================================================================
# Friction fix: animation_delete
# ============================================================================

func test_delete_animation_basic() -> void:
	var player_path := _add_player("TestDeleteAnim")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "to_delete", "length": 1.0})

	var result := _handler.delete_animation({
		"player_path": player_path, "animation_name": "to_delete",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)

	# Verify it's gone.
	var list_result := _handler.list_animations({"player_path": player_path})
	for anim in list_result.data.animations:
		assert_true(anim.name != "to_delete", "Deleted anim should not appear")

	# Undo should restore it.
	_undo_redo.undo()
	var list_after := _handler.list_animations({"player_path": player_path})
	var found := false
	for anim in list_after.data.animations:
		if anim.name == "to_delete":
			found = true
	assert_true(found, "Undo should restore deleted animation")

	_remove_node(player_path)


func test_delete_animation_not_found() -> void:
	var player_path := _add_player("TestDeleteNotFound")
	if player_path.is_empty():
		return
	var result := _handler.delete_animation({
		"player_path": player_path, "animation_name": "nope",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ============================================================================
# Friction fix: animation overwrite
# ============================================================================

func test_create_animation_overwrite() -> void:
	var player_path := _add_player("TestOverwrite")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "overme", "length": 1.0})

	# Without overwrite, duplicate name should fail.
	var fail_result := _handler.create_animation({
		"player_path": player_path, "name": "overme", "length": 2.0,
	})
	assert_is_error(fail_result, McpErrorCodes.INVALID_PARAMS)

	# With overwrite, it should succeed.
	var result := _handler.create_animation({
		"player_path": player_path, "name": "overme", "length": 2.0, "overwrite": true,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.overwritten, true)
	assert_eq(result.data.length, 2.0)

	_remove_node(player_path)


# ============================================================================
# Friction fix: animation_validate
# ============================================================================

func test_validate_animation_all_valid() -> void:
	var player_path := _add_player("TestValidateOk")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "valid_test", "length": 1.0})
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "valid_test",
		"track_path": ".:visible",
		"keyframes": [{"time": 0.0, "value": true}],
	})
	var result := _handler.validate_animation({
		"player_path": player_path, "animation_name": "valid_test",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.valid, true)
	assert_eq(result.data.broken_count, 0)
	assert_eq(result.data.valid_count, 1)
	_remove_node(player_path)


func test_validate_animation_broken_track() -> void:
	var player_path := _add_player("TestValidateBroken")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "broken_test", "length": 1.0})
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "broken_test",
		"track_path": "NonExistentNode:visible",
		"keyframes": [{"time": 0.0, "value": true}],
	})
	var result := _handler.validate_animation({
		"player_path": player_path, "animation_name": "broken_test",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.valid, false)
	assert_eq(result.data.broken_count, 1)
	assert_eq(result.data.broken_tracks[0].issue, "node_not_found")
	assert_eq(result.data.broken_tracks[0].node_path, "NonExistentNode")
	_remove_node(player_path)


func test_validate_animation_not_found() -> void:
	var player_path := _add_player("TestValidateNotFound")
	if player_path.is_empty():
		return
	var result := _handler.validate_animation({
		"player_path": player_path, "animation_name": "nope",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
