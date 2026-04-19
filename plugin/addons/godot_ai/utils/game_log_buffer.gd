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

const MAX_LINES := 2000
const VALID_LEVELS := ["info", "warn", "error"]

var _entries: Array[Dictionary] = []
var _run_id := ""
var _dropped_count := 0


func append(level: String, text: String) -> void:
	## Coerce unknown levels to "info" so a misbehaving sender can't poison
	## downstream filters with arbitrary strings.
	var safe_level := level if level in VALID_LEVELS else "info"
	_entries.append({"source": "game", "level": safe_level, "text": text})
	if _entries.size() > MAX_LINES:
		var overflow := _entries.size() - MAX_LINES
		_entries = _entries.slice(overflow)
		_dropped_count += overflow


func get_range(offset: int, count: int) -> Array[Dictionary]:
	var start := maxi(0, offset)
	var stop := mini(_entries.size(), start + count)
	var out: Array[Dictionary] = []
	for i in range(start, stop):
		out.append(_entries[i])
	return out


func get_recent(count: int) -> Array[Dictionary]:
	var start := maxi(0, _entries.size() - count)
	var out: Array[Dictionary] = []
	for i in range(start, _entries.size()):
		out.append(_entries[i])
	return out


## Rotate the run identifier and drop all buffered entries. Called when the
## game-side autoload sends its mcp:hello beacon, marking a fresh play cycle.
## Returns the new run_id.
func clear_for_new_run() -> String:
	_entries.clear()
	_dropped_count = 0
	_run_id = _generate_run_id()
	return _run_id


func total_count() -> int:
	return _entries.size()


func run_id() -> String:
	return _run_id


func dropped_count() -> int:
	return _dropped_count


static func _generate_run_id() -> String:
	## Opaque to agents — they only check equality. Time-based is plenty
	## unique within a single editor session and avoids the RNG-seed
	## reproducibility footgun.
	return "r%d" % Time.get_ticks_msec()
