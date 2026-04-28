@tool
class_name McpScenePath
extends RefCounted

## Utility for converting between Godot internal node paths and clean
## scene-relative paths like /Main/Camera3D.


## Return a clean path relative to the scene root (e.g. /Main/Camera3D).
static func from_node(node: Node, scene_root: Node) -> String:
	if scene_root == null or node == null:
		return ""
	if node == scene_root:
		return "/" + scene_root.name
	var relative := scene_root.get_path_to(node)
	return "/" + scene_root.name + "/" + str(relative)


## Resolve a clean scene path like "/Main/Camera3D" to the actual node.
##
## Accepts forms relative to the edited scene root:
##   "/Main"          — explicit root prefix (canonical)
##   "/Main/Camera3D" — descendant path
##   "Camera3D"       — bare relative to scene_root
##   "World/Ground"   — nested bare relative to scene_root
##
## Also accepts SceneTree-style "/root/<scene_root_name>[/...]" as an alias for
## the edited scene root. Agents reach for /root/Foo right after creating a
## scene because that's where scenes live at runtime; we honor it so the call
## doesn't fail with a confusing "not found" error. The alias only kicks in
## when the segment after /root matches the scene root's name — paths like
## "/root/@EditorNode@.../Main/..." (returned by Node.get_path() in the editor)
## fall through to the absolute-path fallback unchanged.
static func resolve(scene_path: String, scene_root: Node) -> Node:
	if scene_root == null:
		return null

	## /root/<scene_root_name>[/...] alias: strip the /root prefix and recurse.
	## Match the scene root by name explicitly so we don't capture editor-
	## internal paths that legitimately live under /root.
	var alias_prefix := "/root/" + scene_root.name
	if scene_path == alias_prefix or scene_path.begins_with(alias_prefix + "/"):
		return resolve(scene_path.substr(5), scene_root)  # keep leading slash

	var root_prefix := "/" + scene_root.name
	if scene_path == root_prefix:
		return scene_root
	if scene_path.begins_with(root_prefix + "/"):
		var relative := scene_path.substr(root_prefix.length() + 1)
		return scene_root.get_node_or_null(relative)

	# Try as-is (relative path, or absolute SceneTree path).
	return scene_root.get_node_or_null(scene_path)


## Return the edited scene root, or an error dict if the editor has no open
## scene or the open scene doesn't match `expected_scene_file`.
##
## `expected_scene_file` is the caller's `scene_file` parameter — an empty
## string means "target whatever is currently edited" (current behaviour,
## no guard). A non-empty value must match `scene_file_path` on the current
## edited scene root exactly, or we return EDITED_SCENE_MISMATCH so the
## caller can re-open the right scene.
##
## Shape on success: {"node": <scene_root>}. Shape on error matches
## `McpErrorCodes.make()` so callers can propagate the result directly.
static func require_edited_scene(expected_scene_file: String) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	if not expected_scene_file.is_empty() and root.scene_file_path != expected_scene_file:
		var actual := root.scene_file_path if not root.scene_file_path.is_empty() else "<unsaved>"
		return McpErrorCodes.make(
			McpErrorCodes.EDITED_SCENE_MISMATCH,
			(
				"Expected edited scene \"%s\" but \"%s\" is active. "
				+ "Call scene_open(\"%s\") first, or omit scene_file to target the active scene."
			) % [expected_scene_file, actual, expected_scene_file],
		)
	return {"node": root}


## Format a "parent not found" error that names the path convention.
## Agents routinely try /root/Foo or absolute SceneTree paths; the bare
## "Parent not found: X" gave them no hint that paths are scene-relative.
## Wording is generic ("Paths are relative...") so the helper works for any
## param name (parent_path, new_parent, …).
static func format_parent_error(path: String, scene_root: Node) -> String:
	if scene_root == null:
		return "Parent not found: %s. No edited scene is open." % path
	var root_name := str(scene_root.name)
	return "Parent not found: %s. Paths are relative to the edited scene root (e.g. \"/%s\" or \"\"), not the SceneTree. Scene root is \"/%s\"." % [path, root_name, root_name]


## Format a "node not found" error that names the path convention and, when
## possible, suggests a corrected path. Agents routinely pass /root/Foo
## (runtime SceneTree) or unprefixed names; the bare "Node not found: X"
## gives no hint that paths are edited-scene-relative.
##
## Suggestion logic (highest-confidence first):
##   1. /root/<X>[/...] where <X> is not the scene root → suggest /<sceneRoot>/<X>[/...]
##   2. path doesn't start with "/" → suggest "/<sceneRoot>/<path>"
##   3. otherwise no concrete "did you mean", just the convention reminder.
static func format_node_error(path: String, scene_root: Node) -> String:
	if scene_root == null:
		return "Node not found: %s. No edited scene is open." % path
	var root_name := str(scene_root.name)
	var suggestion := ""

	if path.begins_with("/root/"):
		var after_root := path.substr(6)  # "/root/" is 6 chars
		# Only suggest if the segment after /root/ isn't already the scene root
		# (resolve() handles /root/<sceneRoot>/... as an alias, so a failure
		# with that prefix means a deeper segment is wrong — no clean rewrite).
		var first_seg := after_root.split("/")[0]
		if first_seg != root_name and not first_seg.is_empty():
			suggestion = "/" + root_name + "/" + after_root
	elif not path.begins_with("/") and not path.is_empty():
		suggestion = "/" + root_name + "/" + path

	if suggestion.is_empty():
		return "Node not found: %s. Paths are relative to the edited scene root (e.g. \"/%s/Child\"), not runtime /root/... paths. Scene root is \"/%s\"." % [path, root_name, root_name]
	return "Node not found: %s. Did you mean \"%s\"? Paths are relative to the edited scene root, not runtime /root/... paths. Scene root is \"/%s\"." % [path, suggestion, root_name]
