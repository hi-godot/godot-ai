@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const AutoloadHandler := preload("res://addons/godot_ai/handlers/autoload_handler.gd")

## Tests for AutoloadHandler — autoload listing, adding, and removing.

var _handler: AutoloadHandler
var _editor_plugin: EditorPlugin
const TEST_AUTOLOAD_NAME := "_McpTestAutoload"
const TEST_AUTOLOAD_PATH := "res://tests/fixtures/autoload_node.gd"


func suite_name() -> String:
	return "autoload"


func suite_setup(_ctx: Dictionary) -> void:
	_editor_plugin = EditorPlugin.new()
	_handler = AutoloadHandler.new(_editor_plugin)


func suite_teardown() -> void:
	## Clean up any test autoload left behind
	var key := "autoload/%s" % TEST_AUTOLOAD_NAME
	if ProjectSettings.has_setting(key):
		_handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	_handler = null
	_editor_plugin.free()


# ----- list_autoloads -----

func test_list_autoloads() -> void:
	var result := _handler.list_autoloads({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "autoloads")
	assert_has_key(result.data, "count")


# ----- add_autoload -----

func test_add_autoload_missing_name() -> void:
	var result := _handler.add_autoload({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_add_autoload_missing_path() -> void:
	var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_add_autoload_invalid_path_prefix() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "/absolute/path/evil.gd",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_add_autoload_user_path_rejected() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "user://evil.gd",
	})
	assert_is_error(result)


func test_add_autoload_nonexistent_file() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": "res://nonexistent_autoload_xyz.gd",
	})
	assert_is_error(result)


func test_add_and_remove_autoload() -> void:
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": TEST_AUTOLOAD_PATH,
		"singleton": true,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.name, TEST_AUTOLOAD_NAME)
	assert_eq(result.data.singleton, true)
	assert_eq(result.data.undoable, true)
	assert_eq(_compile_singleton_reference(), OK, "new singleton must compile without an editor restart")
	var persisted := ConfigFile.new()
	assert_eq(persisted.load("res://project.godot"), OK)
	assert_eq(persisted.get_value("autoload", TEST_AUTOLOAD_NAME), "*" + TEST_AUTOLOAD_PATH)

	## Verify it shows up in the list
	var list_result := _handler.list_autoloads({})
	var found := false
	for al in list_result.data.autoloads:
		if al.name == TEST_AUTOLOAD_NAME:
			found = true
			break
	assert_true(found, "Autoload should appear in list after adding")

	## Remove it
	var remove_result := _handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	assert_has_key(remove_result, "data")
	assert_eq(remove_result.data.removed, true)
	assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))
	persisted.clear()
	assert_eq(persisted.load("res://project.godot"), OK)
	assert_false(persisted.has_section_key("autoload", TEST_AUTOLOAD_NAME))
	expect_script_error_containing("Identifier \"%s\" not declared" % TEST_AUTOLOAD_NAME)
	assert_eq(_compile_singleton_reference(), ERR_PARSE_ERROR, "removed singleton must no longer compile")
	var history := _editor_plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(history.undo(), "undo removal")
	assert_eq(_compile_singleton_reference(), OK, "undo removal restores the singleton")
	assert_true(history.undo(), "undo addition")
	assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))
	assert_true(history.redo(), "redo addition")
	assert_eq(_compile_singleton_reference(), OK, "redo addition restores the singleton")
	for autoload in _handler.list_autoloads({}).data.autoloads:
		if autoload.name == TEST_AUTOLOAD_NAME:
			assert_eq(autoload.path, TEST_AUTOLOAD_PATH, "list resolves native undo history UID paths")
	assert_true(history.redo(), "redo removal")
	assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))


func test_add_autoload_duplicate() -> void:
	## Add once
	var added := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": TEST_AUTOLOAD_PATH,
	})
	assert_eq(added.get("data", {}).get("name"), TEST_AUTOLOAD_NAME)
	## Add again should fail
	var result := _handler.add_autoload({
		"name": TEST_AUTOLOAD_NAME,
		"path": TEST_AUTOLOAD_PATH,
	})
	assert_is_error(result)
	## Cleanup
	_handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})


# ----- remove_autoload -----

func test_remove_autoload_missing_name() -> void:
	var result := _handler.remove_autoload({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_remove_autoload_not_found() -> void:
	var result := _handler.remove_autoload({"name": "_NoSuchAutoload"})
	assert_is_error(result)


func test_non_singleton_autoload_keeps_plain_path() -> void:
	var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME, "path": TEST_AUTOLOAD_PATH, "singleton": false})
	assert_has_key(result, "data")
	assert_eq(result.data.singleton, false)
	assert_eq(ProjectSettings.get_setting("autoload/" + TEST_AUTOLOAD_NAME), TEST_AUTOLOAD_PATH)
	var persisted := ConfigFile.new()
	assert_eq(persisted.load("res://project.godot"), OK)
	assert_eq(persisted.get_value("autoload", TEST_AUTOLOAD_NAME), TEST_AUTOLOAD_PATH)
	expect_script_error_containing("Identifier \"%s\" not declared" % TEST_AUTOLOAD_NAME)
	assert_eq(_compile_singleton_reference(), ERR_PARSE_ERROR, "non-singleton must not create a named global")
	var removed := _handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	assert_eq(removed.get("data", {}).get("removed"), true)
	var history := _editor_plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(history.undo(), "undo non-singleton removal")
	assert_eq(ProjectSettings.get_setting("autoload/" + TEST_AUTOLOAD_NAME), TEST_AUTOLOAD_PATH)
	assert_true(history.redo(), "redo non-singleton removal")
	assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))


func test_add_autoload_rejects_non_node_script() -> void:
	var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME, "path": "res://tests/test_autoload.gd"})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))


func test_add_autoload_rejects_invalid_names() -> void:
	for name in ["123Invalid", "Node", "McpTestSuite", "String"]:
		var result := _handler.add_autoload({"name": name, "path": TEST_AUTOLOAD_PATH})
		assert_is_error(result, ErrorCodes.INVALID_PARAMS)
		assert_false(ProjectSettings.has_setting("autoload/" + name))
		var persisted := ConfigFile.new()
		assert_eq(persisted.load("res://project.godot"), OK)
		assert_false(persisted.has_section_key("autoload", name))


func _compile_singleton_reference() -> Error:
	var script := GDScript.new()
	script.source_code = "extends RefCounted\nfunc read_volume():\n\treturn " + TEST_AUTOLOAD_NAME + ".volume\n"
	return script.reload()


func test_empty_packed_scene_is_refused_before_project_write() -> void:
	var path := "res://tests/_mcp_empty_autoload_1207.tres"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("[gd_resource type=\"PackedScene\" format=3]\n\n[resource]\n")
	file.close()
	var scene := ResourceLoader.load(path) as PackedScene
	assert_true(scene != null, "empty scene still loads as PackedScene")
	if scene == null:
		DirAccess.remove_absolute(path)
		return
	assert_false(scene.can_instantiate())
	var original := FileAccess.get_file_as_bytes("res://project.godot")
	for singleton in [false, true]:
		var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME, "path": path, "singleton": singleton})
		assert_is_error(result, ErrorCodes.WRONG_TYPE)
		assert_false(ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME))
		assert_eq(FileAccess.get_file_as_bytes("res://project.godot"), original)
		if ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME):
			_handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	DirAccess.remove_absolute(path)


func test_valid_packed_scene_autoload_is_still_supported() -> void:
	var path := "res://tests/_mcp_valid_autoload_1207.tscn"
	var root := Node.new()
	root.name = "ValidAutoload"
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK)
	root.free()
	assert_eq(ResourceSaver.save(packed, path), OK)
	var result := _handler.add_autoload({"name": TEST_AUTOLOAD_NAME, "path": path, "singleton": true})
	assert_has_key(result, "data", str(result))
	if ProjectSettings.has_setting("autoload/" + TEST_AUTOLOAD_NAME):
		assert_eq(_compile_singleton_reference(), OK)
		_handler.remove_autoload({"name": TEST_AUTOLOAD_NAME})
	DirAccess.remove_absolute(path)
