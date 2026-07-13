@tool
class_name McpPathValidator
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Validates `res://`-rooted paths against directory-traversal escape.
##
## Issue #347 (audit-v2 #3): handlers were accepting `res://../etc/passwd.gd`
## because the only check was `path.begins_with("res://")`. LLM-driven path
## generation (prompt injection, agent typos, untrusted issue/PR text in
## context) can produce traversal payloads for the write tools that produce
## arbitrary disk content (`script_create`, `filesystem_write_text`,
## `patch_script`) and for the matching reads (info disclosure surface).
##
## Two entry points:
##   * `validate_resource_path` — for paths that name a `res://` disk file the
##     plugin will read or (with `for_write`) write. This is the strict one.
##   * `validate_loadable_path` — for paths handed to `ResourceLoader`, which
##     also accepts `uid://` (an opaque resource-DB id that cannot express
##     traversal) and `user://` (the per-project user data sandbox). Load
##     handlers must use this so `uid://` references copied out of `.tscn`
##     ExtResource / `.uid` sidecars and `user://` runtime assets keep loading.
##
## Error wrapping: callers should use `path_error` / `loadable_error`, which
## return a ready `ErrorCodes.make(VALUE_OUT_OF_RANGE, …)` dict (or null). A
## bad path is a value-domain error, and funneling every site through one
## wrapper keeps the error code consistent across all handlers.
##
## Known limitation: containment is lexical (`globalize_path` + `simplify_path`
## prefix match). It does NOT resolve symlinks — GDScript exposes no realpath.
## A symlink *inside* the project that points outside it can therefore defeat
## the under-root check. This matches the engine's own `res://` resolution and
## is accepted; the loopback trust boundary is the primary control.


# Cached project / user roots. `globalize_path` is stable across the editor's
# lifetime — caching avoids redundant resolution on every call. Matters most
# for `reimport`, which loops the validator over each path in a batch.
# Lazy-init on first call so static-load timing can't see a half-initialised
# ProjectSettings.
static var _cached_res_root: String = ""
static var _cached_user_root: String = ""


static func _res_root() -> String:
	if _cached_res_root.is_empty():
		_cached_res_root = ProjectSettings.globalize_path("res://").simplify_path()
	return _cached_res_root


static func _user_root() -> String:
	if _cached_user_root.is_empty():
		_cached_user_root = ProjectSettings.globalize_path("user://").simplify_path()
	return _cached_user_root


## Returns "" when the path is a safe `res://`-rooted reference inside the
## project root. Returns a human-readable error message otherwise.
## Prefer `path_error` over calling this directly — it wraps the message in the
## canonical error code.
##
## Pass `for_write = true` for any handler that creates/overwrites the file
## (write_file, create_script, patch_script, ResourceSaver-backed saves,
## scene saves). Write callers additionally refuse the project manifest and
## startup override, plus the `.godot/` metadata dir. Reads default to
## `for_write = false`, which permits inspecting those files.
static func validate_resource_path(path: String, for_write: bool = false) -> String:
	if path.is_empty():
		return "Missing required param: path"
	## Guard the sentinel: on builds where String.chr(0) yields "" (some engines
	## normalize embedded nulls away, e.g. 4.3), contains("") would be true and
	## reject every path. A String that can't hold a null can't smuggle one.
	var nul := String.chr(0)
	if not nul.is_empty() and path.contains(nul):
		return "Path must not contain null bytes"
	if not path.begins_with("res://"):
		return "Path must start with res://"
	var confine_err := _confine_under(path, _res_root(), "res://")
	if not confine_err.is_empty():
		return confine_err
	if for_write:
		return _reject_sensitive_write(path)
	return ""


## Returns "" when `path` is safe to hand to `ResourceLoader.load` / `.exists`.
## Accepts, in addition to confined `res://` paths:
##   * `uid://<id>` — an opaque 64-bit resource id; it cannot express a path
##     and the engine only ever resolves it to a resource already in the
##     project, so there is nothing to confine.
##   * `user://…` — the per-project user data dir, confined under its root the
##     same way `res://` is (so `user://../…` can't escape the sandbox).
static func validate_loadable_path(path: String) -> String:
	if path.is_empty():
		return "Missing required param: path"
	## Guard the sentinel: on builds where String.chr(0) yields "" (some engines
	## normalize embedded nulls away, e.g. 4.3), contains("") would be true and
	## reject every path. A String that can't hold a null can't smuggle one.
	var nul := String.chr(0)
	if not nul.is_empty() and path.contains(nul):
		return "Path must not contain null bytes"
	if path.begins_with("uid://"):
		return ""
	if path.begins_with("user://"):
		return _confine_under(path, _user_root(), "user://")
	if path.begins_with("res://"):
		return _confine_under(path, _res_root(), "res://")
	return "Path must start with res://, uid://, or user://"


## Shared traversal + under-root containment. `root` must already be simplified.
static func _confine_under(path: String, root: String, label: String) -> String:
	if ".." in path:
		return "Path must not contain '..' (path traversal not allowed)"
	var globalized := ProjectSettings.globalize_path(path).simplify_path()
	# Append a separator so `/proj_evil/...` can't pretend to be inside `/proj`
	# via prefix match. `globalized == root` covers the bare `res://` / `user://`.
	if globalized != root and not globalized.begins_with(root + "/"):
		return "Path must resolve under %s root" % label
	return ""


## Refuse writes that would clobber project-critical files. The path is already
## confirmed `res://`-rooted and traversal-free by the caller.
##
## Comparisons are case-folded: macOS (APFS) and Windows (NTFS) are
## case-insensitive by default, so `res://Project.godot` resolves to the real
## `project.godot` and must be refused too.
##
## `.import` sidecars are deliberately NOT blocked — editing an asset's import
## options then re-importing is a legitimate, recoverable workflow (the file is
## source-controlled). The blocked set is the startup-execution surface only:
## the manifest, its `override.cfg` shadow, and the `.godot/` cache dir.
static func _reject_sensitive_write(path: String) -> String:
	var file_lower := path.get_file().to_lower()
	if file_lower == "project.godot":
		return "Refusing to write res://project.godot (project manifest)"
	if file_lower == "override.cfg":
		return "Refusing to write res://override.cfg (startup config override)"
	# Reject the `.godot/` editor-metadata dir at any depth. Split drops empty
	# segments so a trailing slash can't hide a segment from the check.
	var segments := path.trim_prefix("res://").split("/", false)
	for segment in segments:
		if segment.to_lower() == ".godot":
			return "Refusing to write under res://.godot/ (editor metadata)"
	# Reject the currently-loaded plugin's own script tree. Overwriting a
	# loaded .gd here (plus the immediate reimport triggered by update_file())
	# can SIGABRT the editor mid-call, or silently corrupt the installed
	# plugin so the next enable fails to resolve scripts.
	if segments.size() >= 2 and segments[0].to_lower() == "addons" and segments[1].to_lower() == "godot_ai":
		return "Refusing to write under res://addons/godot_ai/ (overwriting a loaded plugin script can crash the editor)"
	return ""


## Validate a write/read `res://` path and return a ready error dict, or null
## when the path is fine. The single wrapper every handler should use so the
## error code (VALUE_OUT_OF_RANGE — a bad path is a value-domain error) stays
## consistent. `param_name` is prefixed onto the message for context.
static func path_error(path: String, param_name: String = "path", for_write: bool = false) -> Variant:
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % param_name)
	var err := validate_resource_path(path, for_write)
	if err.is_empty():
		return null
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s: %s" % [param_name, err])


## Same as `path_error` but for paths handed to `ResourceLoader` (allows
## `uid://` / `user://`). Returns a ready error dict or null. An empty path is
## reported as MISSING_REQUIRED_PARAM rather than a value error.
static func loadable_error(path: String, param_name: String = "path") -> Variant:
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % param_name)
	var err := validate_loadable_path(path)
	if err.is_empty():
		return null
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s: %s" % [param_name, err])
