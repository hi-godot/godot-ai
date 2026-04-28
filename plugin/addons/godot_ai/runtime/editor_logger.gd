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
## loaders push parse errors off the main thread). McpEditorLogBuffer is
## mutex-protected so we can append directly without an intermediate queue.

const ADDON_PATH_MARKER := "/addons/godot_ai/"

## McpEditorLogBuffer — untyped because this script is loaded dynamically and
## McpEditorLogBuffer's class_name isn't yet registered on the parser at the
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
	if _buffer == null:
		return
	## Cheap reject for the firehose: when `file` is already non-user (the
	## bulk of editor-internal C++ chatter) and there's no backtrace to
	## remap from, the resolved path can only stay non-user — drop without
	## paying for resolve_error's call frame + dict allocation.
	if not _is_user_script(file) and script_backtraces.is_empty():
		return
	var resolved := McpLogBacktrace.resolve_error(
		function, file, line, code, rationale, error_type, script_backtraces,
	)
	if not _is_user_script(resolved.path):
		return
	if _is_in_godot_ai_addon(resolved.path):
		return
	_buffer.append(resolved.level, resolved.message, resolved.path, resolved.line, resolved.function)


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
