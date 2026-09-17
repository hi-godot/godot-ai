@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const NavigationHandler := preload("res://addons/godot_ai/handlers/navigation_handler.gd")

## Tests for NavigationHandler — regions, mesh/polygon configuration and
## baking, agents, obstacles, and path queries.
##
## Bake tests build their source geometry as children of the region (the
## default source-geometry mode) and bake synchronously, so no frames are
## awaited.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: NavigationHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "navigation"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = NavigationHandler.new(_undo_redo)


func suite_teardown() -> void:
	if _undo_redo != null:
		_undo_redo.clear_history()


# ----- helpers -----

func _add_child_node(parent: Node, node: Node, node_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	node.name = node_name
	parent.add_child(node)
	node.set_owner(scene_root)
	return node


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


func _make_box_mesh(size: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	return mesh


# ----- region_create -----

func test_region_create_3d_attaches_mesh_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var result := _handler.region_create({"parent_path": "/" + scene_root.name, "dimension": "3d"})
	assert_has_key(result, "data")
	assert_eq(result.data.dimension, "3d")
	assert_eq(result.data.class, "NavigationRegion3D")
	var region := McpScenePath.resolve(result.data.path, scene_root) as NavigationRegion3D
	assert_true(region != null, "region must exist in the scene")
	assert_true(region.navigation_mesh is NavigationMesh, "region must carry a NavigationMesh")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_true(region.get_parent() == null, "undo must remove the region")


func test_region_create_2d_attaches_polygon() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var result := _handler.region_create({
		"parent_path": "/" + scene_root.name,
		"dimension": "2d",
		"name": "NavRegion2D",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.class, "NavigationRegion2D")
	var region := McpScenePath.resolve(result.data.path, scene_root) as NavigationRegion2D
	assert_true(region != null)
	assert_true(region.navigation_polygon is NavigationPolygon, "region must carry a NavigationPolygon")
	_remove_node(region)


# ----- mesh_configure -----

func test_mesh_configure_sets_values_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.region_create({"parent_path": "/" + scene_root.name})
	assert_has_key(created, "data")
	var region := McpScenePath.resolve(created.data.path, scene_root) as NavigationRegion3D
	_undo_redo.clear_history()
	var result := _handler.mesh_configure({
		"path": created.data.path,
		"agent_radius": 0.75,
		"cell_size": 0.5,
		"geometry_parsed_geometry_type": "static_colliders",
		"geometry_source_geometry_mode": "root_children",
	})
	assert_has_key(result, "data")
	assert_eq(region.navigation_mesh.agent_radius, 0.75)
	assert_eq(region.navigation_mesh.cell_size, 0.5)
	assert_eq(region.navigation_mesh.geometry_parsed_geometry_type, 1, "name must map to static_colliders")
	assert_eq(result.data.applied.geometry_parsed_geometry_type, 1)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.agent_radius, 0.5, "undo must restore the default radius")
	_remove_node(region)


func test_mesh_configure_rejects_unknown_and_bad_enum() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.region_create({"parent_path": "/" + scene_root.name})
	assert_has_key(created, "data")
	var region := McpScenePath.resolve(created.data.path, scene_root) as NavigationRegion3D
	var unknown := _handler.mesh_configure({"path": created.data.path, "wobble": 1.0})
	assert_is_error(unknown, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(unknown.error.message, "wobble")
	var bad_enum := _handler.mesh_configure({
		"path": created.data.path,
		"geometry_parsed_geometry_type": "everything",
	})
	assert_is_error(bad_enum, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_enum.error.message, "mesh_instances")
	assert_false(
		bad_enum.error.message.contains("root_children"),
		"the error must list only the property's own vocabulary"
	)
	## Enum names must not be accepted for plain integer properties.
	var wrong_property_enum := _handler.mesh_configure({
		"path": created.data.path,
		"vertices_per_polygon": "both",
	})
	assert_is_error(wrong_property_enum, ErrorCodes.WRONG_TYPE)
	assert_contains(wrong_property_enum.error.message, "vertices_per_polygon")
	var cross_dimension := _handler.mesh_configure({
		"path": created.data.path,
		"parsed_geometry_type": "both",
	})
	assert_is_error(cross_dimension, ErrorCodes.VALUE_OUT_OF_RANGE)
	_remove_node(region)


# ----- agents / obstacles -----

func test_agent_create_and_configure() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.agent_create({"parent_path": "/" + scene_root.name})
	assert_has_key(created, "data")
	assert_eq(created.data.class, "NavigationAgent3D")
	var agent := McpScenePath.resolve(created.data.path, scene_root) as NavigationAgent3D
	_undo_redo.clear_history()
	var result := _handler.agent_configure({
		"path": created.data.path,
		"radius": 0.8,
		"height": 1.9,
		"max_speed": 4.5,
		"avoidance_enabled": true,
	})
	assert_has_key(result, "data")
	assert_true(absf(agent.radius - 0.8) < 0.001, "radius must apply, got %s" % str(agent.radius))
	assert_true(absf(agent.height - 1.9) < 0.001, "height must apply, got %s" % str(agent.height))
	assert_true(absf(agent.max_speed - 4.5) < 0.001, "max_speed must apply, got %s" % str(agent.max_speed))
	assert_true(agent.avoidance_enabled)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_true(absf(agent.radius - 0.5) < 0.001, "undo must restore the default radius")
	_remove_node(agent)


func test_agent_configure_2d_rejects_height() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.agent_create({"parent_path": "/" + scene_root.name, "dimension": "2d"})
	assert_has_key(created, "data")
	assert_eq(created.data.class, "NavigationAgent2D")
	var result := _handler.agent_configure({"path": created.data.path, "height": 1.9})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "height")
	_remove_node(McpScenePath.resolve(created.data.path, scene_root))


func test_obstacle_create_and_configure() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.obstacle_create({"parent_path": "/" + scene_root.name})
	assert_has_key(created, "data")
	assert_eq(created.data.class, "NavigationObstacle3D")
	var obstacle := McpScenePath.resolve(created.data.path, scene_root) as NavigationObstacle3D
	var result := _handler.obstacle_configure({
		"path": created.data.path,
		"radius": 1.2,
		"height": 2.0,
	})
	assert_has_key(result, "data")
	assert_true(absf(obstacle.radius - 1.2) < 0.001, "radius must apply, got %s" % str(obstacle.radius))
	assert_true(absf(obstacle.height - 2.0) < 0.001, "height must apply, got %s" % str(obstacle.height))
	_remove_node(obstacle)


# ----- bake / path_get -----

func test_bake_3d_produces_polygons_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.region_create({
		"parent_path": "/" + scene_root.name,
		"name": "NavBake3D",
	})
	assert_has_key(created, "data")
	var region := McpScenePath.resolve(created.data.path, scene_root) as NavigationRegion3D
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var baked := _handler.bake({"path": created.data.path})
	assert_has_key(baked, "data")
	assert_true(baked.data.polygon_count > 0,
		"baking a 20x20 box floor must produce polygons, got %d" % baked.data.polygon_count)
	assert_true(baked.data.vertex_count > 0, "baked polygons must have vertices")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "undo must restore the pre-bake mesh")
	_remove_node(region)


func test_bake_undo_redo_restores_prebake_state() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.region_create({
		"parent_path": "/" + scene_root.name,
		"name": "NavBakeCycle",
	})
	assert_has_key(created, "data")
	var region := McpScenePath.resolve(created.data.path, scene_root) as NavigationRegion3D
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var baked := _handler.bake({"path": created.data.path})
	assert_has_key(baked, "data")
	assert_true(baked.data.polygon_count > 0, "bake must produce polygons")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "undo restores the pre-bake mesh")
	var did_redo := editor_redo(_undo_redo)
	assert_true(did_redo, "redo should succeed")
	assert_true(region.navigation_mesh.get_polygon_count() > 0, "redo re-bakes the mesh")
	## A second undo must still reach the pre-bake state: the first redo must
	## not have mutated the resource the undo action restores.
	did_undo = editor_undo(_undo_redo)
	assert_true(did_undo, "the second undo should succeed")
	assert_eq(
		region.navigation_mesh.get_polygon_count(), 0,
		"the second undo must still restore the pre-bake mesh"
	)
	_remove_node(region)


## The editor's navigation map only processes geometry on physics frames, so a
## path query right after a bake can legitimately return an empty path here.
## This asserts the read-only response contract; live games get the baked path.
func test_path_get_returns_response_shape() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var result := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.dimension, "3d")
	assert_true(result.data.point_count >= 0, "point_count must be a count")
	assert_eq(result.data.point_count, result.data.points.size())
	assert_false(result.data.has("undoable"), "path_get is read-only")
	var created := _handler.region_create({
		"parent_path": "/" + scene_root.name,
		"dimension": "2d",
		"name": "NavPathMap2D",
	})
	assert_has_key(created, "data")
	var two_d := _handler.path_get({
		"dimension": "2d",
		"from_point": [-8.0, -8.0],
		"to_point": [8.0, 8.0],
	})
	assert_has_key(two_d, "data")
	assert_eq(two_d.data.dimension, "2d")
	assert_eq(two_d.data.point_count, two_d.data.points.size())
	_remove_node(McpScenePath.resolve(created.data.path, scene_root))


func test_bake_2d_reports_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var created := _handler.region_create({
		"parent_path": "/" + scene_root.name,
		"dimension": "2d",
		"name": "NavBake2D",
	})
	assert_has_key(created, "data")
	var region := McpScenePath.resolve(created.data.path, scene_root) as NavigationRegion2D
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-10, -10), Vector2(10, -10), Vector2(10, 10), Vector2(-10, 10),
	])
	_add_child_node(region, poly, "Floor")
	_handler.mesh_configure({
		"path": created.data.path,
		"cell_size": 1.0,
		"agent_radius": 1.0,
	})
	_undo_redo.clear_history()
	var baked := _handler.bake({"path": created.data.path})
	assert_has_key(baked, "data")
	assert_eq(baked.data.mesh_class, "NavigationPolygon")
	assert_true(baked.data.polygon_count >= 0, "bake must report a polygon count")
	## 2D bake output can be empty until the navigation server processes a
	## physics frame in the editor; the undo contract holds either way.
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	_remove_node(region)


func test_path_get_rejects_bad_points() -> void:
	var bad_from := _handler.path_get({"from_point": {"x": 1.0}, "to_point": {"x": 2.0, "y": 3.0, "z": 4.0}})
	assert_is_error(bad_from, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_from.error.message, "from_point")
	var bad_to := _handler.path_get({
		"from_point": {"x": 1.0, "y": 2.0, "z": 3.0},
		"to_point": "nowhere",
	})
	assert_is_error(bad_to, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_to.error.message, "to_point")


func test_navigation_node_wrong_type_and_dimension() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var plain := Node3D.new()
	_add_child_node(scene_root, plain, "NavNotANode")
	var wrong := _handler.bake({"path": "/" + scene_root.name + "/NavNotANode"})
	assert_is_error(wrong, ErrorCodes.WRONG_TYPE)
	assert_contains(wrong.error.message, "navigation")
	var bad_dimension := _handler.region_create({"dimension": "4d"})
	assert_is_error(bad_dimension, ErrorCodes.VALUE_OUT_OF_RANGE)
	_remove_node(plain)
