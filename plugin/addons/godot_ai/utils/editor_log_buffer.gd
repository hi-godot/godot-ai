@tool
class_name EditorLogBuffer
extends RefCounted

## Ring buffer for editor-process script errors and warnings (parse errors,
## @tool runtime errors, EditorPlugin errors, push_error/push_warning) captured
## by editor_logger.gd's Logger subclass.
##
## Smaller cap than GameLogBuffer (500 vs 2000) — the editor only emits errors,
## not the full println firehose a game can produce. No run_id rotation: editor
## errors persist across project_run cycles (they're about *editing* state, not
## about the playing game).
##
## Implemented as a head-indexed circular buffer like GameLogBuffer. Unlike that
## buffer, EditorLogBuffer is mutex-protected because Logger virtuals can fire
## from any thread (e.g. async script-loader threads emitting parse errors), and
## the buffer is read on the main thread by EditorHandler.get_logs.
##
## Entry shape: {source: "editor", level: "error"|"warn",
##   text, path, line, function} — `path/line/function` may be empty/zero when
## the source location wasn't recoverable (e.g. printerr from a thread without
## a script context).

const MAX_LINES := 500
const VALID_LEVELS := ["info", "warn", "error"]

var _storage: Array[Dictionary] = []
## Next write position within `_storage`. While filling (before first
## wrap) equals `_storage.size()`; once full, points at the oldest entry
## (the one about to be overwritten).
var _head := 0
var _dropped_count := 0
var _mutex := Mutex.new()


func append(level: String, text: String, path: String = "", line: int = 0, function: String = "") -> void:
	## Coerce unknown levels to "info" so a misbehaving sender can't poison
	## downstream filters with arbitrary strings.
	var safe_level := level if level in VALID_LEVELS else "info"
	var entry := {
		"source": "editor",
		"level": safe_level,
		"text": text,
		"path": path,
		"line": line,
		"function": function,
	}
	_mutex.lock()
	if _storage.size() < MAX_LINES:
		_storage.append(entry)
		_head = _storage.size() % MAX_LINES
	else:
		## Full — overwrite oldest in place, advance head, count the drop.
		_storage[_head] = entry
		_head = (_head + 1) % MAX_LINES
		_dropped_count += 1
	_mutex.unlock()


func get_range(offset: int, count: int) -> Array[Dictionary]:
	_mutex.lock()
	var out := _get_range_locked(offset, count)
	_mutex.unlock()
	return out


func get_recent(count: int) -> Array[Dictionary]:
	## Single-lock so the size we compute `start` from can't race against
	## a concurrent append between the size read and the slice copy.
	_mutex.lock()
	var size := _storage.size()
	var start := maxi(0, size - count)
	var out := _get_range_locked(start, size - start)
	_mutex.unlock()
	return out


func total_count() -> int:
	_mutex.lock()
	var n := _storage.size()
	_mutex.unlock()
	return n


func dropped_count() -> int:
	_mutex.lock()
	var n := _dropped_count
	_mutex.unlock()
	return n


func clear() -> int:
	_mutex.lock()
	var n := _storage.size()
	_storage.clear()
	_head = 0
	_dropped_count = 0
	_mutex.unlock()
	return n


## Caller must hold `_mutex`.
func _get_range_locked(offset: int, count: int) -> Array[Dictionary]:
	var size := _storage.size()
	var start := maxi(0, offset)
	var stop := mini(size, start + count)
	var out: Array[Dictionary] = []
	for i in range(start, stop):
		out.append(_storage[_logical_to_physical(i)])
	return out


## Translate a logical index (0 = oldest retained) to a physical
## `_storage` slot. Before the first wrap, storage-order is
## logical-order. After wrapping, the oldest entry lives at `_head`.
##
## Caller must hold `_mutex`.
func _logical_to_physical(logical: int) -> int:
	if _storage.size() < MAX_LINES:
		return logical
	return (_head + logical) % MAX_LINES
