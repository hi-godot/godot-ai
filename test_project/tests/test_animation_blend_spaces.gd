@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/animation_tree_handler.gd")
var _handler: Handler
var _undo: EditorUndoRedoManager
var _root: Node
var _tree: AnimationTree
var _path: String


func suite_name() -> String:
	return "animation_blend_spaces"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.undo_redo
	_handler = Handler.new(_undo)
	if EditorInterface.get_edited_scene_root() == null:
		skip_suite("No scene open")


func setup() -> void:
	_root = EditorInterface.get_edited_scene_root()
	_tree = track(AnimationTree.new()) as AnimationTree
	_tree.name = "_McpTestBlendSpace"
	_tree.active = false
	_tree.tree_root = AnimationNodeBlendSpace1D.new()
	_root.add_child(_tree)
	_tree.owner = _root
	_path = McpScenePath.from_node(_tree, _root)


func teardown() -> void:
	if is_instance_valid(_tree):
		if _tree.get_parent() != null:
			_tree.get_parent().remove_child(_tree)
		_tree.queue_free()


func suite_teardown() -> void:
	for path in ["user://blend_space_roundtrip.tscn"]:
		DirAccess.remove_absolute(path)


func _call(op: String, params := {}) -> Dictionary:
	params.tree_path = _path
	return _handler.call(op, params)


func _ok(result: Dictionary) -> void:
	assert_false(result.has("error"), str(result))


func test_named_1d_points_insert_move_remove_and_undo() -> void:
	_ok(_call("tree_point_add", {"name": "Run", "position": 1, "properties": {"animation": "run"}}))
	_ok(_call("tree_point_add", {"name": "Idle", "position": 0, "at_index": 0, "properties": {"animation": "idle"}}))
	var graph := _tree.tree_root as AnimationNodeBlendSpace1D
	var idle := graph.get_blend_point_node(0)
	var run := graph.get_blend_point_node(1)
	assert_eq(String(idle.animation), "idle")
	assert_eq(String(run.animation), "run")
	assert_eq(String(graph.get_blend_point_name(0)), "Idle")
	assert_eq(String(graph.get_blend_point_name(1)), "Run")
	_ok(_call("tree_point_set", {"name": "Run", "position": 0.75}))
	assert_eq(graph.get_blend_point_position(1), 0.75)
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_blend_point_position(1), 1.0)
	assert_true(editor_redo(_undo))
	assert_eq(graph.get_blend_point_position(1), 0.75)
	_ok(_call("tree_node_set", {"graph_path": "Idle", "properties": {"animation": "rest"}}))
	assert_eq(String(idle.animation), "rest")
	_ok(_call("tree_point_remove", {"name": "Idle"}))
	assert_eq(graph.get_blend_point_node(0), run)
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_blend_point_node(0), idle)
	assert_eq(graph.get_blend_point_node(1), run)
	assert_eq(String(graph.get_blend_point_name(0)), "Idle")
	assert_eq(graph.get_blend_point_position(1), 0.75)
	var read := _call("tree_get")
	assert_eq(read.data.graph.points[0].name, "Idle")
	assert_eq(read.data.graph.points[0].properties.animation, "rest")
	assert_eq(read.data.graph.points[1].position, 0.75)


func test_2d_automatic_triangles_and_identity_survive_remove_undo() -> void:
	_tree.tree_root = AnimationNodeBlendSpace2D.new()
	for entry in [["A", -1, -1], ["B", 1, -1], ["C", 1, 1], ["D", -1, 1], ["Center", 0, 0]]:
		_ok(_call("tree_point_add", {"name": entry[0], "position": {"x": entry[1], "y": entry[2]}}))
	var graph := _tree.tree_root as AnimationNodeBlendSpace2D
	var center := graph.get_blend_point_node(4)
	_assert_center_triangles(graph)
	_ok(_call("tree_point_remove", {"name": "Center"}))
	_assert_square_triangles(graph)
	var read := _call("tree_get")
	assert_eq(read.data.graph.points.size(), 4)
	assert_true(graph.auto_triangles)
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_blend_point_node(4), center)
	assert_eq(String(graph.get_blend_point_name(4)), "Center")
	_assert_center_triangles(graph)
	assert_true(editor_redo(_undo))
	assert_eq(_call("tree_get").data.graph.points.size(), 4)
	_assert_square_triangles(graph)


func test_manual_triangle_indices_and_point_identity_restored() -> void:
	_tree.tree_root = AnimationNodeBlendSpace2D.new()
	var graph := _tree.tree_root as AnimationNodeBlendSpace2D
	graph.auto_triangles = false
	for entry in [["A", 0, 0], ["B", 1, 0], ["C", 0, 1], ["D", 1, 1]]:
		_ok(_call("tree_point_add", {"name": entry[0], "position": {"x": entry[1], "y": entry[2]}}))
	graph.add_triangle(0, 1, 2)
	graph.add_triangle(1, 2, 3)
	var b := graph.get_blend_point_node(1)
	_ok(_call("tree_point_add", {"name": "Inserted", "position": {"x": -1, "y": -1}, "at_index": 1}))
	assert_eq(_call("tree_get").data.graph.triangles, [[0, 2, 3], [2, 3, 4]])
	assert_eq(graph.get_blend_point_node(2), b)
	_ok(_call("tree_point_remove", {"name": "B"}))
	assert_eq(graph.get_triangle_count(), 0)
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_blend_point_node(2), b)
	assert_eq(_call("tree_get").data.graph.triangles, [[0, 2, 3], [2, 3, 4]])
	assert_true(editor_undo(_undo))
	assert_eq(graph.get_blend_point_node(1), b)
	assert_eq(_call("tree_get").data.graph.triangles, [[0, 1, 2], [1, 2, 3]])
	assert_false(graph.auto_triangles)


func test_point_validation_has_no_partial_mutation_or_history() -> void:
	_ok(_call("tree_point_add", {"name": "Idle", "position": 0}))
	var graph := _tree.tree_root as AnimationNodeBlendSpace1D
	var idle := graph.get_blend_point_node(0)
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	for name in ["", "bad.name", "bad/name", "Idle"]:
		assert_is_error(_call("tree_point_add", {"name": name, "position": 0}))
	for position in [INF, NAN, 1e300, true, {"x": 0, "y": 1}]:
		assert_is_error(_call("tree_point_set", {"name": "Idle", "position": position}))
	for index in [-2, 2, 0.5, INF, true]:
		assert_is_error(_call("tree_point_add", {"name": "Bad", "position": 0, "at_index": index}))
	assert_is_error(_call("tree_point_add", {"name": "Bad", "position": 0, "node_type": "AnimationNodeBlend2"}))
	assert_is_error(_call("tree_point_remove", {"name": "Missing"}))
	assert_eq(graph.get_blend_point_node(0), idle)
	assert_eq(graph.get_blend_point_position(0), 0.0)
	assert_eq(history.get_version(), version)
	_tree.tree_root = AnimationNodeBlendSpace2D.new()
	for position in [0, {"x": INF, "y": 0}, {"x": 1e300, "y": 0}, {"x": 0}]:
		assert_is_error(_call("tree_point_add", {"name": "Bad", "position": position}))
	assert_is_error(_call("tree_node_set", {"properties": {"min_space": {"x": -INF, "y": 0}}}))
	assert_eq(_tree.tree_root.min_space, Vector2(-1, -1))
	assert_eq(history.get_version(), version)


func test_nested_point_graph_and_saved_scene_roundtrip() -> void:
	_ok(_call("tree_point_add", {"name": "Nested", "position": 0.5, "node_type": "AnimationNodeBlendTree"}))
	_ok(_call("tree_node_add", {"graph_path": "Nested", "name": "Clip", "properties": {"animation": "walk"}}))
	_ok(_call("tree_connect", {"graph_path": "Nested", "input_node": "output", "input_index": 0, "output_node": "Clip"}))
	var read := _call("tree_get", {"graph_path": "Nested"})
	assert_eq(read.data.graph.connections, [{"input_node": "output", "input_index": 0, "output_node": "Clip"}])
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	var path := "user://blend_space_roundtrip.tscn"
	assert_eq(ResourceSaver.save(packed, path), OK)
	var reopened := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var scene := track(reopened.instantiate()) as Node
	var tree := scene.get_node("_McpTestBlendSpace") as AnimationTree
	assert_eq(String(tree.tree_root.get_blend_point_name(0)), "Nested")
	assert_eq(tree.tree_root.get_blend_point_position(0), 0.5)
	var nested: AnimationNodeBlendTree = tree.tree_root.get_blend_point_node(0)
	assert_eq(String(nested.get_node("Clip").animation), "walk")
	assert_eq(nested.get("node_connections"), [StringName("output"), 0, StringName("Clip")])
	scene.free()
	DirAccess.remove_absolute(path)


func test_native_blend_configuration_roundtrips_and_refuses_structure() -> void:
	_ok(_call("tree_node_set", {"properties": {"min_space": -4.0, "max_space": 6.0, "value_label": "Speed", "sync_mode": 2, "blend_mode": 1}}))
	var graph := _tree.tree_root as AnimationNodeBlendSpace1D
	assert_eq(graph.min_space, -4.0)
	assert_eq(graph.max_space, 6.0)
	assert_eq(graph.value_label, "Speed")
	assert_eq(graph.sync_mode, 2)
	var read := _call("tree_get")
	assert_eq(read.data.graph.properties.min_space, -4.0)
	assert_eq(read.data.graph.properties.value_label, "Speed")
	assert_true(editor_undo(_undo))
	assert_eq(graph.min_space, -1.0)
	assert_eq(graph.max_space, 1.0)
	_tree.tree_root = AnimationNodeBlendSpace2D.new()
	var graph2 := _tree.tree_root as AnimationNodeBlendSpace2D
	_ok(_call("tree_node_set", {"properties": {"min_space": {"x": -4, "y": -3}, "max_space": {"x": 5, "y": 6}, "x_label": "Horizontal", "y_label": "Vertical"}}))
	assert_eq(graph2.min_space, Vector2(-4, -3))
	assert_eq(graph2.max_space, Vector2(5, 6))
	assert_eq(graph2.x_label, "Horizontal")
	assert_eq(_call("tree_get").data.graph.properties.max_space, {"x": 5.0, "y": 6.0})
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	for props in [{"min_space": {"x": INF, "y": 0}}, {"max_space": {"x": 1e300, "y": 0}}, {"auto_triangles": false}, {"triangles": [0, 1, 2]}, {"blend_point_0/node": {"__class__": "AnimationNodeAnimation"}}]:
		assert_is_error(_call("tree_node_set", {"properties": props}))
	assert_eq(graph2.min_space, Vector2(-4, -3))
	assert_eq(graph2.max_space, Vector2(5, 6))
	assert_true(graph2.auto_triangles)
	assert_eq(history.get_version(), version)


func test_native_point_capacity_is_checked_before_mutation() -> void:
	for index in 64:
		_ok(_call("tree_point_add", {"name": "Point%d" % index, "position": index}))
	var graph := _tree.tree_root as AnimationNodeBlendSpace1D
	assert_eq(graph.get_blend_point_count(), 64)
	assert_eq(String(graph.get_blend_point_name(63)), "Point63")
	assert_eq(graph.get_blend_point_position(63), 63.0)
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_call("tree_point_add", {"name": "Excess", "position": 64}))
	assert_eq(graph.get_blend_point_count(), 64)
	assert_eq(history.get_version(), version)


func _assert_center_triangles(graph: AnimationNodeBlendSpace2D) -> void:
	# A valid triangle query also resolves the engine's pending triangulation.
	assert_true(graph.get_triangle_point(0, 0) >= 0)
	var triangles: Array = _call("tree_get").data.graph.triangles
	assert_eq(triangles.size(), 4)
	for triangle in [[0, 1, 4], [1, 2, 4], [2, 3, 4], [0, 3, 4]]:
		assert_true(triangles.has(triangle), "Stored center triangles: %s" % str(triangles))


func _assert_square_triangles(graph: AnimationNodeBlendSpace2D) -> void:
	assert_true(graph.get_triangle_point(0, 0) >= 0)
	var triangles: Array = _call("tree_get").data.graph.triangles
	assert_eq(triangles.size(), 2)
	var diagonal_ac := triangles.has([0, 1, 2]) and triangles.has([0, 2, 3])
	var diagonal_bd := triangles.has([0, 1, 3]) and triangles.has([1, 2, 3])
	assert_true(diagonal_ac or diagonal_bd, "Stored triangles must cover the square: %s" % str(triangles))
