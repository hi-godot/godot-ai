@tool
class_name McpNodeValidator
extends RefCounted

## Shared resolve-or-error helper that subsumes the 38+ sites where
## handlers each rolled their own "is the editor ready, does the path
## resolve, otherwise return EDITOR_NOT_READY / NODE_NOT_FOUND" guard.
##
## audit-v2 #20 (issue #364). Uses the audit-v2 #21 (issue #365) error
## vocabulary.

const McpScenePath = preload("res://addons/godot_ai/utils/scene_path.gd")
const McpErrorCodes = preload("res://addons/godot_ai/utils/error_codes.gd")


## Resolve a scene-relative path to the live Node, or return a structured
## error dict.
##
## Success shape: `{"node": Node, "scene_root": Node, "path": String}`.
## Error shape: matches `McpErrorCodes.make(...)` so callers can
## `return resolved` to propagate.
##
## Errors (in order checked):
##   - `MISSING_REQUIRED_PARAM`: `node_path` is empty
##   - `EDITOR_NOT_READY`: no scene open
##   - `EDITED_SCENE_MISMATCH`: caller pinned `scene_file` and the open
##     scene's path doesn't match
##   - `NODE_NOT_FOUND`: `node_path` doesn't resolve under the scene root
##
## `param_name` is the agent-facing name reported in the
## `MISSING_REQUIRED_PARAM` message — handlers pass "node_path",
## "player_path", "target_path", etc. so the error reads like the
## hand-written messages it replaces.
static func resolve_or_error(
	node_path: String,
	param_name: String = "path",
	scene_file: String = "",
) -> Dictionary:
	if node_path.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.MISSING_REQUIRED_PARAM,
			"Missing required param: %s" % param_name,
		)
	var scene_check := McpScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node
	var node := McpScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(
			McpErrorCodes.NODE_NOT_FOUND,
			McpScenePath.format_node_error(node_path, scene_root),
		)
	return {"node": node, "scene_root": scene_root, "path": node_path}


## When the caller needs the scene root but no specific node yet — e.g.
## handlers that walk children or filter by group. Returns either
## `{"scene_root": Node}` or a `McpErrorCodes.make(...)` error dict.
static func require_scene_or_error(scene_file: String = "") -> Dictionary:
	var scene_check := McpScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	return {"scene_root": scene_check.node}
