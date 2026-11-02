@tool
class_name McpNodeValidator
extends RefCounted

## Shared resolve-or-error helper that subsumes the 38+ sites where
## handlers each rolled their own "is the editor ready, does the path
## resolve, otherwise return EDITOR_NOT_READY / NODE_NOT_FOUND" guard.
##
## audit-v2 #20 (issue #364). Uses the audit-v2 #21 (issue #365) error
## vocabulary.

## Local const names alias the preloaded scripts. The naming choice is
## stylistic, not an upgrade-safety boundary: bare `McpErrorCodes.MEMBER`
## and `ErrorCodes.MEMBER` both depend on the Script object Godot has for
## `error_codes.gd`. The transient #398 parse errors were caused by the
## old runner scanning a mixed old/new plugin snapshot and seeing stale
## Script-object content; the runner now writes one v(N+1) snapshot before
## its scan.
const ScenePath := preload("res://addons/godot_ai/utils/scene_path.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")


## Resolve a scene-relative path to the live Node, or return a structured
## error dict.
##
## Success shape: `{"node": Node, "scene_root": Node, "path": String}`.
## Error shape: matches `ErrorCodes.make(...)` so callers can
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
	for_write: bool = false,
) -> Dictionary:
	if node_path.is_empty():
		return ErrorCodes.make(
			ErrorCodes.MISSING_REQUIRED_PARAM,
			"Missing required param: %s" % param_name,
		)
	var scene_check := ScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node
	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return ErrorCodes.make(
			ErrorCodes.NODE_NOT_FOUND,
			ScenePath.format_node_error(node_path, scene_root),
		)
	if for_write:
		var write_error := writable_error(node, scene_root)
		if not write_error.is_empty():
			return write_error
	return {"node": node, "scene_root": scene_root, "path": node_path}


## PackedScene skips a non-editable instance's internal nodes AND their
## subtrees. Check ancestors too, including for locally owned attachments.
static func writable_error(node: Node, scene_root: Node) -> Dictionary:
	if node != scene_root and not scene_root.is_ancestor_of(node):
		return {}
	var current := node
	while current != null and current != scene_root:
		var owner := current.owner
		if owner != null and owner != scene_root and not scene_root.is_editable_instance(owner):
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Cannot edit %s: changes beneath instance %s (%s) would be lost on save. Enable Editable Children explicitly with node_manage(op=\"set_editable_children\") on that instance, or edit its source scene." % [
					ScenePath.from_node(node, scene_root), ScenePath.from_node(owner, scene_root), owner.scene_file_path,
				])
		current = current.get_parent()
	return {}


## When the caller needs the scene root but no specific node yet — e.g.
## handlers that walk children or filter by group. Returns either
## `{"scene_root": Node}` or an `ErrorCodes.make(...)` error dict.
static func require_scene_or_error(scene_file: String = "") -> Dictionary:
	var scene_check := ScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	return {"scene_root": scene_check.node}


## Editable Children permits overrides, not rearranging the source scene.
static func structure_error(node: Node, scene_root: Node) -> Dictionary:
	if node != scene_root and node.owner != null and node.owner != scene_root:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Cannot change the structure of instance-owned node %s. Edit its source scene %s instead; Editable Children only permits overrides and local attachments." % [
				ScenePath.from_node(node, scene_root), node.owner.scene_file_path,
			])
	return {}
