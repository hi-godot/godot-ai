@tool
class_name McpPathValidator
extends RefCounted

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
##   2. begins with `res://`
##   3. no `..` substring (cheap, catches every common traversal payload)
##   4. globalize → simplify → verify still under the project root
##      (defence-in-depth against URL-encoded or otherwise sneaky shapes
##      that simplify_path collapses but the substring check might miss)


## Returns "" when the path is a safe `res://`-rooted reference inside the
## project root. Returns a human-readable error message otherwise; callers
## wrap it with `McpErrorCodes.make(INVALID_PARAMS, ...)`.
static func validate_resource_path(path: String) -> String:
	if path.is_empty():
		return "Missing required param: path"
	if not path.begins_with("res://"):
		return "Path must start with res://"
	if ".." in path:
		return "Path must not contain '..' (path traversal not allowed)"
	var globalized := ProjectSettings.globalize_path(path).simplify_path()
	var res_root := ProjectSettings.globalize_path("res://").simplify_path()
	# Append a separator so `/proj_evil/...` can't pretend to be inside
	# `/proj` via prefix match. `globalized == res_root` covers `path == "res://"`.
	if globalized != res_root and not globalized.begins_with(res_root + "/"):
		return "Path must resolve under res:// root"
	return ""
