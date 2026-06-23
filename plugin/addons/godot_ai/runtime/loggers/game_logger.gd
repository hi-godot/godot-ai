@tool
extends Logger

## Game-process Logger subclass.
##
## NOTE: deliberately no `class_name` — `extends Logger` requires the Logger
## class which Godot only exposes from 4.5+. This file lives in the
## `.gdignore`'d `runtime/loggers/` folder so Godot's editor filesystem scan
## skips it entirely — on Godot < 4.5 it is never parsed, so it emits no
## "Could not find base class Logger" error (it used to, before #475's
## follow-up). game_helper.gd builds it from source at runtime via
## `logger_loader.gd` and only calls OS.add_logger() after gating on
## ClassDB.class_exists("Logger"). Registered from inside the running game
## so we can intercept print(), printerr(), push_error(), and
## push_warning() and ferry them back to the editor over the
## EngineDebugger channel — the same bridge PR #76 uses for screenshots.
##
## Logger virtuals can be called from any thread (e.g. async loaders push
## errors off the main thread). We accumulate into _pending under a Mutex
## and the host (game_helper.gd) flushes once per frame from the main
## thread, where EngineDebugger.send_message is safe to call.

## `McpLogBacktrace` is published as a `class_name` on log_backtrace.gd, but a
## freshly-launched game subprocess (no prior editor scan; e.g. CI launching
## `--headless --path`) hits this autoload before the global class_name table
## is populated, and parsing this script fails with
## "Identifier 'McpLogBacktrace' not declared in the current scope". Using
## `const preload` resolves the path at parse time and is independent of the
## class_name registry — matches the project convention in CLAUDE.md
## ("Internals … skip class_name entirely and load via const preload").
const _LogBacktrace := preload("res://addons/godot_ai/utils/log_backtrace.gd")

var _pending: Array = []
var _mutex := Mutex.new()
## #490: a monotonic sequence + a small ring of recent GDScript runtime
## (script-type) errors, each with its text AND the function names in its
## backtrace. game_helper uses this to attribute a runtime error to the
## *specific* eval that raised it: each eval's wrapper has a uniquely named
## inner function, and game_helper asks find_script_error_since() whether any
## error past its pre-eval baseline carries that function in its stack. This
## avoids failing an eval on an unrelated background game error that merely
## advanced a global counter, and keeps overlapping evals from cross-
## attributing. Gated on ERROR_TYPE_SCRIPT (2) so push_error()/push_warning()
## (types 0/1) never count. Mutex-guarded: _log_error can fire from any thread.
const _ERROR_TYPE_SCRIPT := 2
const _MAX_RECENT_SCRIPT_ERRORS := 64
var _script_error_seq: int = 0
var _recent_script_errors: Array = []


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
	var resolved := _LogBacktrace.resolve_error(
		function, file, line, code, rationale, error_type, script_backtraces,
	)
	var loc := ""
	if not resolved.path.is_empty():
		loc = "%s:%d @ %s" % [resolved.path, resolved.line, resolved.function] if not resolved.function.is_empty() else "%s:%d" % [resolved.path, resolved.line]
	var text: String = "%s (%s)" % [resolved.message, loc] if not loc.is_empty() else resolved.message
	var details: Dictionary = resolved.get("details", {})
	_append(resolved.level, text, details)
	if error_type == _ERROR_TYPE_SCRIPT:
		## Collect every function name in the first non-empty backtrace so
		## game_helper can match its eval's uniquely named wrapper function.
		var funcs := PackedStringArray()
		for bt: RefCounted in script_backtraces:
			if bt != null and bt.get_frame_count() > 0:
				for i: int in bt.get_frame_count():
					funcs.append(bt.get_frame_function(i))
				break
		_mutex.lock()
		_script_error_seq += 1
		_recent_script_errors.append({"seq": _script_error_seq, "text": text, "funcs": funcs})
		if _recent_script_errors.size() > _MAX_RECENT_SCRIPT_ERRORS:
			_recent_script_errors.remove_at(0)
		_mutex.unlock()


func _append(level: String, text: String, details: Dictionary = {}) -> void:
	_mutex.lock()
	if details.is_empty():
		_pending.append([level, text])
	else:
		_pending.append([level, text, details.duplicate(true)])
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


## #490: monotonic count of script-type runtime errors seen this run.
## game_helper snapshots this before an eval to use as the `since_seq`
## baseline for find_script_error_since(). Mutex-guarded.
func script_error_seq() -> int:
	_mutex.lock()
	var v := _script_error_seq
	_mutex.unlock()
	return v


## #490: text (with inlined path:line @ function) of the most recent
## script-type runtime error, or "" if none seen this run.
func last_script_error_text() -> String:
	_mutex.lock()
	var v: String = _recent_script_errors[-1]["text"] if not _recent_script_errors.is_empty() else ""
	_mutex.unlock()
	return v


## #490: text of the most recent script error with seq > since_seq whose
## backtrace includes `function_name`, or "" if none. Lets game_helper
## attribute a runtime error to the exact eval whose uniquely named wrapper
## function appears in the stack — ignoring unrelated game errors and errors
## from before the eval started. Mutex-guarded.
func find_script_error_since(since_seq: int, function_name: String) -> String:
	_mutex.lock()
	var found := ""
	for i in range(_recent_script_errors.size() - 1, -1, -1):
		var rec: Dictionary = _recent_script_errors[i]
		if int(rec["seq"]) <= since_seq:
			break
		if (rec["funcs"] as PackedStringArray).has(function_name):
			found = rec["text"]
			break
	_mutex.unlock()
	return found
