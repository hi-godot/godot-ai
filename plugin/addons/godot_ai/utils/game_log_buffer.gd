@tool
class_name GameLogBuffer
extends StructuredLogRing

## Ring buffer for game-process log lines (print, push_warning, push_error)
## ferried back from the playing game over the EngineDebugger channel.
##
## Larger cap than EditorLogBuffer because games can be noisy. `run_id`
## rotates each time clear_for_new_run() fires (called on the game's
## mcp:hello boot beacon), giving agents a stable cursor for "lines since
## this play started".
##
## Single-threaded — game_helper.gd drains its logger from `_process` and
## calls `append` from the main thread, so this subclass can use the base
## ring's lockless reads/writes directly.

const MAX_LINES := 2000

var _run_id := ""


func _init() -> void:
	super._init(MAX_LINES)


func append(level: String, text: String) -> void:
	_append_entry({"source": "game", "level": _coerce_level(level), "text": text})


## Rotate the run identifier and drop all buffered entries. Called when the
## game-side autoload sends its mcp:hello beacon, marking a fresh play cycle.
## Returns the new run_id.
func clear_for_new_run() -> String:
	_clear_storage()
	_run_id = _generate_run_id()
	return _run_id


func run_id() -> String:
	return _run_id


static func _generate_run_id() -> String:
	## Opaque to agents — they only check equality. Time-based is plenty
	## unique within a single editor session and avoids the RNG-seed
	## reproducibility footgun.
	return "r%d" % Time.get_ticks_msec()
