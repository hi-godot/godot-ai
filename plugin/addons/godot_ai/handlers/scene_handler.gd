@tool
class_name SceneHandler
extends RefCounted

## Handles scene tree reading and node search.


func get_scene_tree(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("depth", 10)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {"data": {"nodes": [], "message": "No scene open"}}

	var nodes: Array[Dictionary] = []
	_walk_tree(scene_root, nodes, 0, max_depth, scene_root)
	return {"data": {"nodes": nodes, "total_count": nodes.size()}}


func get_open_scenes(_params: Dictionary) -> Dictionary:
	var scene_paths := EditorInterface.get_open_scenes()
	var scene_root := EditorInterface.get_edited_scene_root()
	var current := scene_root.scene_file_path if scene_root else ""
	return {
		"data": {
			"scenes": scene_paths,
			"current_scene": current,
			"count": scene_paths.size(),
		}
	}


func find_nodes(params: Dictionary) -> Dictionary:
	var name_filter: String = params.get("name", "")
	var type_filter: String = params.get("type", "")
	var group_filter: String = params.get("group", "")

	if name_filter.is_empty() and type_filter.is_empty() and group_filter.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "At least one filter (name, type, group) is required")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var results: Array[Dictionary] = []
	_find_recursive(scene_root, scene_root, name_filter, type_filter, group_filter, results)
	return {"data": {"nodes": results, "count": results.size()}}


func _find_recursive(node: Node, scene_root: Node, name_filter: String, type_filter: String, group_filter: String, out: Array[Dictionary]) -> void:
	var matches := true

	if not name_filter.is_empty():
		if node.name.to_lower().find(name_filter.to_lower()) == -1:
			matches = false

	if matches and not type_filter.is_empty():
		if node.get_class() != type_filter:
			matches = false

	if matches and not group_filter.is_empty():
		if not node.is_in_group(group_filter):
			matches = false

	if matches:
		out.append({
			"name": node.name,
			"type": node.get_class(),
			"path": ScenePath.from_node(node, scene_root),
		})

	for child in node.get_children():
		_find_recursive(child, scene_root, name_filter, type_filter, group_filter, out)


func _walk_tree(node: Node, out: Array[Dictionary], depth: int, max_depth: int, scene_root: Node) -> void:
	if depth > max_depth:
		return
	out.append({
		"name": node.name,
		"type": node.get_class(),
		"path": ScenePath.from_node(node, scene_root),
		"children_count": node.get_child_count(),
	})
	for child in node.get_children():
		_walk_tree(child, out, depth + 1, max_depth, scene_root)
