@tool
extends RefCounted

## Minimal duck-typed stand-in for Godot's built-in `ScriptBacktrace`
## class (the type of `script_backtraces[i]` entries inside `_log_error`).
## Mirrors the getter surface `_log_error`'s `script_backtraces` argument
## exposes (`get_frame_count` + per-frame file/line/function), so test
## suites for `editor_logger` and `game_logger` can exercise the
## backtrace-remapping path without a live script execution — Godot
## doesn't expose a constructor for the real ScriptBacktrace.
##
## Defaults to a single frame for existing tests, but can carry multiple
## frames so detail payload tests can verify full stack preservation.

var _frames: Array[Dictionary] = []


func _init(file: String, line: int, function: String, frames: Array[Dictionary] = []) -> void:
	if frames.is_empty():
		_frames = [{"path": file, "line": line, "function": function}]
	else:
		_frames = frames


func get_frame_count() -> int:
	return _frames.size()


func get_frame_file(idx: int) -> String:
	return str(_frames[idx].get("path", ""))


func get_frame_line(idx: int) -> int:
	return int(_frames[idx].get("line", 0))


func get_frame_function(idx: int) -> String:
	return str(_frames[idx].get("function", ""))
