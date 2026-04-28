@tool
class_name LogBacktrace
extends RefCounted

## Helpers for interpreting Godot's `_log_error` virtual arguments.
## (Named `LogBacktrace`, not `ScriptBacktrace`: Godot ships a built-in
## `ScriptBacktrace` class — the type of `script_backtraces[i]` entries
## — so class_name'ing ours the same would collide. Verified against
## the engine's `--doctool` output in 4.6.)
##
## Both `editor_logger.gd` and `game_logger.gd` need to:
##   - Map `error_type` (0=ERROR, 1=WARNING, 2=SCRIPT, 3=SHADER) to a
##     two-bucket "error" / "warn" string so callers can filter without
##     consulting the enum.
##   - Fall back to `code` when `rationale` is empty — single-arg
##     `push_error("msg")` leaves rationale empty and stuffs the user's
##     string into `code`; without the fallback the user message is
##     silently lost. The two-arg form `push_error(code, rationale)`
##     populates both and rationale wins.
##   - Remap the source location to the first frame of `script_backtraces[0]`
##     when present. `push_error` / `push_warning` always report
##     `file=core/variant/variant_utility.cpp`; the actual user GDScript
##     caller is in the backtrace.
##
## Centralising the rules keeps the next push_error semantics shift
## (already happened once between 4.5 and 4.6, see PR #78) a one-place
## fix instead of a two-place hunt.


## Coalesce the per-virtual-arg shape Godot hands `_log_error` into a
## flat record. Always walks `script_backtraces` for the first non-empty
## frame; loggers that need to filter by source path call this first and
## then check the resolved `path` field.
##
## Returns: `{level, message, path, line, function}`
##   - `level`: "error" or "warn" (warn iff `error_type == 1`).
##   - `message`: `rationale` when non-empty, else `code`.
##   - `path` / `line` / `function`: first backtrace frame when one is
##     available; otherwise the original `file` / `line` / `function`.
static func resolve_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	error_type: int,
	script_backtraces: Array,
) -> Dictionary:
	var src_file := file
	var src_line := line
	var src_function := function
	## First non-empty frame wins, not just `script_backtraces[0]` —
	## chained errors can leave the leading entry empty with the actual
	## user frame in `script_backtraces[1]`.
	for bt in script_backtraces:
		if bt != null and bt.get_frame_count() > 0:
			src_file = bt.get_frame_file(0)
			src_line = bt.get_frame_line(0)
			src_function = bt.get_frame_function(0)
			break
	return {
		"level": "warn" if error_type == 1 else "error",
		"message": rationale if not rationale.is_empty() else code,
		"path": src_file,
		"line": src_line,
		"function": src_function,
	}
