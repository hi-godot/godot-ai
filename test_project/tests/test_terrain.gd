@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const TerrainHandler := preload("res://addons/godot_ai/handlers/terrain_handler.gd")

var _terrain_handler: TerrainHandler
var _undo_redo: EditorUndoRedoManager
var _created_nodes: Array[Node] = []


func suite_name() -> String:
	return "terrain"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_terrain_handler = TerrainHandler.new(_undo_redo)


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


func _find_child(parent: Node, name: String) -> Node:
	for child in parent.get_children():
		if child.name == name:
			return child
	return null


func _corner_height(container: Node, idx: int) -> float:
	var mi := _find_child(container, "TerrainMesh") as MeshInstance3D
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return verts[idx].y


## Height at grid cell (gx, gz) of a size-48 terrain. Avoids grid (0, 0),
## which maps to noise(0, 0) — that sample is seed-independent, so it can't
## prove determinism.
func _grid_height(container: Node, gx: int, gz: int) -> float:
	var mi := _find_child(container, "TerrainMesh") as MeshInstance3D
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return verts[gz * 48 + gx].y


func test_terrain_create_builds_mesh_and_collision() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _terrain_handler.create({"parent_path": _root_path(), "name": "Hills"})
	assert_has_key(result, "data")
	assert_eq(result.data.name, "Hills")
	assert_eq(result.data.size, 48)
	assert_eq(result.data.vertices, 48 * 48)
	assert_eq(result.data.triangles, 2 * 47 * 47)
	assert_true(result.data.generate_collision)
	assert_true(result.data.undoable)

	var container := _find_child(scene_root, "Hills")
	_created_nodes.append(container)
	assert_true(container is Node3D)
	var mi := _find_child(container, "TerrainMesh")
	assert_true(mi is MeshInstance3D, "container should hold a TerrainMesh")
	assert_true((mi as MeshInstance3D).mesh != null)
	var arrays := (mi as MeshInstance3D).mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), 48 * 48, "mesh should carry one vertex per grid cell")

	var body := _find_child(container, "TerrainCollision")
	assert_true(body is StaticBody3D, "collision should be on by default")
	var cs: CollisionShape3D = body.get_child(0) as CollisionShape3D
	assert_true(cs.shape is ConcavePolygonShape3D)

	## Owners are assigned after attachment, so every generated node is
	## owned by the scene root and persists when the scene is saved.
	assert_true(container.owner == scene_root, "container must be owned by the scene root")
	assert_true(mi.owner == scene_root, "TerrainMesh must be owned by the scene root")
	assert_true(body.owner == scene_root, "TerrainCollision must be owned by the scene root")


func test_terrain_create_collision_off_when_disabled() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _terrain_handler.create({
		"parent_path": _root_path(), "name": "Deco", "generate_collision": false,
	})
	assert_has_key(result, "data")
	assert_false(result.data.generate_collision)
	assert_true(result.data.undoable)

	var container := _find_child(scene_root, "Deco")
	_created_nodes.append(container)
	assert_true(_find_child(container, "TerrainMesh") != null)
	assert_true(_find_child(container, "TerrainCollision") == null,
		"no collision body when generate_collision is false")


func test_terrain_seed_determinism() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var a := _terrain_handler.create({
		"parent_path": _root_path(), "name": "SeedA", "seed": 42,
	})
	var b := _terrain_handler.create({
		"parent_path": _root_path(), "name": "SeedB", "seed": 42,
	})
	var c := _terrain_handler.create({
		"parent_path": _root_path(), "name": "SeedC", "seed": 43,
	})
	assert_has_key(a, "data")
	assert_has_key(b, "data")
	assert_has_key(c, "data")

	var node_a := _find_child(scene_root, "SeedA")
	var node_b := _find_child(scene_root, "SeedB")
	var node_c := _find_child(scene_root, "SeedC")
	_created_nodes.append(node_a)
	_created_nodes.append(node_b)
	_created_nodes.append(node_c)

	var mi_a := _find_child(node_a, "TerrainMesh") as MeshInstance3D
	var mi_b := _find_child(node_b, "TerrainMesh") as MeshInstance3D
	var verts_a: PackedVector3Array = mi_a.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var verts_b: PackedVector3Array = mi_b.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts_a, verts_b, "same seed must produce identical vertex arrays")
	## Grid (0, 0) maps to noise(0, 0), which is seed-independent — compare
	## an interior cell instead.
	assert_ne(_grid_height(node_a, 10, 10), _grid_height(node_c, 10, 10),
		"different seed must produce a different mesh")


func test_terrain_regenerate_undo_restores_previous_mesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var created := _terrain_handler.create({
		"parent_path": _root_path(), "name": "Rebuild", "seed": 7,
	})
	assert_has_key(created, "data")
	var container := _find_child(scene_root, "Rebuild")
	_created_nodes.append(container)
	var before := _grid_height(container, 10, 10)
	assert_true(_find_child(container, "TerrainCollision") is StaticBody3D)

	var regenerated := _terrain_handler.regenerate({
		"path": created.data.path, "seed": 999, "height_scale": 20.0,
		"generate_collision": false,
	})
	assert_has_key(regenerated, "data")
	assert_eq(regenerated.data.vertices, 48 * 48)
	assert_true(regenerated.data.undoable)
	var after := _grid_height(container, 10, 10)
	assert_ne(after, before, "regenerate must change the mesh for a new seed")
	assert_true(_find_child(container, "TerrainCollision") == null,
		"regenerate with generate_collision=false must remove the collision body")

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(_grid_height(container, 10, 10), before,
		"undo must restore the previous mesh state")
	assert_true(_find_child(container, "TerrainCollision") is StaticBody3D,
		"undo must restore the previous collision state")


func test_terrain_create_is_undoable() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _terrain_handler.create({"parent_path": _root_path(), "name": "UndoMe"})
	assert_has_key(result, "data")
	var container := _find_child(scene_root, "UndoMe")
	_created_nodes.append(container)
	assert_true(container != null)

	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_true(not is_instance_valid(container) or container.get_parent() == null,
		"undo should remove the created container from the scene")


func test_terrain_rejects_invalid_params() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var bad_size := _terrain_handler.create({"parent_path": _root_path(), "size": 200})
	assert_is_error(bad_size, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_cell := _terrain_handler.create({"parent_path": _root_path(), "cell_size": 0.0})
	assert_is_error(bad_cell, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_scale := _terrain_handler.create({"parent_path": _root_path(), "height_scale": -1.0})
	assert_is_error(bad_scale, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_freq := _terrain_handler.create({"parent_path": _root_path(), "frequency": 0.0})
	assert_is_error(bad_freq, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_octaves := _terrain_handler.create({"parent_path": _root_path(), "octaves": 0})
	assert_is_error(bad_octaves, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_terrain_rejects_unknown_noise_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var result := _terrain_handler.create({
		"parent_path": _root_path(), "noise_type": "billow",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_terrain_frequency_changes_shape() -> void:
	## Guard against the frequency being applied twice (FastNoiseLite
	## frequency + a manual coordinate multiply would square it): distinct
	## frequency values must produce distinct meshes for the same seed.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var low := _terrain_handler.create({
		"parent_path": _root_path(), "name": "FreqLow", "seed": 5, "frequency": 0.02,
	})
	var high := _terrain_handler.create({
		"parent_path": _root_path(), "name": "FreqHigh", "seed": 5, "frequency": 0.2,
	})
	assert_has_key(low, "data")
	assert_has_key(high, "data")

	var node_low := _find_child(scene_root, "FreqLow")
	var node_high := _find_child(scene_root, "FreqHigh")
	_created_nodes.append(node_low)
	_created_nodes.append(node_high)
	assert_ne(_grid_height(node_low, 10, 10), _grid_height(node_high, 10, 10),
		"different frequencies must produce different terrain for the same seed")


func test_terrain_parent_not_node3d_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var parent := Node2D.new()
	parent.name = "_McpTerrainBadParent"
	scene_root.add_child(parent)
	_created_nodes.append(parent)

	var result := _terrain_handler.create({
		"parent_path": McpScenePath.from_node(parent, scene_root),
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_terrain_regenerate_wrong_type_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var node := Node2D.new()
	node.name = "_McpTerrainWrongType"
	scene_root.add_child(node)
	_created_nodes.append(node)

	var result := _terrain_handler.regenerate({
		"path": McpScenePath.from_node(node, scene_root),
	})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


func test_terrain_scene_file_mismatch_returns_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	var wrong_scene := "res://_mcp_non_active_scene_for_terrain.tscn"
	if scene_root.scene_file_path == wrong_scene:
		wrong_scene = "res://main.tscn"

	var result := _terrain_handler.create({
		"parent_path": _root_path(),
		"scene_file": wrong_scene,
	})
	assert_is_error(result, ErrorCodes.EDITED_SCENE_MISMATCH)
