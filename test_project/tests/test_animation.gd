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
		skip("No scene root — is a scene open?")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("No scene root — is a scene open?")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "walk", "length": 1.0})
	var result := _handler.create_animation({"player_path": player_path, "name": "walk", "length": 1.0})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "already exists")
	_remove_node(player_path)


func test_animation_create_rejects_invalid_loop_mode() -> void:
	var player_path := _add_player("TestAnimBadLoop")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})

	# Scene root is Node3D — use .:position (a real Vector3 property) rather
	# than .:modulate which doesn't exist on Node3D.
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:position",
		"keyframes": [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}},
			{"time": 1.0, "value": {"x": 1.0, "y": 0.0, "z": 0.0}},
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")

	# Scene root is Node3D — use .:visible (a real bool property) rather than
	# the previous .:modulate which only worked because coercion used to silently
	# fall through when the property didn't exist.
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:visible",
		"keyframes": [{"time": 0.0, "value": true}, {"time": 1.0, "value": false}],
	})
	assert_eq(anim.get_track_count(), 1)
	_undo_redo.undo()
	assert_eq(anim.get_track_count(), 0, "Undo should remove the track")
	_remove_node(player_path)


func test_add_property_track_rejects_missing_property() -> void:
	# Scene root is Node3D — .modulate doesn't exist. Previously coercion
	# passed through silently; now it errors.
	var player_path := _add_player("TestMissingProp")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:modulate",
		"keyframes": [{"time": 0.0, "value": {"r": 1.0, "g": 0.0, "b": 0.0}}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not found")
	_remove_node(player_path)


func test_add_property_track_undo_survives_interleaving() -> void:
	# Stress-tests the find_track-at-undo-time pattern: if another track lands
	# between do and undo, the undo must still remove the CORRECT track — not
	# whatever happens to sit at the originally captured index.
	var player_path := _add_player("TestInterleavedUndo")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("anim")

	# Add track A on .:position.
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:position",
		"keyframes": [{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}}],
	})
	assert_eq(anim.get_track_count(), 1, "After track A")

	# Add track B on .:scale (interleaves track A's history).
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "anim",
		"track_path": ".:scale",
		"keyframes": [{"time": 0.0, "value": {"x": 1.0, "y": 1.0, "z": 1.0}}],
	})
	assert_eq(anim.get_track_count(), 2, "After track B")

	# Undo B — should remove scale, leaving position.
	_undo_redo.undo()
	assert_eq(anim.get_track_count(), 1, "Undo B leaves one track")
	assert_eq(anim.track_get_path(0), NodePath(".:position"), "Remaining track is position, not scale")

	# Undo A — should remove position.
	_undo_redo.undo()
	assert_eq(anim.get_track_count(), 0, "Undo A leaves no tracks")

	_remove_node(player_path)


func test_add_method_track_rejects_bad_args() -> void:
	# args must be an Array if provided — not a string, not a null.
	var player_path := _add_player("TestBadArgs")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_method_track({
		"player_path": player_path,
		"animation_name": "anim",
		"target_node_path": ".",
		"keyframes": [{"time": 0.0, "method": "queue_free", "args": "not an array"}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "args")
	_remove_node(player_path)


func test_add_method_track_rejects_empty_method() -> void:
	var player_path := _add_player("TestEmptyMethod")
	if player_path.is_empty():
		return
	_handler.create_animation({"player_path": player_path, "name": "anim", "length": 1.0})
	var result := _handler.add_method_track({
		"player_path": player_path,
		"animation_name": "anim",
		"target_node_path": ".",
		"keyframes": [{"time": 0.0, "method": ""}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


func test_add_property_track_transition_named() -> void:
	var player_path := _add_player("TestTransNamed")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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


func test_add_property_track_accepts_vector_subpath() -> void:
	# Godot-native NodePath subpath form (`position:y`) must resolve to the
	# `y` float component, not error as "Property 'y' not found".
	var player_path := _add_player("TestSubpathVec")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "bob", "length": 1.0})
	var result := _handler.add_property_track({
		"player_path": player_path,
		"animation_name": "bob",
		"track_path": ".:position:y",
		"keyframes": [
			{"time": 0.0, "value": 0.0},
			{"time": 1.0, "value": 2.0},
		],
	})
	assert_has_key(result, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("bob")
	var k0 = anim.track_get_key_value(0, 0)
	var k1 = anim.track_get_key_value(0, 1)
	# Subpath coercion must land scalar floats in the keyframes — never a
	# Vector3 dict masquerading as a keyframe value.
	assert_true(k0 is float, "keyframe 0 should be float for position:y subpath")
	assert_true(k1 is float, "keyframe 1 should be float for position:y subpath")
	assert_eq(k1, 2.0)
	_remove_node(player_path)


func test_create_simple_accepts_color_subpath() -> void:
	# Fade-just-the-alpha flow: `modulate:a` subpath targets a Color component,
	# which must coerce to float so the animation plays an alpha ramp, not a
	# broken dict-valued track.
	var scene_root := EditorInterface.get_edited_scene_root()
	var sprite := Sprite2D.new()
	sprite.name = "SubpathAlphaSprite"
	scene_root.add_child(sprite)
	sprite.owner = scene_root

	var player_path := _add_player("TestSubpathAlpha")
	if player_path.is_empty():
		sprite.get_parent().remove_child(sprite)
		sprite.queue_free()
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "fade",
		"tweens": [
			{
				"target": "SubpathAlphaSprite",
				"property": "modulate:a",
				"from": 1.0,
				"to": 0.0,
				"duration": 0.5,
			},
		],
	})
	assert_has_key(result, "data")
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	var anim: Animation = player.get_animation("fade")
	var k0 = anim.track_get_key_value(0, 0)
	var k1 = anim.track_get_key_value(0, 1)
	assert_true(k0 is float, "from value should coerce to float for modulate:a")
	assert_true(k1 is float, "to value should coerce to float for modulate:a")
	assert_eq(k1, 0.0)
	_remove_node(player_path)
	sprite.get_parent().remove_child(sprite)
	sprite.queue_free()


func test_create_simple_coerces_vector3() -> void:
	# Auto-length + coerce path in one test.
	var player_path := _add_player("TestCoerceSimple")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.play({"player_path": player_path, "animation_name": "nope"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ─── animation_list / animation_get ──────────────────────────────────────────

func test_list_returns_created_animations() -> void:
	var player_path := _add_player("TestList")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "fade", "length": 1.0})
	_handler.add_property_track({
		"player_path": player_path,
		"animation_name": "fade",
		"track_path": ".:position",
		"keyframes": [
			{"time": 0.0, "value": {"x": 0.0, "y": 0.0, "z": 0.0}},
			{"time": 1.0, "value": {"x": 10.0, "y": 0.0, "z": 0.0}},
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	# Scene root is Node3D — use .position, not .modulate (not present on Node3D).
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "fade",
		"length": 2.0,
		"tweens": [
			{
				"target": ".",
				"property": "position",
				"from": {"x": 0.0, "y": 0.0, "z": 0.0},
				"to": {"x": 1.0, "y": 0.0, "z": 0.0},
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
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "combo",
		"tweens": [
			{"target": ".", "property": "scale", "from": {"x":1,"y":1,"z":1}, "to": {"x":2,"y":2,"z":2}, "duration": 0.5},
			{"target": ".", "property": "position", "from": {"x": -200.0, "y": 0.0, "z": 0.0}, "to": {"x": 0.0, "y": 0.0, "z": 0.0}, "duration": 0.3, "delay": 0.1},
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.track_count, 2)
	_remove_node(player_path)


func test_create_simple_is_undoable() -> void:
	var player_path := _add_player("TestSimpleUndo")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer

	_handler.create_simple({
		"player_path": player_path,
		"name": "pulse",
		"loop_mode": "pingpong",
		"tweens": [
			{"target": ".", "property": "scale", "from": {"x":1,"y":1,"z":1}, "to": {"x":2,"y":2,"z":2}, "duration": 0.5},
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_bare_player returned empty path")
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
		skip("Scene not ready — _add_bare_player returned empty path")
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


func test_create_simple_auto_creates_animation_player() -> void:
	## Issue #86: agents hit "Node at /Root/Pivot is not an AnimationPlayer" or
	## "Node not found" when the player doesn't exist yet. The tool now creates
	## one at the given path (parent must exist), bundled into the same undo
	## action so Ctrl-Z rolls back player + library + animation together.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var player_path := "/" + scene_root.name + "/AutoPlayer86"
	if ScenePath.resolve(player_path, scene_root) != null:
		skip("AutoPlayer86 already exists in scene — rerun after cleanup")
		return

	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "bob",
		"tweens": [
			{"target": ".", "property": "position",
			 "from": {"x": 0.0, "y": 0.0, "z": 0.0},
			 "to": {"x": 0.0, "y": 2.0, "z": 0.0}, "duration": 1.0},
		],
	})
	assert_has_key(result, "data")
	assert_true(result.data.animation_player_created,
		"animation_player_created should be true when the player didn't exist")
	assert_true(result.data.library_created,
		"library_created should be true — fresh player has no library")
	var created := ScenePath.resolve(player_path, scene_root)
	assert_true(created is AnimationPlayer,
		"AnimationPlayer should exist at %s after create_simple" % player_path)
	assert_true((created as AnimationPlayer).has_animation("bob"))

	# Single Ctrl-Z rolls back everything.
	_undo_redo.undo()
	assert_true(ScenePath.resolve(player_path, scene_root) == null,
		"undo should remove the auto-created AnimationPlayer from the scene")


func test_create_simple_rejects_wrong_type_even_when_auto_create_enabled() -> void:
	## Existing error when the path points at a non-AnimationPlayer stays —
	## the caller picked a live node that happens to be a different class.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var decoy := Node.new()
	decoy.name = "Decoy86"
	scene_root.add_child(decoy)
	decoy.owner = scene_root

	var result := _handler.create_simple({
		"player_path": "/" + scene_root.name + "/Decoy86",
		"name": "x",
		"tweens": [
			{"target": ".", "property": "position",
			 "from": {"x": 0}, "to": {"x": 1}, "duration": 1.0},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "not an AnimationPlayer")
	_remove_node("/" + scene_root.name + "/Decoy86")


func test_create_simple_errors_when_parent_missing() -> void:
	## Parent path must exist, matching node_create semantics.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var result := _handler.create_simple({
		"player_path": "/" + scene_root.name + "/NoSuchParent/AutoPlayer",
		"name": "x",
		"tweens": [
			{"target": ".", "property": "position",
			 "from": {"x": 0}, "to": {"x": 1}, "duration": 1.0},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_animation_reports_library_created_false_when_present() -> void:
	var player_path := _add_player("TestLibExists")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	_handler.create_animation({"player_path": player_path, "name": "idle", "length": 1.0})
	var result := _handler.play({"player_path": player_path, "animation_name": ""})
	assert_has_key(result, "data")
	assert_eq(result.data.undoable, false)
	_remove_node(player_path)


func test_create_simple_rejects_missing_tween_fields() -> void:
	var player_path := _add_player("TestSimpleMissing")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "bad",
		"tweens": [{"target": ".", "property": "position"}],  # Missing from/to/duration
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ─── Explicit invalid length rejected (not silently auto-computed) ────────────

func test_create_simple_rejects_zero_length() -> void:
	var player_path := _add_player("TestSimpleZeroLen")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "zerolen",
		"length": 0.0,
		"tweens": [
			{"target": ".", "property": "scale",
			 "from": {"x":1,"y":1,"z":1}, "to": {"x":2,"y":2,"z":2}, "duration": 0.5},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "length")
	_remove_node(player_path)


func test_create_simple_rejects_negative_length() -> void:
	var player_path := _add_player("TestSimpleNegLen")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.create_simple({
		"player_path": player_path,
		"name": "neglen",
		"length": -1.0,
		"tweens": [
			{"target": ".", "property": "scale",
			 "from": {"x":1,"y":1,"z":1}, "to": {"x":2,"y":2,"z":2}, "duration": 0.5},
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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


func test_delete_animation_in_non_default_library() -> void:
	# Previously delete only worked for animations in the default library and
	# returned INTERNAL_ERROR "No default library found" for anything else.
	# Now it searches all libraries symmetrically with animation_get / animation_play.
	var player_path := _add_player("TestDeleteNonDefault")
	if player_path.is_empty():
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer

	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 0.5
	lib.add_animation(&"idle", anim)
	player.add_animation_library(&"moves", lib)
	assert_true(player.has_animation("moves/idle"), "Setup: library-qualified animation present")

	var result := _handler.delete_animation({
		"player_path": player_path, "animation_name": "moves/idle",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.library_key, "moves")
	assert_false(player.has_animation("moves/idle"), "Animation removed from non-default library")

	# Undo restores it.
	_undo_redo.undo()
	assert_true(player.has_animation("moves/idle"), "Undo restored library-qualified animation")

	_remove_node(player_path)


func test_delete_animation_not_found() -> void:
	var player_path := _add_player("TestDeleteNotFound")
	if player_path.is_empty():
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
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
		skip("Scene not ready — _add_player returned empty path")
		return
	var result := _handler.validate_animation({
		"player_path": player_path, "animation_name": "nope",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)


# ─── animation_preset_* — shared helpers ─────────────────────────────────────

## Add a sibling node to the scene_root. The preset tools resolve target_path
## against the player's root_node (default "..") which is the scene_root when
## the player lives directly under it — so target_path is just the sibling's name.
func _add_sibling(node: Node, sibling_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	node.name = sibling_name
	scene_root.add_child(node)
	node.owner = scene_root
	return node


func _fetch_anim(player_path: String, anim_name: String) -> Animation:
	var scene_root := EditorInterface.get_edited_scene_root()
	var player := ScenePath.resolve(player_path, scene_root) as AnimationPlayer
	if player == null or not player.has_animation(anim_name):
		return null
	return player.get_animation(anim_name)


# ─── animation_preset_fade ────────────────────────────────────────────────────

func test_preset_fade_basic_in() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return
	var sprite: Sprite2D = _add_sibling(Sprite2D.new(), "FadeTarget") as Sprite2D
	var player_path := _add_player("TestPresetFadeIn")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/FadeTarget")
		skip("Scene not ready")
		return
	var result := _handler.preset_fade({
		"player_path": player_path,
		"target_path": "FadeTarget",
		"mode": "in",
		"duration": 0.5,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.animation_name, "fade_in")
	assert_eq(result.data.track_count, 1)
	assert_eq(result.data.length, 0.5)
	assert_true(result.data.undoable)

	# Verify the stored keyframes are floats (alpha sub-property),
	# not raw dicts — guarded against coercion regressions.
	var anim := _fetch_anim(player_path, "fade_in")
	assert_true(anim != null, "animation should exist")
	var start_v = anim.track_get_key_value(0, 0)
	var end_v = anim.track_get_key_value(0, 1)
	assert_true(start_v is float, "start alpha should be float, got %s" % typeof(start_v))
	assert_true(end_v is float, "end alpha should be float, got %s" % typeof(end_v))
	assert_eq(float(start_v), 0.0)
	assert_eq(float(end_v), 1.0)
	# Track path should include the :a sub-property so only alpha changes.
	var track_path := String(anim.track_get_path(0))
	assert_true(track_path.ends_with(":modulate:a"),
		"expected fade track to target modulate:a, got '%s'" % track_path)

	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/FadeTarget")


func test_preset_fade_out_reverses_alpha() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var sprite: Sprite2D = _add_sibling(Sprite2D.new(), "FadeOutTarget") as Sprite2D
	var player_path := _add_player("TestPresetFadeOut")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/FadeOutTarget")
		skip("Scene not ready")
		return
	_handler.preset_fade({
		"player_path": player_path,
		"target_path": "FadeOutTarget",
		"mode": "out",
	})
	var anim := _fetch_anim(player_path, "fade_out")
	assert_eq(float(anim.track_get_key_value(0, 0)), 1.0)
	assert_eq(float(anim.track_get_key_value(0, 1)), 0.0)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/FadeOutTarget")


func test_preset_fade_rejects_target_without_modulate() -> void:
	# A plain Node3D has no modulate property — the handler must reject it
	# rather than silently building a broken track.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var n3d: Node3D = _add_sibling(Node3D.new(), "NoModulateTarget") as Node3D
	var player_path := _add_player("TestPresetFadeReject")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/NoModulateTarget")
		skip("Scene not ready")
		return
	var result := _handler.preset_fade({
		"player_path": player_path,
		"target_path": "NoModulateTarget",
		"mode": "in",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/NoModulateTarget")


func test_preset_fade_invalid_mode() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var sprite: Sprite2D = _add_sibling(Sprite2D.new(), "FadeBadMode") as Sprite2D
	var player_path := _add_player("TestPresetFadeBadMode")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/FadeBadMode")
		skip("Scene not ready")
		return
	var result := _handler.preset_fade({
		"player_path": player_path,
		"target_path": "FadeBadMode",
		"mode": "wobble",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/FadeBadMode")


# ─── animation_preset_slide ───────────────────────────────────────────────────

func test_preset_slide_2d_stores_vector2() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node2D = _add_sibling(Node2D.new(), "Slide2D") as Node2D
	target.position = Vector2(100, 50)
	var player_path := _add_player("TestPresetSlide2D")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Slide2D")
		skip("Scene not ready")
		return
	var result := _handler.preset_slide({
		"player_path": player_path,
		"target_path": "Slide2D",
		"direction": "left",
		"mode": "in",
		"distance": 200.0,
		"duration": 0.4,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.animation_name, "slide_in_left")
	var anim := _fetch_anim(player_path, "slide_in_left")
	var start_v = anim.track_get_key_value(0, 0)
	var end_v = anim.track_get_key_value(0, 1)
	assert_true(start_v is Vector2, "2D slide start should be Vector2, got %s" % typeof(start_v))
	assert_true(end_v is Vector2, "2D slide end should be Vector2")
	# mode=in, direction=left: starts at current - (200, 0), ends at current.
	assert_eq((start_v as Vector2).x, -100.0)  # 100 + (-200)
	assert_eq((end_v as Vector2).x, 100.0)
	assert_eq((end_v as Vector2).y, 50.0)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Slide2D")


func test_preset_slide_3d_stores_vector3() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node3D = _add_sibling(Node3D.new(), "Slide3D") as Node3D
	target.position = Vector3.ZERO
	var player_path := _add_player("TestPresetSlide3D")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Slide3D")
		skip("Scene not ready")
		return
	# direction=up, mode=out: Node3D up = +y, so end = (0, 1, 0)
	var result := _handler.preset_slide({
		"player_path": player_path,
		"target_path": "Slide3D",
		"direction": "up",
		"mode": "out",
		"distance": 1.0,
	})
	assert_has_key(result, "data")
	var anim := _fetch_anim(player_path, "slide_out_up")
	var end_v = anim.track_get_key_value(0, 1)
	assert_true(end_v is Vector3, "3D slide end should be Vector3, got %s" % typeof(end_v))
	assert_eq((end_v as Vector3).y, 1.0)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Slide3D")


func test_preset_slide_rejects_non_transform_node() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node = _add_sibling(Node.new(), "SlideBadTarget")
	var player_path := _add_player("TestPresetSlideBad")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/SlideBadTarget")
		skip("Scene not ready")
		return
	var result := _handler.preset_slide({
		"player_path": player_path,
		"target_path": "SlideBadTarget",
		"direction": "left",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/SlideBadTarget")


func test_preset_slide_invalid_direction() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node2D = _add_sibling(Node2D.new(), "SlideDir") as Node2D
	var player_path := _add_player("TestPresetSlideDir")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/SlideDir")
		skip("Scene not ready")
		return
	var result := _handler.preset_slide({
		"player_path": player_path,
		"target_path": "SlideDir",
		"direction": "sideways",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/SlideDir")


# ─── animation_preset_shake ───────────────────────────────────────────────────

func test_preset_shake_seed_is_deterministic() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node2D = _add_sibling(Node2D.new(), "Shaker") as Node2D
	target.position = Vector2(10, 20)
	var player_path := _add_player("TestPresetShake")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Shaker")
		skip("Scene not ready")
		return

	# First run.
	var r1 := _handler.preset_shake({
		"player_path": player_path,
		"target_path": "Shaker",
		"intensity": 5.0,
		"duration": 0.2,
		"frequency": 20.0,
		"seed": 42,
		"animation_name": "shake_a",
	})
	assert_has_key(r1, "data")
	var anim_a := _fetch_anim(player_path, "shake_a")
	var vals_a: Array = []
	for i in range(anim_a.track_get_key_count(0)):
		vals_a.append(anim_a.track_get_key_value(0, i))

	# Second run, same seed, different name.
	_handler.preset_shake({
		"player_path": player_path,
		"target_path": "Shaker",
		"intensity": 5.0,
		"duration": 0.2,
		"frequency": 20.0,
		"seed": 42,
		"animation_name": "shake_b",
	})
	var anim_b := _fetch_anim(player_path, "shake_b")
	var vals_b: Array = []
	for i in range(anim_b.track_get_key_count(0)):
		vals_b.append(anim_b.track_get_key_value(0, i))

	assert_eq(vals_a.size(), vals_b.size())
	for i in range(vals_a.size()):
		assert_true(vals_a[i] is Vector2, "shake 2D keyframe should be Vector2")
		assert_eq(vals_a[i], vals_b[i],
			"same-seed shakes should produce identical keyframe %d" % i)

	# First and last keyframe are at-rest (node's current position).
	assert_eq(vals_a[0], target.position)
	assert_eq(vals_a[vals_a.size() - 1], target.position)

	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Shaker")


func test_preset_shake_3d_stores_vector3() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node3D = _add_sibling(Node3D.new(), "Shake3D") as Node3D
	var player_path := _add_player("TestPresetShake3D")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Shake3D")
		skip("Scene not ready")
		return
	_handler.preset_shake({
		"player_path": player_path,
		"target_path": "Shake3D",
		"seed": 7,
	})
	var anim := _fetch_anim(player_path, "shake")
	# Sample a middle keyframe (0 and last are at-rest).
	var mid = anim.track_get_key_value(0, 1)
	assert_true(mid is Vector3, "3D shake keyframe should be Vector3, got %s" % typeof(mid))
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Shake3D")


# ─── animation_preset_pulse ───────────────────────────────────────────────────

func test_preset_pulse_2d_three_keyframes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node2D = _add_sibling(Node2D.new(), "Pulser") as Node2D
	var player_path := _add_player("TestPresetPulse")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Pulser")
		skip("Scene not ready")
		return
	var result := _handler.preset_pulse({
		"player_path": player_path,
		"target_path": "Pulser",
		"from_scale": 1.0,
		"to_scale": 1.2,
		"duration": 0.4,
	})
	assert_has_key(result, "data")
	var anim := _fetch_anim(player_path, "pulse")
	assert_eq(anim.track_get_key_count(0), 3)
	var k0 = anim.track_get_key_value(0, 0)
	var k1 = anim.track_get_key_value(0, 1)
	var k2 = anim.track_get_key_value(0, 2)
	assert_true(k0 is Vector2 and k1 is Vector2 and k2 is Vector2,
		"2D pulse keyframes should be Vector2")
	# Vector2 components are float32 — compare approximately.
	assert_true(is_equal_approx((k0 as Vector2).x, 1.0))
	assert_true(is_equal_approx((k1 as Vector2).x, 1.2))
	assert_true(is_equal_approx((k2 as Vector2).x, 1.0))
	# Peak sits at the midpoint.
	assert_true(is_equal_approx(anim.track_get_key_time(0, 1), 0.2))
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Pulser")


func test_preset_pulse_3d_stores_vector3() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var target: Node3D = _add_sibling(Node3D.new(), "Pulse3D") as Node3D
	var player_path := _add_player("TestPresetPulse3D")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/Pulse3D")
		skip("Scene not ready")
		return
	_handler.preset_pulse({
		"player_path": player_path,
		"target_path": "Pulse3D",
	})
	var anim := _fetch_anim(player_path, "pulse")
	var peak = anim.track_get_key_value(0, 1)
	assert_true(peak is Vector3, "3D pulse peak should be Vector3, got %s" % typeof(peak))
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/Pulse3D")


# ─── animation_preset_* — shared behaviors ───────────────────────────────────

func test_preset_overwrite_required_for_second_call() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var sprite: Sprite2D = _add_sibling(Sprite2D.new(), "OverwriteTarget") as Sprite2D
	var player_path := _add_player("TestPresetOverwrite")
	if player_path.is_empty():
		_remove_node("/" + scene_root.name + "/OverwriteTarget")
		skip("Scene not ready")
		return
	var r1 := _handler.preset_fade({
		"player_path": player_path, "target_path": "OverwriteTarget", "mode": "in",
	})
	assert_has_key(r1, "data")
	# Second call with same (auto-derived) name errors without overwrite.
	var r2 := _handler.preset_fade({
		"player_path": player_path, "target_path": "OverwriteTarget", "mode": "in",
	})
	assert_is_error(r2, McpErrorCodes.INVALID_PARAMS)
	# With overwrite=true, it succeeds.
	var r3 := _handler.preset_fade({
		"player_path": player_path, "target_path": "OverwriteTarget", "mode": "in",
		"overwrite": true, "duration": 0.25,
	})
	assert_has_key(r3, "data")
	assert_eq(r3.data.overwritten, true)
	assert_eq(r3.data.length, 0.25)
	_remove_node(player_path)
	_remove_node("/" + scene_root.name + "/OverwriteTarget")


func test_preset_fade_missing_target() -> void:
	var player_path := _add_player("TestPresetMissingTarget")
	if player_path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.preset_fade({
		"player_path": player_path,
		"target_path": "NoSuchNode",
		"mode": "in",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(player_path)
