@tool
class_name ScenePath
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
