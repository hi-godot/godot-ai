@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const CsgHandler := preload("res://addons/godot_ai/handlers/csg_handler.gd")

var _csg_handler: CsgHandler
var _undo_redo: EditorUndoRedoManager
var _created_nodes: Array[Node] = []


func suite_name() -> String:
	return "csg"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_csg_handler = CsgHandler.new(_undo_redo)


func teardown() -> void:
	_cleanup_runtime_artifacts()
	## Committed undoable actions accumulate in the shared editor history;
	## drop them so later undo calls never roll back unrelated suites.
	if _undo_redo != null:
		_undo_redo.clear_history()


func suite_teardown() -> void:
	_cleanup_runtime_artifacts()


func _cleanup_runtime_artifacts() -> void:
	for node in _created_nodes:
		if is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()
	_created_nodes.clear()


func _root_path() -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	return McpScenePath.from_node(scene_root, scene_root)


## The handler returns MCP-style scene-relative paths (e.g. "/Main/CaveHole");
## locate the created node by name under the scene root instead of resolving
## that path through the live tree.
func _find_child_by_name(parent: Node, name: String) -> Node:
	for child in parent.get_children():
		if child.name == name:
			return child
	return null


func test_csg_create_box_with_default_union() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({"parent_path": _root_path()})
	assert_has_key(result, "data")
	assert_eq(result.data.shape, "box")
	assert_eq(result.data.operation, "union")
	assert_true(result.data.undoable)

	var node := _find_child_by_name(scene_root, result.data.name)
	_created_nodes.append(node)
	assert_true(node is CSGBox3D, "created node should be a CSGBox3D")
	assert_eq((node as CSGShape3D).operation, CSGShape3D.OPERATION_UNION)


func test_csg_create_sphere_with_subtraction() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({
		"parent_path": _root_path(),
		"name": "CaveHole",
		"shape": "sphere",
		"operation": "subtraction",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "CaveHole")
	assert_eq(result.data.shape, "sphere")
	assert_eq(result.data.operation, "subtraction")

	var node := _find_child_by_name(scene_root, "CaveHole")
	_created_nodes.append(node)
	assert_true(node is CSGSphere3D, "created node should be a CSGSphere3D")
	assert_eq((node as CSGShape3D).operation, CSGShape3D.OPERATION_SUBTRACTION)


func test_csg_create_defaults_name_to_shape_class() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({"parent_path": _root_path()})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "CSGBox3D", "omitted name should fall back to the shape class")

	var node := _find_child_by_name(scene_root, "CSGBox3D")
	_created_nodes.append(node)
	assert_true(node is CSGBox3D)


func test_csg_create_torus_and_polygon_shapes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var torus := _csg_handler.create({"parent_path": _root_path(), "name": "Ring", "shape": "torus"})
	assert_has_key(torus, "data")
	assert_eq(torus.data.shape, "torus")
	var torus_node := _find_child_by_name(scene_root, "Ring")
	_created_nodes.append(torus_node)
	assert_true(torus_node is CSGTorus3D, "created node should be a CSGTorus3D")

	var polygon := _csg_handler.create({"parent_path": _root_path(), "name": "Slab", "shape": "polygon"})
	assert_has_key(polygon, "data")
	assert_eq(polygon.data.shape, "polygon")
	var polygon_node := _find_child_by_name(scene_root, "Slab")
	_created_nodes.append(polygon_node)
	assert_true(polygon_node is CSGPolygon3D, "created node should be a CSGPolygon3D")


func test_csg_create_intersection_operation() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({
		"parent_path": _root_path(),
		"name": "Overlap",
		"shape": "cylinder",
		"operation": "intersection",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.operation, "intersection")

	var node := _find_child_by_name(scene_root, "Overlap")
	_created_nodes.append(node)
	assert_true(node is CSGCylinder3D)
	assert_eq((node as CSGShape3D).operation, CSGShape3D.OPERATION_INTERSECTION)


func test_csg_create_is_undoable() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({"parent_path": _root_path()})
	assert_has_key(result, "data")
	var node := _find_child_by_name(scene_root, result.data.name)
	_created_nodes.append(node)
	assert_true(node != null)

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_true(not is_instance_valid(node) or node.get_parent() == null,
		"undo should remove the created node from the scene")


func test_csg_create_unknown_shape_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({
		"parent_path": _root_path(),
		"shape": "icosahedron",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_csg_create_unknown_operation_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _csg_handler.create({
		"parent_path": _root_path(),
		"operation": "xor",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_csg_create_parent_not_node3d_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var parent := Node2D.new()
	parent.name = "_McpCsgBadParent"
	scene_root.add_child(parent)
	_created_nodes.append(parent)

	var result := _csg_handler.create({
		"parent_path": McpScenePath.from_node(parent, scene_root),
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_csg_set_operation_roundtrip_and_undo() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var created := _csg_handler.create({
		"parent_path": _root_path(),
		"shape": "cylinder",
	})
	assert_has_key(created, "data")
	var node := _find_child_by_name(scene_root, created.data.name)
	_created_nodes.append(node)
	assert_true(node is CSGCylinder3D)

	var result := _csg_handler.set_operation({
		"path": created.data.path,
		"operation": "subtraction",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.operation, "subtraction")
	assert_true(result.data.undoable)
	assert_eq((node as CSGShape3D).operation, CSGShape3D.OPERATION_SUBTRACTION)

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq((node as CSGShape3D).operation, CSGShape3D.OPERATION_UNION)


func test_csg_set_operation_wrong_type_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var node := Node3D.new()
	node.name = "_McpCsgWrongType"
	scene_root.add_child(node)
	_created_nodes.append(node)

	var result := _csg_handler.set_operation({
		"path": McpScenePath.from_node(node, scene_root),
		"operation": "union",
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_csg_scene_file_mismatch_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var wrong_scene := "res://_mcp_non_active_scene_for_csg.tscn"
	if scene_root.scene_file_path == wrong_scene:
		wrong_scene = "res://main.tscn"

	var result := _csg_handler.create({
		"parent_path": _root_path(),
		"scene_file": wrong_scene,
	})
	assert_is_error(result, ErrorCodes.EDITED_SCENE_MISMATCH)
