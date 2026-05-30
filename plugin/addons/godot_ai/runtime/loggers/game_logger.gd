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
## #490: monotonic count of GDScript runtime (script-type) errors seen this
## run, plus the text of the most recent one. game_helper snapshots the
## count before running eval code and compares each frame to detect a
## runtime error that aborted the eval before it could reply. Gated on
## ERROR_TYPE_SCRIPT (2) so push_error()/push_warning() (types 0/1) don't
## count — otherwise a benign push_error in eval code would be misreported
## as a fatal error. Mutex-guarded: _log_error can fire from any thread.
const _ERROR_TYPE_SCRIPT := 2
var _script_error_seq: int = 0
var _last_script_error_text: String = ""


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
	_append(resolved.level, text)
	if error_type == _ERROR_TYPE_SCRIPT:
		_mutex.lock()
		_script_error_seq += 1
		_last_script_error_text = text
		_mutex.unlock()


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


## #490: monotonic count of script-type runtime errors seen this run.
## game_helper snapshots this before eval and compares after to detect a
## runtime error that aborted execute(). Mutex-guarded.
func script_error_seq() -> int:
	_mutex.lock()
	var v := _script_error_seq
	_mutex.unlock()
	return v


## #490: text (with inlined path:line @ function) of the most recent
## script-type runtime error, or "" if none seen this run.
func last_script_error_text() -> String:
	_mutex.lock()
	var v := _last_script_error_text
	_mutex.unlock()
	return v
