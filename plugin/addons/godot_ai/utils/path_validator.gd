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
## Layered checks:
##   1. non-empty
##   2. no embedded null byte (a truncation trap: a C string would stop at
##      the NUL, so the path written could differ from the one validated)
##   3. begins with `res://`
##   4. no `..` substring (cheap, catches every common traversal payload)
##   5. globalize → simplify → verify still under the project root
##      (defence-in-depth against URL-encoded or otherwise sneaky shapes
##      that simplify_path collapses but the substring check might miss)
##   6. for writes only: refuse the project manifest, the `.godot/` editor
##      metadata dir, and `.import` sidecars (issue audit TC-1/GH-3) — these
##      pass every check above but overwriting them corrupts the project or
##      import cache. Reads of these are allowed (inspecting config is fine).


# Cached project root. `ProjectSettings.globalize_path("res://")` is stable
# across the editor's lifetime — caching avoids redundant resolution on every
# call. Matters most for `reimport`, which loops the validator over each path
# in a batch. Lazy-init on first call so static-load timing can't see a
# half-initialised ProjectSettings.
static var _cached_res_root: String = ""


static func _res_root() -> String:
	if _cached_res_root.is_empty():
		_cached_res_root = ProjectSettings.globalize_path("res://").simplify_path()
	return _cached_res_root


## Returns "" when the path is a safe `res://`-rooted reference inside the
## project root. Returns a human-readable error message otherwise; callers
## wrap it with `ErrorCodes.make(INVALID_PARAMS, ...)`.
##
## Pass `for_write = true` for any handler that creates/overwrites the file
## (write_file, create_script, patch_script, ResourceSaver-backed saves,
## scene saves). Write callers additionally refuse the project manifest, the
## `.godot/` metadata dir, and `.import` sidecars. Reads default to
## `for_write = false`, which permits inspecting those files.
static func validate_resource_path(path: String, for_write: bool = false) -> String:
	if path.is_empty():
		return "Missing required param: path"
	if path.contains(String.chr(0)):
		return "Path must not contain null bytes"
	if not path.begins_with("res://"):
		return "Path must start with res://"
	if ".." in path:
		return "Path must not contain '..' (path traversal not allowed)"
	var globalized := ProjectSettings.globalize_path(path).simplify_path()
	var res_root := _res_root()
	# Append a separator so `/proj_evil/...` can't pretend to be inside
	# `/proj` via prefix match. `globalized == res_root` covers `path == "res://"`.
	if globalized != res_root and not globalized.begins_with(res_root + "/"):
		return "Path must resolve under res:// root"
	if for_write:
		var write_err := _reject_sensitive_write(path)
		if not write_err.is_empty():
			return write_err
	return ""


## Refuse writes that would clobber project-critical files. The path is
## already confirmed `res://`-rooted and traversal-free by the caller.
static func _reject_sensitive_write(path: String) -> String:
	if path.get_file() == "project.godot":
		return "Refusing to write res://project.godot (project manifest)"
	if path.ends_with(".import"):
		return "Refusing to write .import sidecar (import cache metadata)"
	# Reject the `.godot/` editor-metadata dir at any depth. Split drops empty
	# segments so a trailing slash can't hide a segment from the check.
	for segment in path.trim_prefix("res://").split("/", false):
		if segment == ".godot":
			return "Refusing to write under res://.godot/ (editor metadata)"
	return ""
