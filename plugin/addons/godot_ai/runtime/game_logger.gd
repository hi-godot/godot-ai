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

const FLUSH_BATCH_LIMIT := 200

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
	_code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array,
) -> void:
	## error_type: 0 = ERROR (push_error), 1 = WARNING (push_warning),
	## 2 = SCRIPT, 3 = SHADER. Map warnings to "warn" so callers can filter
	## without consulting the enum.
	var level := "warn" if error_type == 1 else "error"
	var loc := ""
	if not file.is_empty():
		loc = "%s:%d @ %s" % [file, line, function] if not function.is_empty() else "%s:%d" % [file, line]
	var text := "%s (%s)" % [rationale, loc] if not loc.is_empty() else rationale
	_append(level, text)


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
