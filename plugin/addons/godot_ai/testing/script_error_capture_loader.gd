@tool
extends RefCounted

## Builds the Logger-based test script-error capture lazily.
##
## Logger exists only on newer Godot versions. The capture implementation lives
## under a `.gdignore`d folder and is compiled from source only after the runner
## verifies the Logger API is present, so older editor scans do not parse an
## `extends Logger` file and emit red startup errors.

const SCRIPT_ERROR_CAPTURE_PATH := "res://addons/godot_ai/testing/loggers/script_error_capture.gd"


static func build() -> Object:
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return null
	if not FileAccess.file_exists(SCRIPT_ERROR_CAPTURE_PATH):
		return null
	var source := FileAccess.get_file_as_string(SCRIPT_ERROR_CAPTURE_PATH)
	if source.is_empty():
		return null
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return null
	return script.new()
