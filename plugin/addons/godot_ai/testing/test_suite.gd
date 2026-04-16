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


func _reset() -> void:
	_failed = false
	_message = ""
	_assertion_count = 0
	_skipped = false
	_skip_reason = ""


## Mark the current test as skipped. Use when a precondition isn't met
## (e.g. no scene open, no Node3D in scene) and the test can't run.
## Skipped tests count separately from passed/failed.
func skip(reason: String = "") -> void:
	_skipped = true
	_skip_reason = reason


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
