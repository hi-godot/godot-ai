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


## True when `path` carries a codepoint that must never reach a filesystem API.
##
## Issue #889: the previous guard built its sentinel with `String.chr(0)`, and
## Godot emits `Unicode parsing error … Unexpected NUL character` while
## *constructing* that string. Every validated call — including reads that then
## failed with "File not found" — printed an alarming engine error that had
## nothing to do with the caller's path. Reading codepoints instead never
## materialises a NUL String, so the noise is gone.
##
## Both codepoints are rejected, for different reasons:
##   * `0x0000` — a real embedded NUL can truncate a C string, so the path that
##     is validated is not the path that gets opened. Current Godot cannot
##     retain one in a String, making this a no-op today; it stays as
##     defense-in-depth for any build or input path that can.
##   * `0xFFFD` — what current Godot actually substitutes for a NUL or any other
##     undecodable input. Once the engine has replaced the byte there is no way
##     left to tell an attempted NUL from malformed UTF-8 from a literal
##     replacement character, so the only safe reading at a security boundary is
##     to refuse all three. A legitimate filename containing U+FFFD is rejected
##     too; that false positive is deliberate and vanishingly rare.
static func _contains_invalid_path_codepoint(path: String) -> bool:
	for i in path.length():
		var codepoint := path.unicode_at(i)
		if codepoint == 0x0000 or codepoint == 0xFFFD:
			return true
	return false


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
	if _contains_invalid_path_codepoint(path):
		return "Path must not contain null bytes or invalid Unicode"
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
	if _contains_invalid_path_codepoint(path):
		return "Path must not contain null bytes or invalid Unicode"
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
	# Normalize once, then reuse for filename and segment checks. The writer
	# (`FileAccess::fix_path` / `FileAccessWindows`) folds `\`, `//`, and `.`
	# the same way, so `res://project.godot/.` and `res://override.cfg/.` must
	# not slip past `get_file()` as a trailing `.` while still opening the
	# protected file.
	#
	#   - `res://.godot\uid_cache.bin` used to collapse to one fused segment
	#     and match neither this check nor the loaded-plugin one below, while the
	#     write itself still landed in `.godot/`.
	#   - a `.` segment shifts the *anchored* plugin-tree check below, so
	#     `res://./addons/godot_ai/plugin.gd` slipped past it even once the
	#     separators were normalized.
	#
	# `..` never reaches here -- `_confine_under` refuses it first -- so its
	# folding is inert. Because the engine normalizes backslashes on Linux too,
	# a POSIX file literally named `addons\godot_ai\x.gd` is not addressable
	# through `res://` at all, so normalizing costs no legitimate write.
	var normalized := path.replace("\\", "/").simplify_path()
	# Windows opens one file under several spellings: `name::$DATA` (any
	# `:stream`) is the file's own data stream, `PROJEC~1.GOD` its 8.3 short
	# name, and a trailing dot or space is stripped. Each reached
	# project.godot, override.cfg or `.godot/` under a name the checks below
	# do not recognise, so writes refuse those spellings outright. None is a
	# portable filename (Windows forbids `:` in names), so no legitimate write
	# is lost.
	var alias_err := _reject_windows_alias(normalized.trim_prefix("res://"))
	if not alias_err.is_empty():
		return alias_err
	var file_lower := normalized.get_file().to_lower()
	if file_lower == "project.godot":
		return "Refusing to write res://project.godot (project manifest)"
	if file_lower == "override.cfg":
		return "Refusing to write res://override.cfg (startup config override)"
	# Reject the `.godot/` editor-metadata dir at any depth. Split drops empty
	# segments so a trailing slash can't hide a segment from the check.
	var segments := normalized.trim_prefix("res://").split("/", false)
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


## 8.3 short-name shape: up to six characters, `~`, a number, then an optional
## extension of up to three (`PROJEC~1.GOD`, `GODOT~1`, `GODOT_~1`).
static var _short_name_regex: RegEx


static func _reject_windows_alias(relative: String) -> String:
	if _short_name_regex == null:
		_short_name_regex = RegEx.create_from_string("^[^.~]{0,6}~[0-9]+(\\.[^.]{0,3})?$")
	for segment in relative.split("/", false):
		if ":" in segment:
			return "Refusing to write a path containing ':' (Windows stream syntax): %s" % segment
		if segment.ends_with(".") or segment.ends_with(" "):
			return "Refusing to write a path segment ending in '.' or ' ' (Windows strips it): %s" % segment
		if _short_name_regex.search(segment) != null:
			return "Refusing to write an 8.3 short-name path segment (Windows alias): %s" % segment
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
