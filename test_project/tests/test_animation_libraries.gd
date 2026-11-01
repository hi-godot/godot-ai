@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/animation_handler.gd")
const LIBRARY_PATH := "res://tests/fixtures/animation_shared_library.tres"
const INSTANCE := preload("res://tests/fixtures/animation_instance.tscn")

var _handler: Handler
var _undo_redo: EditorUndoRedoManager
var _root: Node
var _player: AnimationPlayer
var _path: String


func suite_name() -> String:
	return "animation_libraries"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.undo_redo
	_handler = Handler.new(_undo_redo)


func setup() -> void:
	_root = EditorInterface.get_edited_scene_root()
	_player = AnimationPlayer.new()
	_player.name = "LibraryTestPlayer"
	_root.add_child(_player)
	_player.owner = _root
	_path = McpScenePath.from_node(_player, _root)


func teardown() -> void:
	_root.remove_child(_player)
	_player.queue_free()


func test_add_remove_undo_redo_preserves_resource_identity() -> void:
	var library := load(LIBRARY_PATH) as AnimationLibrary
	var result := _handler.library_add({"player_path": _path, "library_name": "moves", "resource_path": LIBRARY_PATH})
	_assert_success(result)
	assert_true(result.data.undoable)
	assert_eq(_player.get_animation_library("moves"), library)
	assert_eq(_player.get_animation("moves/idle"), library.get_animation("idle"))
	assert_true(editor_undo(_undo_redo))
	assert_false(_player.has_animation_library("moves"))
	assert_true(editor_redo(_undo_redo))
	assert_eq(_player.get_animation_library("moves"), library)
	_player.autoplay = "moves/idle"
	result = _handler.library_remove({"player_path": _path, "library_name": "moves"})
	_assert_success(result)
	assert_true(result.data.autoplay_cleared)
	assert_eq(String(_player.autoplay), "")
	assert_false(_player.has_animation_library("moves"))
	assert_true(editor_undo(_undo_redo))
	assert_eq(_player.get_animation_library("moves"), library)
	assert_eq(String(_player.autoplay), "moves/idle")
	assert_true(editor_redo(_undo_redo))
	assert_false(_player.has_animation_library("moves"))
	assert_eq(String(_player.autoplay), "")


func test_refusals_leave_libraries_and_undo_unchanged() -> void:
	_assert_success(_handler.library_add({"player_path": _path, "library_name": "moves", "resource_path": LIBRARY_PATH}))
	var library := _player.get_animation_library("moves")
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	for name in ["moves", "alias", "bad/name", "bad:name", "bad,name", "bad[name"]:
		assert_is_error(_handler.library_add({"player_path": _path, "library_name": name, "resource_path": LIBRARY_PATH}))
	assert_is_error(_handler.library_add({"player_path": _path, "resource_path": "res://not-there.tres"}))
	assert_is_error(_handler.library_add({"player_path": _path, "resource_path": "res://tests/fixtures/animation_instance.tscn"}))
	assert_is_error(_handler.library_add({"player_path": _path, "resource_path": "/tmp/outside.tres"}))
	assert_is_error(_handler.library_add({"player_path": _path}))
	assert_is_error(_handler.library_add({"resource_path": LIBRARY_PATH}))
	assert_is_error(_handler.library_add({"player_path": McpScenePath.from_node(_root, _root), "resource_path": LIBRARY_PATH}))
	assert_is_error(_handler.library_remove({"player_path": _path, "library_name": "missing"}))
	assert_eq(_player.get_animation_library("moves"), library)
	assert_eq(Array(_player.get_animation_library_list()), [StringName("moves")])
	assert_eq(history.get_version(), version)


func test_default_library_and_autoplay_readback() -> void:
	_assert_success(_handler.library_add({"player_path": _path, "resource_path": LIBRARY_PATH}))
	_assert_success(_handler.set_autoplay({"player_path": _path, "animation_name": "idle"}))
	var listed := _handler.library_list({"player_path": _path})
	_assert_success(listed)
	assert_eq(listed.data.autoplay, "idle")
	assert_eq(listed.data.libraries[0].name, "")
	assert_eq(listed.data.libraries[0].resource_path, LIBRARY_PATH)
	assert_eq(listed.data.libraries[0].animations, ["idle", "run"])
	var clips := _handler.list_animations({"player_path": _path})
	_assert_success(clips)
	assert_eq(clips.data.autoplay, "idle")
	assert_eq(clips.data.libraries, listed.data.libraries)
	assert_eq(clips.data.animations[0].length, 2.5)
	_assert_success(_handler.library_remove({"player_path": _path}))
	assert_eq(String(_player.autoplay), "")
	assert_true(editor_undo(_undo_redo))
	assert_eq(String(_player.autoplay), "idle")
	assert_eq(_player.get_animation_library(""), load(LIBRARY_PATH))


func test_removing_other_libraries_preserves_autoplay() -> void:
	var library := load(LIBRARY_PATH) as AnimationLibrary
	_player.add_animation_library("", AnimationLibrary.new())
	_player.add_animation_library("move", AnimationLibrary.new())
	_player.add_animation_library("moves", library)
	_player.autoplay = "moves/idle"
	for name in ["", "move"]:
		var removed := _handler.library_remove({"player_path": _path, "library_name": name})
		_assert_success(removed)
		assert_false(removed.data.autoplay_cleared)
		assert_eq(String(_player.autoplay), "moves/idle")
		assert_true(editor_undo(_undo_redo))
		assert_eq(String(_player.autoplay), "moves/idle")


func test_tree_libraries_and_builtin_readback() -> void:
	var tree := AnimationTree.new()
	tree.name = "LibraryTestTree"
	_root.add_child(tree)
	tree.owner = _root
	var path := McpScenePath.from_node(tree, _root)
	_assert_success(_handler.library_add({"player_path": path, "resource_path": LIBRARY_PATH, "library_name": "shared"}))
	assert_eq(tree.get_animation_library("shared"), load(LIBRARY_PATH))
	var listed := _handler.library_list({"player_path": path})
	_assert_success(listed)
	assert_false(listed.data.has("autoplay"))
	assert_eq(listed.data.libraries[0].resource_path, LIBRARY_PATH)
	assert_true(editor_undo(_undo_redo))
	assert_false(tree.has_animation_library("shared"))
	assert_true(editor_redo(_undo_redo))
	assert_eq(tree.get_animation_library("shared"), load(LIBRARY_PATH))
	_assert_success(_handler.library_remove({"player_path": path, "library_name": "shared"}))
	assert_false(tree.has_animation_library("shared"))
	_root.remove_child(tree)
	tree.queue_free()
	_player.add_animation_library("", AnimationLibrary.new())
	listed = _handler.library_list({"player_path": _path})
	assert_eq(listed.data.libraries[0].resource_path, "")
	assert_eq(listed.data.libraries[0].animations, [])


func test_locked_instance_refuses_writes_but_allows_reads() -> void:
	var instance := INSTANCE.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_root.add_child(instance)
	instance.owner = _root
	var player := instance.get_node("Player") as AnimationPlayer
	var path := McpScenePath.from_node(player, _root)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_handler.library_add({"player_path": path, "resource_path": LIBRARY_PATH}))
	_assert_success(_handler.library_list({"player_path": path}))
	assert_eq(history.get_version(), version)
	_root.set_editable_instance(instance, true)
	_assert_success(_handler.library_add({"player_path": path, "resource_path": LIBRARY_PATH}))
	assert_eq(player.get_animation_library(""), load(LIBRARY_PATH))
	_root.set_editable_instance(instance, false)
	version = history.get_version()
	assert_is_error(_handler.library_remove({"player_path": path}))
	assert_eq(player.get_animation_library(""), load(LIBRARY_PATH))
	assert_eq(history.get_version(), version)
	_root.remove_child(instance)
	instance.queue_free()


func test_saved_scene_reopens_with_library_and_autoplay() -> void:
	var bytes_before := FileAccess.get_file_as_bytes(LIBRARY_PATH)
	_assert_success(_handler.library_add({"player_path": _path, "resource_path": LIBRARY_PATH, "library_name": "shared"}))
	_assert_success(_handler.set_autoplay({"player_path": _path, "animation_name": "shared/run"}))
	var packed := PackedScene.new()
	assert_eq(packed.pack(_player), OK)
	var path := "user://animation-library-persistence.tscn"
	assert_eq(ResourceSaver.save(packed, path), OK)
	var reopened := (ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate() as AnimationPlayer
	assert_eq(reopened.get_animation_library("shared"), _player.get_animation_library("shared"))
	assert_eq(reopened.get_animation_library("shared").resource_path, LIBRARY_PATH)
	assert_eq(String(reopened.autoplay), "shared/run")
	assert_eq(reopened.get_animation("shared/run").length, 0.75)
	reopened.free()
	_assert_success(_handler.library_remove({"player_path": _path, "library_name": "shared"}))
	assert_eq(packed.pack(_player), OK)
	assert_eq(ResourceSaver.save(packed, path), OK)
	reopened = (ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate() as AnimationPlayer
	assert_false(reopened.has_animation_library("shared"))
	assert_eq(String(reopened.autoplay), "")
	reopened.free()
	assert_eq(FileAccess.get_file_as_bytes(LIBRARY_PATH), bytes_before)
	DirAccess.remove_absolute(path)


func _assert_success(result: Dictionary) -> void:
	assert_false(result.has("error"), str(result))
	assert_has_key(result, "data")
