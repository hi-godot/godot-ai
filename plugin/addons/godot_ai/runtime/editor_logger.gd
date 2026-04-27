@tool
extends Logger

## Editor-process Logger subclass.
##
## NOTE: deliberately no `class_name` — `extends Logger` requires the Logger
## class which Godot only exposes from 4.5+. plugin.gd loads this script
## dynamically via load() after gating on
## ClassDB.class_exists("Logger"), so the script never gets parsed on
## older engines. Registered via OS.add_logger() from plugin.gd::_enter_tree
## so we can intercept editor-process script errors — parse errors, @tool
## runtime errors, EditorPlugin errors, push_error/push_warning — and
## surface them via `logs_read(source="editor")`. Without this, the LLM
## sees nothing in `logs_read` while the same errors show in red lines in
## Godot's Output panel.
##
## Why only `_log_error` and not `_log_message`:
## `_log_message(msg, error)` covers print() and printerr(), which is the
## firehose path — running editors print thousands of internal info lines
## a session. The issue (#231) explicitly asks to filter so the buffer
## isn't drowned. Errors and warnings flow through `_log_error` (parse
## errors, push_error/push_warning, runtime errors), which is what
## debugging callers actually need. If we discover @tool printerr() is a
## valuable source later, _log_message can be added behind the same filter.
##
## Logger virtuals can be called from any thread (e.g. async script
## loaders push parse errors off the main thread). EditorLogBuffer is
## mutex-protected so we can append directly without an intermediate queue.

const ADDON_PATH_MARKER := "/addons/godot_ai/"

## EditorLogBuffer — untyped because this script is loaded dynamically and
## EditorLogBuffer's class_name isn't yet registered on the parser at the
## time `extends Logger` resolves. Constructor-injected so the hot path
## doesn't need a per-call null check.
var _buffer


func _init(buffer = null) -> void:
	_buffer = buffer


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
	## error_type: 0 = ERROR (push_error / runtime), 1 = WARNING (push_warning),
	## 2 = SCRIPT (parse / script-load errors), 3 = SHADER. Map warnings to
	## "warn" and the rest to "error" so callers can filter without consulting
	## the enum.
	##
	## Cheap-reject ordering: this function is called for every editor-process
	## error and warning, including the firehose of internal Godot C++ chatter
	## that we drop. Filter on `file` first, only consult `script_backtraces`
	## for the push_error/push_warning case (file=variant_utility.cpp) where
	## the real source is buried in the backtrace.
	if _buffer == null:
		return

	var src_file := file
	var src_line := line
	var src_function := function

	## push_error/push_warning land here with file pointing at Godot's
	## variant_utility.cpp; the actual user GDScript caller is the first
	## script_backtrace frame. Anywhere else, the cheap reject below
	## decides — no backtrace walk needed.
	if not _is_user_script(src_file) and not script_backtraces.is_empty():
		var bt = script_backtraces[0]
		if bt != null and bt.get_frame_count() > 0:
			src_file = bt.get_frame_file(0)
			src_line = bt.get_frame_line(0)
			src_function = bt.get_frame_function(0)

	if not _is_user_script(src_file):
		return
	if _is_in_godot_ai_addon(src_file):
		return

	## Single-arg push_error("msg") / push_warning("msg") stores the user's
	## string in `code` and leaves `rationale` empty; the two-arg form
	## push_error(code, rationale) populates both. Fall back to `code` when
	## `rationale` is missing — otherwise the user's message is silently lost.
	var level := "warn" if error_type == 1 else "error"
	var message := rationale if not rationale.is_empty() else code
	_buffer.append(level, message, src_file, src_line, src_function)


## Predicate broken out so tests can drive the path-filter logic without
## constructing real Logger calls.
static func _is_user_script(path: String) -> bool:
	if path.is_empty():
		return false
	## Match .gd / .cs (case-insensitively to handle .GD on case-insensitive
	## filesystems). C# scripts compile elsewhere but the parser path can
	## still surface .cs files for assembly load failures.
	var lower := path.to_lower()
	return lower.ends_with(".gd") or lower.ends_with(".cs")


## Path-substring check works for both `res://addons/godot_ai/foo.gd` and
## globalized absolute paths (`/Users/.../addons/godot_ai/foo.gd`) that
## Godot can also report depending on where the error originated.
static func _is_in_godot_ai_addon(path: String) -> bool:
	if path.begins_with("res://addons/godot_ai/"):
		return true
	return path.find(ADDON_PATH_MARKER) >= 0
