@tool
class_name McpGameLogBuffer
extends McpStructuredLogRing

## Ring buffer for game-process log lines (print, push_warning, push_error)
## ferried back from the playing game over the EngineDebugger channel.
##
## Larger cap than McpEditorLogBuffer because games can be noisy. `run_id`
## rotates at play-start, giving agents a stable cursor for "lines from
## this run" even when the game never reaches the mcp:hello boot beacon.
##
## Single-threaded — game_helper.gd drains its logger from `_process` and
## calls `append` from the main thread, so this subclass can use the base
## ring's lockless reads/writes directly.

const MAX_LINES := 2000

var _run_id := ""
var _run_seq := 0
var _error_warn_total := 0
var _error_total := 0


func _init() -> void:
	super._init(MAX_LINES)


func append(level: String, text: String, details: Dictionary = {}) -> void:
	var coerced_level := _coerce_level(level)
	var entry := {
		"source": "game",
		"level": coerced_level,
		"text": text,
		"run_id": _run_id,
	}
	if not details.is_empty():
		entry["details"] = details.duplicate(true)
	_append_entry(entry)
	if coerced_level in ["warn", "error"]:
		_error_warn_total += 1
	if coerced_level == "error":
		_error_total += 1


## Rotate the run identifier without dropping buffered entries. Called at
## play-start so even no-hello parse failures get a fresh current-run identity.
## Historical lines stay tagged with their original run_id and can still be
## queried explicitly.
func clear_for_new_run() -> String:
	_run_id = _generate_run_id()
	_error_warn_total = 0
	_error_total = 0
	return _run_id


func run_id() -> String:
	return _run_id


func error_warn_total() -> int:
	return _error_warn_total


func error_total() -> int:
	return _error_total


func get_run_range(run_id: String, offset: int, count: int) -> Array[Dictionary]:
	return get_run_page(run_id, offset, count).entries


func run_total_count(run_id: String) -> int:
	return int(get_run_page(run_id, 0, 0).total_count)


func get_run_page(run_id: String, offset: int, count: int) -> Dictionary:
	var entries := _entries_for_run(run_id)
	var start := mini(maxi(0, offset), entries.size())
	var stop := mini(entries.size(), start + maxi(0, count))
	var out: Array[Dictionary] = []
	for i in range(start, stop):
		out.append(entries[i])
	return {
		"entries": out,
		"total_count": entries.size(),
	}


func _entries_for_run(run_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in get_range(0, total_count()):
		if str(entry.get("run_id", "")) == run_id:
			out.append(entry)
	return out


func _generate_run_id() -> String:
	## Opaque to agents — they only check equality. Time-based is plenty
	## unique within a single editor session; the local sequence protects
	## fast back-to-back test runs within the same millisecond.
	_run_seq += 1
	return "r%d-%d" % [Time.get_ticks_msec(), _run_seq]
