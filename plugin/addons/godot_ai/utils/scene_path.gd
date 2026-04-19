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
## Accepts three forms, all relative to the edited scene root:
##   "/Main"          — explicit root prefix (canonical)
##   "/Main/Camera3D" — descendant path
##   "Main/Camera3D"  — bare relative
##
## Also accepts SceneTree-style "/root/<root_name>[/...]" as an alias for the
## edited scene root. Agents reach for /root/Foo right after creating a scene
## because that's where scenes live at runtime under SceneTree; we honor it
## so the call doesn't fail with a confusing "not found" error.
static func resolve(scene_path: String, scene_root: Node) -> Node:
	if scene_root == null:
		return null

	## SceneTree-style /root/<name> alias: strip the /root prefix and recurse.
	if scene_path == "/root":
		return scene_root
	if scene_path.begins_with("/root/"):
		return resolve(scene_path.substr(5), scene_root)  # keep leading slash

	var root_prefix := "/" + scene_root.name
	if scene_path == root_prefix:
		return scene_root
	if scene_path.begins_with(root_prefix + "/"):
		var relative := scene_path.substr(root_prefix.length() + 1)
		return scene_root.get_node_or_null(relative)

	# Try as-is (relative path)
	return scene_root.get_node_or_null(scene_path)


## Format a "parent not found" error that names the path convention.
## Agents routinely try /root/Foo or absolute SceneTree paths; the bare
## "Parent not found: X" gave them no hint that paths are scene-relative.
static func format_parent_error(path: String, scene_root: Node) -> String:
	var root_name := scene_root.name if scene_root != null else "<no scene>"
	return (
		"Parent not found: %s. parent_path is relative to the edited scene root "
		"(e.g. \"/%s\" or \"\"), not the SceneTree. Scene root is \"/%s\"."
		% [path, root_name, root_name]
	)
