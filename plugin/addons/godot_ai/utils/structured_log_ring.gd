@tool
class_name McpStructuredLogRing
extends RefCounted

## Head-indexed circular buffer of structured log entries shared by
## game_log_buffer and editor_log_buffer.
##
## Once `_max_lines` (set in subclass `_init`) is reached, new appends
## overwrite the oldest slot at `_head`, keeping append O(1) on overflow
## — the previous slice() approach reallocated the full retained array
## on every drop, which a chatty game would pay for thousands of times
## per second.
##
## Lockless. Subclasses needing thread-safety (editor_log_buffer is
## written from any thread a Godot Logger virtual can fire on) wrap each
## public method with their own Mutex around the `_*_unlocked` helpers.
## Keeping the base lockless means the hot game-side path (single thread,
## called from _process) doesn't pay an unused mutex cost.
##
## Entry shape is owned by subclasses — `_append_entry` takes a
## ready-built Dictionary so each buffer can carry the fields it needs
## (game: `source/level/text`; editor: adds `path/line/function`).

const VALID_LEVELS := ["info", "warn", "error"]

var _max_lines: int
var _storage: Array[Dictionary] = []
## Next write position within `_storage`. While filling (before first
## wrap) equals `_storage.size()`; once full, points at the oldest entry
## (the one about to be overwritten).
var _head := 0
var _dropped_count := 0


func _init(max_lines: int) -> void:
	_max_lines = max_lines


## Append `entry` to the ring, evicting the oldest slot when full.
## Subclasses build the dict with their per-source shape and pass it in.
func _append_entry(entry: Dictionary) -> void:
	if _storage.size() < _max_lines:
		_storage.append(entry)
		_head = _storage.size() % _max_lines
		return
	## Full — overwrite oldest in place, advance head, count the drop.
	_storage[_head] = entry
	_head = (_head + 1) % _max_lines
	_dropped_count += 1


## Lockless slice. Subclasses with a mutex wrap their `get_range` /
## `get_recent` overrides around this; the lockless base implementations
## of those public methods just delegate here.
func _get_range_unlocked(offset: int, count: int) -> Array[Dictionary]:
	var size := _storage.size()
	var start := maxi(0, offset)
	var stop := mini(size, start + count)
	var out: Array[Dictionary] = []
	for i in range(start, stop):
		out.append(_storage[_logical_to_physical(i)])
	return out


func get_range(offset: int, count: int) -> Array[Dictionary]:
	return _get_range_unlocked(offset, count)


func get_recent(count: int) -> Array[Dictionary]:
	var size := _storage.size()
	var start := maxi(0, size - count)
	return _get_range_unlocked(start, size - start)


## Lockless accessors. Subclasses with a mutex use these under their lock
## so the field reads stay encapsulated in the base instead of leaking
## `_storage` / `_dropped_count` reach-through into the subclass.
func _total_count_unlocked() -> int:
	return _storage.size()


func _dropped_count_unlocked() -> int:
	return _dropped_count


func total_count() -> int:
	return _total_count_unlocked()


func dropped_count() -> int:
	return _dropped_count_unlocked()


## Translate a logical index (0 = oldest retained) to a physical
## `_storage` slot. Before the first wrap, storage-order is logical-
## order. After wrapping, the oldest entry lives at `_head`.
func _logical_to_physical(logical: int) -> int:
	if _storage.size() < _max_lines:
		return logical
	return (_head + logical) % _max_lines


## Reset the ring to empty. Subclasses with a mutex wrap this with their
## lock; subclasses that surface `clear` to callers (McpEditorLogBuffer)
## return the prior size from their wrapper.
func _clear_storage() -> void:
	_storage.clear()
	_head = 0
	_dropped_count = 0


## Coerce unknown levels to "info" so a misbehaving sender can't poison
## downstream filters with arbitrary strings.
static func _coerce_level(level: String) -> String:
	return level if level in VALID_LEVELS else "info"
