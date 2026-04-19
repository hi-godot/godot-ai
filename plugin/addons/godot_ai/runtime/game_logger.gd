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
	## error_type: 0 = ERROR (push_error), 1 = WARNING (push_warning),
	## 2 = SCRIPT, 3 = SHADER. Map warnings to "warn" so callers can filter
	## without consulting the enum.
	##
	## Single-arg push_error("msg") / push_warning("msg") stores the user's
	## string in `code` and leaves `rationale` empty; the two-arg form
	## push_error(code, rationale) populates both. Fall back to `code` when
	## `rationale` is missing — otherwise the user's message is silently lost.
	##
	## `file`/`line` for push_error/push_warning point into Godot's own C++
	## source (core/variant/variant_utility.cpp). Prefer the first frame of
	## `script_backtraces` so the capture shows the caller's GDScript location.
	var level := "warn" if error_type == 1 else "error"
	var message := rationale if not rationale.is_empty() else code
	var src_file := file
	var src_line := line
	var src_function := function
	for bt in script_backtraces:
		if bt != null and bt.get_frame_count() > 0:
			src_file = bt.get_frame_file(0)
			src_line = bt.get_frame_line(0)
			src_function = bt.get_frame_function(0)
			break
	var loc := ""
	if not src_file.is_empty():
		loc = "%s:%d @ %s" % [src_file, src_line, src_function] if not src_function.is_empty() else "%s:%d" % [src_file, src_line]
	var text := "%s (%s)" % [message, loc] if not loc.is_empty() else message
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
