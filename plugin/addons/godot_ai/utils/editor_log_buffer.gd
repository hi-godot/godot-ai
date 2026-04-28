@tool
class_name EditorLogBuffer
extends StructuredLogRing

## Ring buffer for editor-process script errors and warnings (parse errors,
## @tool runtime errors, EditorPlugin errors, push_error/push_warning) captured
## by editor_logger.gd's Logger subclass.
##
## Smaller cap than GameLogBuffer (500 vs 2000) — the editor only emits errors,
## not the full println firehose a game can produce. No run_id rotation: editor
## errors persist across project_run cycles (they're about *editing* state, not
## about the playing game).
##
## Mutex-protected because Logger virtuals can fire from any thread (e.g.
## async script-loader threads emitting parse errors), and the buffer is
## read on the main thread by EditorHandler.get_logs. Each public method
## wraps the base ring's lockless helpers in `_mutex.lock()/unlock()` —
## the base stays lockless so GameLogBuffer's hot path doesn't pay an
## unused mutex cost.
##
## Entry shape: {source: "editor", level: "info"|"warn"|"error",
##   text, path, line, function} — `path/line/function` may be empty/zero
## when the source location wasn't recoverable (e.g. printerr from a
## thread without a script context).

const MAX_LINES := 500

var _mutex := Mutex.new()


func _init() -> void:
	super._init(MAX_LINES)


func append(level: String, text: String, path: String = "", line: int = 0, function: String = "") -> void:
	var entry := {
		"source": "editor",
		"level": _coerce_level(level),
		"text": text,
		"path": path,
		"line": line,
		"function": function,
	}
	_mutex.lock()
	_append_entry(entry)
	_mutex.unlock()


func get_range(offset: int, count: int) -> Array[Dictionary]:
	_mutex.lock()
	var out := _get_range_unlocked(offset, count)
	_mutex.unlock()
	return out


func get_recent(count: int) -> Array[Dictionary]:
	## Single-lock so the size we compute `start` from can't race against
	## a concurrent append between the size read and the slice copy.
	_mutex.lock()
	var size := _total_count_unlocked()
	var start := maxi(0, size - count)
	var out := _get_range_unlocked(start, size - start)
	_mutex.unlock()
	return out


func total_count() -> int:
	_mutex.lock()
	var n := _total_count_unlocked()
	_mutex.unlock()
	return n


func dropped_count() -> int:
	_mutex.lock()
	var n := _dropped_count_unlocked()
	_mutex.unlock()
	return n


func clear() -> int:
	_mutex.lock()
	var n := _total_count_unlocked()
	_clear_storage()
	_mutex.unlock()
	return n
