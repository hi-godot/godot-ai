@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const GridmapHandler := preload("res://addons/godot_ai/handlers/gridmap_handler.gd")

var _gridmap_handler: GridmapHandler
var _undo_redo: EditorUndoRedoManager
var _created_nodes: Array[Node] = []


func suite_name() -> String:
	return "gridmap"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_gridmap_handler = GridmapHandler.new(_undo_redo)


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


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	library.create_item(0)
	library.set_item_name(0, "Wall")
	library.set_item_mesh(0, BoxMesh.new())
	library.create_item(5)
	library.set_item_name(5, "Pillar")
	library.set_item_mesh(5, CylinderMesh.new())
	return library


func _create_gridmap(name: String, with_library := false) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var gm := GridMap.new()
	gm.name = name
	if with_library:
		gm.mesh_library = _make_library()
	scene_root.add_child(gm)
	_created_nodes.append(gm)
	return {
		"node": gm,
		"path": McpScenePath.from_node(gm, scene_root),
	}


func test_gridmap_set_item_and_read_cells() -> void:
	var ctx := _create_gridmap("_McpGridMapA")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var result := _gridmap_handler.set_item({
		"path": path,
		"item": 2,
		"map_x": 1,
		"map_y": 2,
		"map_z": -1,
		"orientation": 9,
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)

	var cells := _gridmap_handler.get_used_cells({"path": path})
	assert_has_key(cells, "data")
	assert_eq(cells.data.count, 1)
	assert_eq(cells.data.cells[0].x, 1)
	assert_eq(cells.data.cells[0].y, 2)
	assert_eq(cells.data.cells[0].z, -1)

	## Read the payload back from the engine: position alone doesn't prove
	## item/orientation were stored (the core of set_item's contract).
	var gm: GridMap = ctx.node
	assert_eq(gm.get_cell_item(Vector3i(1, 2, -1)), 2)
	assert_eq(gm.get_cell_item_orientation(Vector3i(1, 2, -1)), 9)


func test_gridmap_erase_with_negative_item() -> void:
	var ctx := _create_gridmap("_McpGridMapErase")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var placed := _gridmap_handler.set_item({
		"path": path, "item": 1, "map_x": 0, "map_y": 0, "map_z": 0,
	})
	assert_has_key(placed, "data")
	assert_eq(placed.data.item, 1)

	var erased := _gridmap_handler.set_item({
		"path": path, "item": -1, "map_x": 0, "map_y": 0, "map_z": 0,
	})
	assert_has_key(erased, "data")
	assert_eq(erased.data.item, -1)

	var after := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(after.data.count, 0)


func test_gridmap_fill_undo_preserves_outside_cells() -> void:
	var ctx := _create_gridmap("_McpGridMapFillUndo")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var seed_a := _gridmap_handler.set_item({
		"path": path, "item": 1, "map_x": -5, "map_y": -5, "map_z": -5,
	})
	var seed_b := _gridmap_handler.set_item({
		"path": path, "item": 1, "map_x": 10, "map_y": 10, "map_z": 10,
	})
	assert_has_key(seed_a, "data")
	assert_eq(seed_a.data.item, 1)
	assert_has_key(seed_b, "data")
	assert_eq(seed_b.data.item, 1)

	var fill := _gridmap_handler.fill({
		"path": path,
		"item": 2,
		"rect_x": 0, "rect_y": 0, "rect_z": 0,
		"rect_w": 2, "rect_h": 2, "rect_d": 2,
	})
	assert_has_key(fill, "data")
	assert_eq(fill.data.cells_filled, 8)

	var after_fill := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(after_fill.data.count, 10)

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")

	var after_undo := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(after_undo.data.count, 2, "Undo of fill must not clear cells outside region")

	var seen := {}
	for entry in after_undo.data.cells:
		seen["%s,%s,%s" % [entry.x, entry.y, entry.z]] = true
	assert_true(seen.has("-5,-5,-5"))
	assert_true(seen.has("10,10,10"))


func test_gridmap_fill_rejects_large_region() -> void:
	var ctx := _create_gridmap("_McpGridMapFillBig")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var result := _gridmap_handler.fill({
		"path": path,
		"item": 1,
		"rect_x": 0, "rect_y": 0, "rect_z": 0,
		"rect_w": 20, "rect_h": 20, "rect_d": 20,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_gridmap_fill_accepts_exactly_max_fill_cells() -> void:
	var ctx := _create_gridmap("_McpGridMapFillExact")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	## 16×16×16 = 4096 = MAX_FILL_CELLS — the boundary must succeed, only
	## strictly larger regions are rejected.
	var result := _gridmap_handler.fill({
		"path": path,
		"item": 1,
		"rect_x": 0, "rect_y": 0, "rect_z": 0,
		"rect_w": 16, "rect_h": 16, "rect_d": 16,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.cells_filled, 4096)

	var cells := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(cells.data.count, 4096)

	## Read the stored items back from the engine, not just the count: the
	## boundary fill must store item 1 at the region corners.
	var gm: GridMap = ctx.node
	assert_eq(gm.get_cell_item(Vector3i(0, 0, 0)), 1)
	assert_eq(gm.get_cell_item(Vector3i(15, 15, 15)), 1)


func test_gridmap_clear_is_undoable() -> void:
	var ctx := _create_gridmap("_McpGridMapClear")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var a := _gridmap_handler.set_item({
		"path": path, "item": 1, "map_x": 0, "map_y": 0, "map_z": 0,
	})
	var b := _gridmap_handler.set_item({
		"path": path, "item": 2, "map_x": 1, "map_y": 1, "map_z": 1,
	})
	assert_has_key(a, "data")
	assert_eq(a.data.item, 1)
	assert_has_key(b, "data")
	assert_eq(b.data.item, 2)

	var cleared := _gridmap_handler.clear_layer({"path": path})
	assert_has_key(cleared, "data")
	assert_true(cleared.data.cleared)
	assert_true(cleared.data.undoable)

	var after_clear := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(after_clear.data.count, 0)

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	var restored := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(restored.data.count, 2)


func test_gridmap_clear_rejects_oversized_map() -> void:
	var ctx := _create_gridmap("_McpGridMapClearBig")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	## Fill exactly MAX_FILL_CELLS (16×16×16), then nudge past the limit
	## with a handful of individual cells so clear_layer must refuse.
	var fill := _gridmap_handler.fill({
		"path": path,
		"item": 1,
		"rect_x": 0, "rect_y": 0, "rect_z": 0,
		"rect_w": 16, "rect_h": 16, "rect_d": 16,
	})
	assert_has_key(fill, "data")
	assert_eq(fill.data.cells_filled, 4096)
	for i in 8:
		var extra := _gridmap_handler.set_item({
			"path": path, "item": 1, "map_x": i, "map_y": 40, "map_z": 40,
		})
		assert_has_key(extra, "data")

	var result := _gridmap_handler.clear_layer({"path": path})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	## The oversized map is untouched — nothing was cleared.
	var cells := _gridmap_handler.get_used_cells({"path": path})
	assert_eq(cells.data.count, 4104)

	## Read the stored items back from the engine: a filled cell and an
	## added cell must still carry item 1 after the rejected clear.
	var gm: GridMap = ctx.node
	assert_eq(gm.get_cell_item(Vector3i(0, 0, 0)), 1)
	assert_eq(gm.get_cell_item(Vector3i(7, 40, 40)), 1)


func test_gridmap_list_library_items() -> void:
	var ctx := _create_gridmap("_McpGridMapLibrary", true)
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var result := _gridmap_handler.list_library_items({"path": path})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 2)
	assert_eq(result.data.items[0].item, 0)
	assert_eq(result.data.items[0].name, "Wall")
	## Runtime BoxMesh.new() has no resource_path — the exact value is "".
	assert_eq(result.data.items[0].mesh, "")
	assert_eq(result.data.items[1].item, 5)
	assert_eq(result.data.items[1].name, "Pillar")


func test_gridmap_list_library_items_empty_without_library() -> void:
	var ctx := _create_gridmap("_McpGridMapNoLibrary")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var result := _gridmap_handler.list_library_items({"path": path})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 0)
	assert_eq(result.data.library, "")


func test_gridmap_orientation_out_of_range() -> void:
	var ctx := _create_gridmap("_McpGridMapOrientation")
	if ctx.is_empty():
		skip("No scene open")
		return
	var path: String = ctx.path

	var result := _gridmap_handler.set_item({
		"path": path, "item": 1, "map_x": 0, "map_y": 0, "map_z": 0, "orientation": 25,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_gridmap_wrong_type_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var node := Node3D.new()
	node.name = "_McpGridMapWrongType"
	scene_root.add_child(node)
	_created_nodes.append(node)

	var result := _gridmap_handler.set_item({
		"path": McpScenePath.from_node(node, scene_root),
		"item": 1, "map_x": 0, "map_y": 0, "map_z": 0,
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_gridmap_scene_file_mismatch_returns_error() -> void:
	var ctx := _create_gridmap("_McpGridMapSceneFile")
	if ctx.is_empty():
		skip("No scene open")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var wrong_scene := "res://_mcp_non_active_scene_for_gridmap.tscn"
	if scene_root.scene_file_path == wrong_scene:
		wrong_scene = "res://main.tscn"

	var result := _gridmap_handler.get_used_cells({
		"path": ctx.path,
		"scene_file": wrong_scene,
	})
	assert_is_error(result, ErrorCodes.EDITED_SCENE_MISMATCH)
