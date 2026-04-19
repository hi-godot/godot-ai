@tool
extends McpTestSuite

## Tests for ScriptHandler — script creation, reading, attach/detach, and symbol inspection.

var _handler: ScriptHandler
var _undo_redo: EditorUndoRedoManager

const TEST_SCRIPT_PATH := "res://tests/_mcp_test_script.gd"
const TEST_SCRIPT_CONTENT := """class_name _McpTestScript
extends Node3D

signal health_changed(new_value: int)
signal died

@export var speed: float = 10.0
@export var max_health: int = 100

var _internal := 0

func _ready() -> void:
	pass

func move(direction: Vector3) -> void:
	pass
"""


func suite_name() -> String:
	return "script"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ScriptHandler.new(_undo_redo)
	# Create a test script file for read/symbol tests
	var file := FileAccess.open(TEST_SCRIPT_PATH, FileAccess.WRITE)
	if file:
		file.store_string(TEST_SCRIPT_CONTENT)
		file.close()


func suite_teardown() -> void:
	# Clean up test script file
	if FileAccess.file_exists(TEST_SCRIPT_PATH):
		DirAccess.remove_absolute(TEST_SCRIPT_PATH)


# ----- create_script -----

func test_create_script_basic() -> void:
	var path := "res://tests/_mcp_test_created.gd"
	var content := "extends Node\n\nfunc _ready() -> void:\n\tpass\n"
	var result := _handler.create_script({"path": path, "content": content})
	assert_has_key(result, "data")
	assert_eq(result.data.path, path)
	assert_eq(result.data.size, content.length())
	assert_false(result.data.undoable, "File write should not be undoable")
	# Verify file was actually written
	assert_true(FileAccess.file_exists(path), "Script file should exist")
	var file := FileAccess.open(path, FileAccess.READ)
	assert_eq(file.get_as_text(), content)
	file.close()
	# Cleanup hint lists .gd and .gd.uid for freshly-created scripts (issue #82).
	assert_has_key(result.data, "cleanup")
	assert_eq(result.data.cleanup.rm, [path, path + ".uid"])
	# Clean up
	DirAccess.remove_absolute(path)


func test_create_script_overwrite_omits_cleanup_hint() -> void:
	## On overwrite the caller already had the file on disk; cleanup.rm would
	## point them at user content, not just scratch — so the field is omitted.
	var path := "res://tests/_mcp_test_overwrite.gd"
	var first := FileAccess.open(path, FileAccess.WRITE)
	assert_true(first != null)
	first.store_string("extends Node\n")
	first.close()
	var result := _handler.create_script({"path": path, "content": "extends Node\n# v2\n"})
	assert_has_key(result, "data")
	assert_false(result.data.has("cleanup"), "Overwrite must not emit a cleanup hint")
	DirAccess.remove_absolute(path)


func test_create_script_missing_path() -> void:
	var result := _handler.create_script({"content": "extends Node\n"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_script_invalid_prefix() -> void:
	var result := _handler.create_script({"path": "/tmp/bad.gd"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_script_wrong_extension() -> void:
	var result := _handler.create_script({"path": "res://test.txt"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- patch_script -----

func test_patch_script_basic() -> void:
	var path := "res://tests/_mcp_test_patch.gd"
	var original := "extends Node\n\nvar speed = 5\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	var result := _handler.patch_script({
		"path": path,
		"old_text": "speed = 5",
		"new_text": "speed = 10",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.replacements, 1)
	assert_false(result.data.undoable)

	var read := FileAccess.open(path, FileAccess.READ)
	var new_content := read.get_as_text()
	read.close()
	assert_contains(new_content, "speed = 10")
	DirAccess.remove_absolute(path)


func test_patch_script_no_match() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"old_text": "this_does_not_exist_anywhere",
		"new_text": "whatever",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_patch_script_ambiguous_match_without_replace_all() -> void:
	var path := "res://tests/_mcp_test_patch_ambig.gd"
	var original := "var x = 1\nvar y = 1\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	var result := _handler.patch_script({
		"path": path,
		"old_text": "= 1",
		"new_text": "= 2",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	DirAccess.remove_absolute(path)


func test_patch_script_replace_all() -> void:
	var path := "res://tests/_mcp_test_patch_all.gd"
	var original := "foo()\nfoo()\nfoo()\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	var result := _handler.patch_script({
		"path": path,
		"old_text": "foo",
		"new_text": "bar",
		"replace_all": true,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.replacements, 3)

	var read := FileAccess.open(path, FileAccess.READ)
	var new_content := read.get_as_text()
	read.close()
	assert_eq(new_content, "bar()\nbar()\nbar()\n")
	DirAccess.remove_absolute(path)


func test_patch_script_missing_old_text() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"new_text": "x",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_patch_script_non_gd_extension_rejected() -> void:
	var result := _handler.patch_script({
		"path": "res://main.tscn",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_patch_script_missing_new_text() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"old_text": "speed",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_patch_script_file_not_found() -> void:
	var result := _handler.patch_script({
		"path": "res://does/not/exist.gd",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_patch_script_invalid_prefix() -> void:
	var result := _handler.patch_script({
		"path": "/tmp/bad.gd",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- read_script -----

func test_read_script_basic() -> void:
	var result := _handler.read_script({"path": TEST_SCRIPT_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_SCRIPT_PATH)
	assert_contains(result.data.content, "class_name _McpTestScript")
	assert_gt(result.data.size, 0, "Size should be positive")
	assert_gt(result.data.line_count, 0, "Line count should be positive")


func test_read_script_missing_path() -> void:
	var result := _handler.read_script({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_read_script_invalid_prefix() -> void:
	var result := _handler.read_script({"path": "/tmp/bad.gd"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_read_script_not_found() -> void:
	var result := _handler.read_script({"path": "res://nonexistent_script.gd"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- attach_script -----

func test_attach_script_basic() -> void:
	# Clean up any leftover node from a prior run
	var scene_root := EditorInterface.get_edited_scene_root()
	var stale := ScenePath.resolve("/Main/_McpTestAttach", scene_root)
	if stale:
		stale.get_parent().remove_child(stale)
		stale.queue_free()

	# Create a temporary node to attach to
	var node_handler := NodeHandler.new(_undo_redo)
	node_handler.create_node({"type": "Node3D", "name": "_McpTestAttach", "parent_path": "/Main"})

	var result := _handler.attach_script({
		"path": "/Main/_McpTestAttach",
		"script_path": TEST_SCRIPT_PATH,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.script_path, TEST_SCRIPT_PATH)
	assert_false(result.data.had_previous_script)
	assert_true(result.data.undoable)

	# Clean up: undo attach then undo create
	_undo_redo.undo()
	_undo_redo.undo()


func test_attach_script_missing_path() -> void:
	var result := _handler.attach_script({"script_path": TEST_SCRIPT_PATH})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_attach_script_missing_script_path() -> void:
	var result := _handler.attach_script({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_attach_script_node_not_found() -> void:
	var result := _handler.attach_script({
		"path": "/Main/DoesNotExist",
		"script_path": TEST_SCRIPT_PATH,
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_attach_script_not_found() -> void:
	var result := _handler.attach_script({
		"path": "/Main/Camera3D",
		"script_path": "res://nonexistent_script.gd",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- detach_script -----

func test_detach_script_no_script() -> void:
	# Camera3D typically has no custom script attached
	# Create a fresh node with no script
	var node_handler := NodeHandler.new(_undo_redo)
	node_handler.create_node({"type": "Node3D", "name": "_McpTestDetach", "parent_path": "/Main"})

	var result := _handler.detach_script({"path": "/Main/_McpTestDetach"})
	assert_has_key(result, "data")
	assert_false(result.data.had_script)

	# Clean up
	_undo_redo.undo()


func test_detach_script_missing_path() -> void:
	var result := _handler.detach_script({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_detach_script_node_not_found() -> void:
	var result := _handler.detach_script({"path": "/Main/DoesNotExist"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- find_symbols -----

func test_find_symbols_basic() -> void:
	var result := _handler.find_symbols({"path": TEST_SCRIPT_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_SCRIPT_PATH)
	assert_eq(result.data.class_name, "_McpTestScript")
	assert_eq(result.data.extends, "Node3D")


func test_find_symbols_functions() -> void:
	var result := _handler.find_symbols({"path": TEST_SCRIPT_PATH})
	assert_gt(result.data.function_count, 0, "Should find functions")
	var func_names: Array[String] = []
	for fn: Dictionary in result.data.functions:
		func_names.append(fn.name)
	assert_contains(func_names, "_ready")
	assert_contains(func_names, "move")


func test_find_symbols_signals() -> void:
	var result := _handler.find_symbols({"path": TEST_SCRIPT_PATH})
	assert_eq(result.data.signal_count, 2)
	assert_contains(result.data.signals, "health_changed")
	assert_contains(result.data.signals, "died")


func test_find_symbols_exports() -> void:
	var result := _handler.find_symbols({"path": TEST_SCRIPT_PATH})
	assert_eq(result.data.export_count, 2)
	var export_names: Array[String] = []
	for exp: Dictionary in result.data.exports:
		export_names.append(exp.name)
	assert_contains(export_names, "speed")
	assert_contains(export_names, "max_health")


func test_find_symbols_missing_path() -> void:
	var result := _handler.find_symbols({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_find_symbols_invalid_prefix() -> void:
	var result := _handler.find_symbols({"path": "/tmp/bad.gd"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_find_symbols_not_found() -> void:
	var result := _handler.find_symbols({"path": "res://nonexistent_script.gd"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
