@tool
extends Logger

## Game-process Logger subclass.
##
## NOTE: deliberately no `class_name` — `extends Logger` requires the Logger
## class which Godot only exposes from 4.5+. game_helper.gd loads this
## script dynamically via load() after gating on
## ClassDB.class_exists("Logger"), so the script never gets parsed on
## older engines. Registered via OS.add_logger() from inside
## the running game so we can intercept print(), printerr(), push_error(),
## and push_warning() and ferry them back to the editor over the
## EngineDebugger channel — the same bridge PR #76 uses for screenshots.
##
## Logger virtuals can be called from any thread (e.g. async loaders push
## errors off the main thread). We accumulate into _pending under a Mutex
## and the host (game_helper.gd) flushes once per frame from the main
## thread, where EngineDebugger.send_message is safe to call.

var _pending: Array = []
var _mutex := Mutex.new()


func _log_message(message: String, error: bool) -> void:
	## `error` is true for printerr(), false for print().
	var level := "error" if error else "info"
	_append(level, message)


func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	script_backtraces: Array,
) -> void:
	## LogBacktrace.resolve_error coalesces the per-virtual-arg shape
	## (level mapping, rationale-vs-code fallback, backtrace-driven source
	## remap) — the same logic editor_logger needs. Format `loc` from the
	## resolved fields so the queued text carries a human-readable source
	## suffix; editor_logger uses the structured fields directly instead.
	var resolved := LogBacktrace.resolve_error(
		function, file, line, code, rationale, error_type, script_backtraces,
	)
	var src_file: String = resolved.path
	var src_line: int = resolved.line
	var src_function: String = resolved.function
	var loc := ""
	if not src_file.is_empty():
		loc = "%s:%d @ %s" % [src_file, src_line, src_function] if not src_function.is_empty() else "%s:%d" % [src_file, src_line]
	var text: String = "%s (%s)" % [resolved.message, loc] if not loc.is_empty() else resolved.message
	_append(resolved.level, text)


func _append(level: String, text: String) -> void:
	_mutex.lock()
	_pending.append([level, text])
	_mutex.unlock()


## Drain the pending queue and return entries as [[level, text], ...].
## Called from the main thread by game_helper each frame.
func drain() -> Array:
	_mutex.lock()
	var out := _pending
	_pending = []
	_mutex.unlock()
	return out


func has_pending() -> bool:
	_mutex.lock()
	var any := not _pending.is_empty()
	_mutex.unlock()
	return any
