@tool
class_name McpTestSuite
extends RefCounted

## Base class for MCP test suites. Provides assertion methods and
## lifecycle hooks. Subclass this, add test_* methods, and drop the
## script in res://tests/.

## Override to return a short name for this suite (e.g. "scene", "node").
func suite_name() -> String:
	return "unnamed"


## Called once before the suite runs. Override to create handlers.
func suite_setup(_ctx: Dictionary) -> void:
	pass


## Called before each test method.
func setup() -> void:
	pass


## Called after each test method.
func teardown() -> void:
	pass


## Called once after the suite finishes.
func suite_teardown() -> void:
	pass


# ----- assertion state (managed by McpTestRunner) -----

var _failed: bool = false
var _message: String = ""
var _assertion_count: int = 0
var _skipped: bool = false
var _skip_reason: String = ""

# ----- suite-level state (managed by McpTestRunner) -----

var _suite_failed: bool = false
var _suite_failed_message: String = ""
var _suite_skipped: bool = false
var _suite_skipped_reason: String = ""


func _reset() -> void:
	_failed = false
	_message = ""
	_assertion_count = 0
	_skipped = false
	_skip_reason = ""


func _reset_suite_state() -> void:
	_suite_failed = false
	_suite_failed_message = ""
	_suite_skipped = false
	_suite_skipped_reason = ""


## Mark the current test as skipped. Use when a precondition isn't met
## (e.g. no scene open, no Node3D in scene) and the test can't run.
## Skipped tests count separately from passed/failed.
func skip(reason: String = "") -> void:
	_skipped = true
	_skip_reason = reason


## Bail out of suite_setup() with a failure. Subsequent tests in this suite
## are not run; the runner reports a single suite-level failure with the
## given reason instead of N zero-assertion noise lines per test.
##
## Example:
##     func suite_setup(ctx):
##         var arena = preload("res://game/arena.gd").new()
##         if arena == null:
##             fail_setup("arena.gd failed to instantiate in @tool scope")
##             return
func fail_setup(reason: String) -> void:
	_suite_failed = true
	_suite_failed_message = reason


## Bail out of suite_setup() because a precondition isn't met (no scene open,
## no game running, etc.). Subsequent tests are not run and the runner emits
## a single suite-level skip rather than per-test skip noise.
func skip_suite(reason: String) -> void:
	_suite_skipped = true
	_suite_skipped_reason = reason


## Trigger an undo against whichever history (scene or global) holds the most
## recent action. `EditorUndoRedoManager` in Godot 4.x doesn't expose `.undo()`
## directly — you resolve the history's underlying UndoRedo and call it there.
## Actions registered via `add_do_method(self, …)` with a non-scene target land
## in GLOBAL_HISTORY, while actions on scene nodes land in the scene's history,
## so we try both (matches the pattern in batch_handler.gd).
func editor_undo(undo_redo: EditorUndoRedoManager) -> bool:
	for ur in _collect_histories(undo_redo):
		if ur.undo():
			return true
	return false


## Mirror of `editor_undo` for redo.
func editor_redo(undo_redo: EditorUndoRedoManager) -> bool:
	for ur in _collect_histories(undo_redo):
		if ur.redo():
			return true
	return false


func _collect_histories(undo_redo: EditorUndoRedoManager) -> Array:
	var out: Array = []
	if undo_redo == null:
		return out
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		var scene_id := undo_redo.get_object_history_id(scene_root)
		var scene_ur := undo_redo.get_history_undo_redo(scene_id)
		if scene_ur != null:
			out.append(scene_ur)
	var global_ur := undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	if global_ur != null and not global_ur in out:
		out.append(global_ur)
	return out


# ----- assertions -----

func assert_true(condition: bool, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if not condition:
		_failed = true
		_message = msg if msg else "Expected true"


func assert_false(condition: bool, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if condition:
		_failed = true
		_message = msg if msg else "Expected false"


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if actual != expected:
		_failed = true
		_message = msg if msg else "Expected %s, got %s" % [str(expected), str(actual)]


func assert_ne(actual: Variant, not_expected: Variant, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if actual == not_expected:
		_failed = true
		_message = msg if msg else "Expected value != %s" % str(not_expected)


func assert_gt(actual: Variant, threshold: Variant, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if not (actual > threshold):
		_failed = true
		_message = msg if msg else "Expected %s > %s" % [str(actual), str(threshold)]


func assert_has_key(dict: Variant, key: String, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if not dict is Dictionary:
		_failed = true
		_message = msg if msg else "Expected Dictionary, got %s" % type_string(typeof(dict))
		return
	if not dict.has(key):
		_failed = true
		_message = msg if msg else "Missing key: %s (keys: %s)" % [key, str(dict.keys())]


func assert_contains(haystack: Variant, needle: Variant, msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if haystack is String:
		if haystack.find(str(needle)) == -1:
			_failed = true
			_message = msg if msg else "'%s' not found in '%s'" % [str(needle), haystack]
	elif haystack is Array:
		if not haystack.has(needle):
			_failed = true
			_message = msg if msg else "%s not found in array" % str(needle)
	else:
		_failed = true
		_message = msg if msg else "assert_contains requires String or Array"


func assert_is_error(result: Dictionary, expected_code: String = "", msg: String = "") -> void:
	_assertion_count += 1
	if _failed:
		return
	if not result.has("error"):
		_failed = true
		_message = msg if msg else "Expected error response, got: %s" % str(result.keys())
		return
	if expected_code and result.error.get("code", "") != expected_code:
		_failed = true
		_message = msg if msg else "Expected error code %s, got %s" % [expected_code, result.error.get("code", "")]


# ----- scene helpers (shared across suites that create/remove Controls) -----

## Add a Control under the scene root. Creates a Panel if ctl is null.
## Returns the scene path, or "" when no scene is open — in which case a
## caller-supplied ctl is freed to prevent leaks.
func _add_control(ctl_name: String, ctl: Control = null) -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		if ctl != null:
			ctl.queue_free()
		return ""
	if ctl == null:
		ctl = Panel.new()
	ctl.name = ctl_name
	scene_root.add_child(ctl)
	ctl.owner = scene_root
	return "/" + scene_root.name + "/" + ctl_name


func _remove_control(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var node := ScenePath.resolve(path, scene_root)
	if node != null:
		node.get_parent().remove_child(node)
		node.queue_free()
