@tool
class_name StubBacktrace
extends RefCounted

## Minimal duck-typed stand-in for Godot's built-in `ScriptBacktrace`
## class (the type of `script_backtraces[i]` entries inside `_log_error`).
## Mirrors the getter surface `_log_error`'s `script_backtraces` argument
## exposes (`get_frame_count` + per-frame file/line/function), so test
## suites for `editor_logger` and `game_logger` can exercise the
## backtrace-remapping path without a live script execution — Godot
## doesn't expose a constructor for the real ScriptBacktrace.
##
## Single-frame is enough: both loggers only consult the first non-empty
## frame of `script_backtraces` (via `LogBacktrace.resolve_error`).

var _file: String
var _line: int
var _function: String


func _init(file: String, line: int, function: String) -> void:
	_file = file
	_line = line
	_function = function


func get_frame_count() -> int:
	return 1


func get_frame_file(_idx: int) -> String:
	return _file


func get_frame_line(_idx: int) -> int:
	return _line


func get_frame_function(_idx: int) -> String:
	return _function
