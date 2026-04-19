@tool
class_name GameLogBuffer
extends RefCounted

## Ring buffer for game-process log lines (print, push_warning, push_error)
## ferried back from the playing game over the EngineDebugger channel.
##
## Larger cap than McpLogBuffer because games can be noisy. Each entry is a
## structured dict so callers can filter by level. `run_id` rotates each time
## clear_for_new_run() fires (called on the game's mcp:hello boot beacon),
## giving agents a stable cursor for "lines since this play started".
##
## Implemented as a head-indexed circular buffer: `_storage` stays at most
## MAX_LINES long, and once full, new appends overwrite the oldest slot at
## `_head`. This keeps append O(1) on overflow — the previous `slice()`
## approach reallocated the full retained array on every drop, which a very
## chatty game would pay for thousands of times per second.

const MAX_LINES := 2000
const VALID_LEVELS := ["info", "warn", "error"]

var _storage: Array[Dictionary] = []
## Next write position within `_storage`. While filling (before first
## wrap) equals `_storage.size()`; once full, points at the oldest entry
## (the one about to be overwritten).
var _head := 0
var _run_id := ""
var _dropped_count := 0


func append(level: String, text: String) -> void:
	## Coerce unknown levels to "info" so a misbehaving sender can't poison
	## downstream filters with arbitrary strings.
	var safe_level := level if level in VALID_LEVELS else "info"
	var entry := {"source": "game", "level": safe_level, "text": text}
	if _storage.size() < MAX_LINES:
		_storage.append(entry)
		_head = _storage.size() % MAX_LINES
		return
	## Full — overwrite oldest in place, advance head, count the drop.
	_storage[_head] = entry
	_head = (_head + 1) % MAX_LINES
	_dropped_count += 1


func get_range(offset: int, count: int) -> Array[Dictionary]:
	var size := _storage.size()
	var start := maxi(0, offset)
	var stop := mini(size, start + count)
	var out: Array[Dictionary] = []
	for i in range(start, stop):
		out.append(_storage[_logical_to_physical(i)])
	return out


func get_recent(count: int) -> Array[Dictionary]:
	var size := _storage.size()
	var start := maxi(0, size - count)
	return get_range(start, size - start)


## Rotate the run identifier and drop all buffered entries. Called when the
## game-side autoload sends its mcp:hello beacon, marking a fresh play cycle.
## Returns the new run_id.
func clear_for_new_run() -> String:
	_storage.clear()
	_head = 0
	_dropped_count = 0
	_run_id = _generate_run_id()
	return _run_id


func total_count() -> int:
	return _storage.size()


func run_id() -> String:
	return _run_id


func dropped_count() -> int:
	return _dropped_count


## Translate a logical index (0 = oldest retained) to a physical
## `_storage` slot. Before the first wrap, storage-order is
## logical-order. After wrapping, the oldest entry lives at `_head`.
func _logical_to_physical(logical: int) -> int:
	if _storage.size() < MAX_LINES:
		return logical
	return (_head + logical) % MAX_LINES


static func _generate_run_id() -> String:
	## Opaque to agents — they only check equality. Time-based is plenty
	## unique within a single editor session and avoids the RNG-seed
	## reproducibility footgun.
	return "r%d" % Time.get_ticks_msec()
