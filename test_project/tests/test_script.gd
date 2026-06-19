@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const _LoggerLoader := preload("res://addons/godot_ai/runtime/logger_loader.gd")

## Tests for ScriptHandler — script creation, reading, attach/detach, and symbol inspection.

const INVALID_IF_PARSE_ERROR := "Parse Error: Expected conditional expression after \"if\"."

var _handler: ScriptHandler
var _undo_redo: EditorUndoRedoManager
var _attached_shared_logger = null

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

static func make_default() -> _McpTestScript:
	return null
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
	_detach_shared_editor_logger()
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
	assert_eq(result.data.committed, true)
	assert_eq(result.data.import_settled, false)
	assert_eq(result.data.import_settle, "not_waited")
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "none")
	assert_eq(result.data.diagnostics, [])
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


func test_create_script_reports_log_capture_diagnostics_with_real_line() -> void:
	if skip_on_godot_lt("4.5", "Logger subclass only exists on Godot 4.5+"):
		return
	var path := "res://tests/_mcp_test_invalid_create.gd"
	var content := "extends Node\n\nfunc _ready() -> void:\n\tif\n\tpass\n"
	_expect_invalid_if_parse_errors()
	var result := _handler.create_script({"path": path, "content": content})
	assert_has_key(result, "data")
	assert_eq(result.data.path, path)
	assert_eq(result.data.committed, true)
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "log_capture")
	assert_eq(result.data.diagnostics.size(), 1, "Invalid GDScript should report one diagnostic")
	assert_eq(result.data.diagnostics[0].path, path)
	assert_eq(result.data.diagnostics[0].line, 4)
	assert_eq(result.data.diagnostics[0].level, "error")
	assert_contains(result.data.diagnostics[0].text, "Parse Error")
	assert_false(result.data.diagnostics[0].details.has("fallback_line"), "Real capture must not use fallback line guesses")
	assert_eq(result.data.diagnostics[0].details.source.path, path)
	assert_eq(result.data.diagnostics[0].details.source.line, 4)
	assert_true(FileAccess.file_exists(path), "Invalid content is still written so the agent can fix it")
	DirAccess.remove_absolute(path)


func test_create_script_validation_does_not_pollute_shared_editor_log() -> void:
	var shared_buf := McpEditorLogBuffer.new()
	if not _attach_shared_editor_logger(shared_buf):
		return
	var path := "res://tests/_mcp_test_invalid_create_shared_log.gd"
	var content := "extends Node\n\nfunc _ready() -> void:\n\tif\n\tpass\n"
	var cursor := shared_buf.appended_total()
	_expect_invalid_if_parse_errors()
	var result := _handler.create_script({"path": path, "content": content})
	_detach_shared_editor_logger()

	assert_has_key(result, "data")
	assert_eq(result.data.diagnostics_detail, "log_capture")
	assert_eq(result.data.diagnostics.size(), 1, "Invalid GDScript should report one diagnostic")
	var captured := shared_buf.get_since(cursor)
	assert_eq(captured.entries.size(), 0, "Validation load diagnostics must not leak into the shared editor log")
	DirAccess.remove_absolute(path)


func test_create_script_reports_fallback_diagnostics_without_logger() -> void:
	if ClassDB.class_exists("Logger"):
		skip("Fallback branch is exercised on Godot versions without Logger")
		return
	var path := "res://tests/_mcp_test_invalid_create_no_logger.gd"
	var content := "extends Node\n\nfunc _ready() -> void:\n\tif\n\tpass\n"
	var result := _handler.create_script({"path": path, "content": content})
	assert_has_key(result, "data")
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "fallback")
	assert_gt(result.data.diagnostics.size(), 0)
	assert_eq(result.data.diagnostics[0].path, path)
	assert_eq(result.data.diagnostics[0].line, 5)
	assert_eq(result.data.diagnostics[0].details.fallback_line, true)
	DirAccess.remove_absolute(path)


func _attach_shared_editor_logger(buffer: McpEditorLogBuffer) -> bool:
	_detach_shared_editor_logger()
	if skip_on_godot_lt("4.5", "Logger subclass only exists on Godot 4.5+"):
		return false
	if not OS.has_method("add_logger") or not OS.has_method("remove_logger"):
		skip("Logger API is unavailable")
		return false
	var logger_script := _LoggerLoader.build(_LoggerLoader.EDITOR_LOGGER_PATH)
	assert_true(logger_script != null, "Editor logger script should compile on Godot 4.5+")
	if logger_script == null:
		return false
	_attached_shared_logger = logger_script.new(buffer)
	OS.call("add_logger", _attached_shared_logger)
	return true


func _detach_shared_editor_logger() -> void:
	if _attached_shared_logger != null and OS.has_method("remove_logger"):
		OS.call("remove_logger", _attached_shared_logger)
	_attached_shared_logger = null


func _expect_invalid_if_parse_errors() -> void:
	# Godot 4.7 adds one more logger-visible copy of this parse diagnostic.
	# Expect the maximum seen across supported engines; older versions tolerate
	# extra expectations for errors that are never emitted.
	expect_script_error_containing(INVALID_IF_PARSE_ERROR)
	expect_script_error_containing(INVALID_IF_PARSE_ERROR)
	expect_script_error_containing(INVALID_IF_PARSE_ERROR)


func test_finish_create_script_deferred_is_static_and_handles_null_connection() -> void:
	## Under stress (many concurrent script_create + editor_reload_plugin
	## mid-burst) the ScriptHandler RefCounted was being freed mid-await of
	## _finish_create_script_deferred, producing "Resumed function ... after
	## await, but class instance is gone" errors and dropping the response.
	## The fix is to make the deferred completion a `static` function so the
	## coroutine doesn't capture self.
	##
	## Calling the function directly via the Script resource exercises both
	## guarantees in one go: if the function isn't `static`, the parser
	## rejects this call site ("Cannot call non-static function ... directly,
	## make an instance instead") and the whole test file fails to load. If
	## it IS static, the null-connection branch must bail without awaiting or
	## sending a deferred response — the safety net for teardown-time callers.
	##
	## The Python source-pin in tests/unit/test_script_create_import_settle.py
	## also asserts the `static func` declaration at the source-text level.
	var ScriptHandlerScript := preload("res://addons/godot_ai/handlers/script_handler.gd")
	ScriptHandlerScript._finish_create_script_deferred(null, "req-x", "res://nope.gd", {})
	assert_true(true, "Static call with null connection must not raise")


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
	assert_eq(result.data.committed, true)
	assert_eq(result.data.import_settled, true)
	assert_eq(result.data.import_settle, "already_known")
	assert_false(result.data.has("cleanup"), "Overwrite must not emit a cleanup hint")
	DirAccess.remove_absolute(path)


func test_create_script_missing_path() -> void:
	var result := _handler.create_script({"content": "extends Node\n"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_create_script_invalid_prefix() -> void:
	var result := _handler.create_script({"path": "/tmp/bad.gd"})
	assert_is_error(result)


func test_create_script_wrong_extension() -> void:
	var result := _handler.create_script({"path": "res://test.txt"})
	assert_is_error(result)


func test_create_script_rejects_traversal_path() -> void:
	## Issue #347: `res://../etc/passwd.gd` previously passed the prefix check.
	## Use a synthetic target so a host with a pre-existing
	## `<project_parent>/etc/passwd.gd` couldn't false-positive the disk
	## assertion. The synthetic name never exists in a clean tree.
	var traversal_path := "res://../__mcp_traversal_test_target__.gd"
	var result := _handler.create_script({
		"path": traversal_path,
		"content": "extends Node\n",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "..")
	## Defence: confirm the file was NOT written outside the project.
	assert_false(FileAccess.file_exists(traversal_path), "traversal must not write to disk")


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
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "none")
	assert_eq(result.data.diagnostics, [])
	assert_false(result.data.undoable)

	var read := FileAccess.open(path, FileAccess.READ)
	var new_content := read.get_as_text()
	read.close()
	assert_contains(new_content, "speed = 10")
	DirAccess.remove_absolute(path)


func test_patch_script_reports_log_capture_diagnostics_with_real_line() -> void:
	if skip_on_godot_lt("4.5", "Logger subclass only exists on Godot 4.5+"):
		return
	var path := "res://tests/_mcp_test_invalid_patch.gd"
	var original := "extends Node\n\nfunc _ready() -> void:\n\tpass\n\tprint(\"after\")\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	_expect_invalid_if_parse_errors()
	var result := _handler.patch_script({
		"path": path,
		"old_text": "pass",
		"new_text": "if",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.path, path)
	assert_eq(result.data.replacements, 1)
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "log_capture")
	assert_eq(result.data.diagnostics.size(), 1, "Invalid patched GDScript should report one diagnostic")
	assert_eq(result.data.diagnostics[0].path, path)
	assert_eq(result.data.diagnostics[0].line, 4)
	assert_eq(result.data.diagnostics[0].level, "error")
	assert_contains(result.data.diagnostics[0].text, "Parse Error")
	assert_false(result.data.diagnostics[0].details.has("fallback_line"), "Real capture must not use fallback line guesses")
	assert_eq(result.data.diagnostics[0].details.source.path, path)
	assert_eq(result.data.diagnostics[0].details.source.line, 4)

	var read := FileAccess.open(path, FileAccess.READ)
	var new_content := read.get_as_text()
	read.close()
	assert_contains(new_content, "if")
	DirAccess.remove_absolute(path)


func test_patch_script_validation_does_not_pollute_shared_editor_log() -> void:
	var shared_buf := McpEditorLogBuffer.new()
	if not _attach_shared_editor_logger(shared_buf):
		return
	var path := "res://tests/_mcp_test_invalid_patch_shared_log.gd"
	var original := "extends Node\n\nfunc _ready() -> void:\n\tpass\n\tprint(\"after\")\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	var cursor := shared_buf.appended_total()
	_expect_invalid_if_parse_errors()
	var result := _handler.patch_script({
		"path": path,
		"old_text": "pass",
		"new_text": "if",
	})
	_detach_shared_editor_logger()

	assert_has_key(result, "data")
	assert_eq(result.data.diagnostics_detail, "log_capture")
	assert_eq(result.data.diagnostics.size(), 1, "Invalid patched GDScript should report one diagnostic")
	var captured := shared_buf.get_since(cursor)
	assert_eq(captured.entries.size(), 0, "Validation load diagnostics must not leak into the shared editor log")
	DirAccess.remove_absolute(path)


func test_patch_script_reports_fallback_diagnostics_without_logger() -> void:
	if ClassDB.class_exists("Logger"):
		skip("Fallback branch is exercised on Godot versions without Logger")
		return
	var path := "res://tests/_mcp_test_invalid_patch_no_logger.gd"
	var original := "extends Node\n\nfunc _ready() -> void:\n\tpass\n\tprint(\"after\")\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(original)
	file.close()

	var result := _handler.patch_script({
		"path": path,
		"old_text": "pass",
		"new_text": "if",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.path, path)
	assert_eq(result.data.diagnostics_scope, "this_file")
	assert_eq(result.data.diagnostics_status, "checked")
	assert_eq(result.data.diagnostics_detail, "fallback")
	assert_gt(result.data.diagnostics.size(), 0)
	assert_eq(result.data.diagnostics[0].path, path)
	assert_eq(result.data.diagnostics[0].line, 5)
	assert_eq(result.data.diagnostics[0].details.fallback_line, true)
	DirAccess.remove_absolute(path)


func test_patch_script_no_match() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"old_text": "this_does_not_exist_anywhere",
		"new_text": "whatever",
	})
	assert_is_error(result)


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
	assert_is_error(result)
	DirAccess.remove_absolute(path)


func test_patch_script_replace_all() -> void:
	var path := "res://tests/_mcp_test_patch_all.gd"
	var original := "extends Node\n\n# foo\n# foo\n# foo\n"
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
	assert_eq(new_content, "extends Node\n\n# bar\n# bar\n# bar\n")
	DirAccess.remove_absolute(path)


func test_patch_script_missing_old_text() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"new_text": "x",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_patch_script_non_gd_extension_rejected() -> void:
	var result := _handler.patch_script({
		"path": "res://main.tscn",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result)


func test_patch_script_missing_new_text() -> void:
	var result := _handler.patch_script({
		"path": TEST_SCRIPT_PATH,
		"old_text": "speed",
	})
	assert_is_error(result)


func test_patch_script_file_not_found() -> void:
	var result := _handler.patch_script({
		"path": "res://does/not/exist.gd",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_patch_script_invalid_prefix() -> void:
	var result := _handler.patch_script({
		"path": "/tmp/bad.gd",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result)


func test_patch_script_rejects_traversal_path() -> void:
	## Issue #347 regression: traversal must be caught before the file is
	## opened for read or write.
	var result := _handler.patch_script({
		"path": "res://../etc/passwd.gd",
		"old_text": "x",
		"new_text": "y",
	})
	assert_is_error(result)
	assert_contains(result.error.message, "..")


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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_read_script_invalid_prefix() -> void:
	var result := _handler.read_script({"path": "/tmp/bad.gd"})
	assert_is_error(result)


func test_read_script_not_found() -> void:
	var result := _handler.read_script({"path": "res://nonexistent_script.gd"})
	assert_is_error(result)


func test_read_script_rejects_traversal_path() -> void:
	## Issue #347: read_script must not become a file-disclosure primitive.
	var result := _handler.read_script({"path": "res://../etc/passwd.gd"})
	assert_is_error(result)
	assert_contains(result.error.message, "..")


# ----- attach_script -----

func test_attach_script_basic() -> void:
	# Clean up any leftover node from a prior run
	var scene_root := EditorInterface.get_edited_scene_root()
	var stale := McpScenePath.resolve("/Main/_McpTestAttach", scene_root)
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
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_attach_script_missing_path() -> void:
	var result := _handler.attach_script({"script_path": TEST_SCRIPT_PATH})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_attach_script_missing_script_path() -> void:
	var result := _handler.attach_script({"path": "/Main/Camera3D"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_attach_script_node_not_found() -> void:
	var result := _handler.attach_script({
		"path": "/Main/DoesNotExist",
		"script_path": TEST_SCRIPT_PATH,
	})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


func test_attach_script_not_found() -> void:
	var result := _handler.attach_script({
		"path": "/Main/Camera3D",
		"script_path": "res://nonexistent_script.gd",
	})
	assert_is_error(result)


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
	assert_true(editor_undo(_undo_redo), "undo should succeed")


func test_detach_script_missing_path() -> void:
	var result := _handler.detach_script({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_detach_script_node_not_found() -> void:
	var result := _handler.detach_script({"path": "/Main/DoesNotExist"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


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
	## Regression: `static func` declarations must be detected too (not just
	## plain `func`). See script_handler.find_symbols.
	assert_contains(func_names, "make_default")


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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_find_symbols_invalid_prefix() -> void:
	var result := _handler.find_symbols({"path": "/tmp/bad.gd"})
	assert_is_error(result)


func test_find_symbols_not_found() -> void:
	var result := _handler.find_symbols({"path": "res://nonexistent_script.gd"})
	assert_is_error(result)


func test_find_symbols_rejects_traversal_path() -> void:
	## Issue #347: find_symbols also reads file content; same disclosure surface.
	var result := _handler.find_symbols({"path": "res://../etc/passwd.gd"})
	assert_is_error(result)
	assert_contains(result.error.message, "..")
