@tool
extends Logger

## Captures GDScript runtime errors emitted while a test is running.
##
## Deliberately no class_name: this is an internal test helper.
##
## Only ERROR_TYPE_SCRIPT is captured. push_error(), push_warning(), and
## engine-internal ERR_FAIL_* checks are often valid negative-path assertions and
## should not abort the test.

var _mutex := Mutex.new()
var _capturing := false
var _errors := PackedStringArray()


func begin_capture() -> void:
	_mutex.lock()
	_capturing = true
	_errors.clear()
	_mutex.unlock()


func end_capture() -> PackedStringArray:
	_mutex.lock()
	var captured := _errors.duplicate()
	_capturing = false
	_errors.clear()
	_mutex.unlock()
	return captured


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array,
) -> void:
	if error_type != ERROR_TYPE_SCRIPT:
		return
	_mutex.lock()
	if _capturing:
		var text := rationale if not rationale.is_empty() else code
		_errors.append("%s (%s:%d in %s)" % [text, file, line, function])
	_mutex.unlock()
