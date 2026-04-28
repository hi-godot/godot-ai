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
	## EngineDebugger's payload shape is `[level, text]` — the source
	## location has nowhere structured to land for the game side, so we
	## inline it into `text`. editor_logger keeps the resolved fields
	## as structured columns instead.
	var resolved := LogBacktrace.resolve_error(
		function, file, line, code, rationale, error_type, script_backtraces,
	)
	var loc := ""
	if not resolved.path.is_empty():
		loc = "%s:%d @ %s" % [resolved.path, resolved.line, resolved.function] if not resolved.function.is_empty() else "%s:%d" % [resolved.path, resolved.line]
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
