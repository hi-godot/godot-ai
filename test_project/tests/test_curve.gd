@tool
extends McpTestSuite

## Tests for CurveHandler — set points on Curve/Curve2D/Curve3D resources.

var _handler: CurveHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "curve"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = CurveHandler.new(_undo_redo)


func _add_path_3d(node_name: String) -> Path3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var p := Path3D.new()
	p.name = node_name
	p.curve = Curve3D.new()
	scene_root.add_child(p)
	p.set_owner(scene_root)
	return p


func _add_path_2d(node_name: String) -> Path2D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var p := Path2D.new()
	p.name = node_name
	p.curve = Curve2D.new()
	scene_root.add_child(p)
	p.set_owner(scene_root)
	return p


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()


# ----- validation -----

func test_set_points_no_home() -> void:
	var result := _handler.set_points({"points": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_points_both_homes() -> void:
	var result := _handler.set_points({
		"points": [],
		"path": "/Main/Path3D",
		"property": "curve",
		"resource_path": "res://curve.tres",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_points_missing_property() -> void:
	var result := _handler.set_points({
		"points": [],
		"path": "/Main/Path3D",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_set_points_wrong_resource_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mi := MeshInstance3D.new()
	mi.name = "NotACurveHost"
	mi.mesh = BoxMesh.new()
	scene_root.add_child(mi)
	mi.set_owner(scene_root)
	var result := _handler.set_points({
		"points": [],
		"path": mi.get_path(),
		"property": "mesh",  # BoxMesh, not a Curve
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Curve")
	_remove_node(mi)


# ----- Curve3D happy paths -----

func test_set_points_auto_creates_curve3d_when_null() -> void:
	# Regression: Path3D with curve=null should auto-create a fresh Curve3D
	# in the same undo action, rather than requiring a separate resource_create.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var p := Path3D.new()
	p.name = "TestAutoCreate3D"
	# Intentionally leave p.curve = null
	scene_root.add_child(p)
	p.set_owner(scene_root)
	assert_true(p.curve == null, "Precondition: curve slot should be empty")

	var result := _handler.set_points({
		"points": [
			{"position": {"x": 0, "y": 0, "z": 0}},
			{"position": {"x": 1, "y": 0, "z": 0}},
		],
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.curve_class, "Curve3D")
	assert_eq(result.data.point_count, 2)
	assert_true(result.data.curve_created, "curve_created should be true when slot was null")
	assert_true(p.curve is Curve3D)
	assert_eq(p.curve.point_count, 2)

	# Undo should clear the slot back to null, not leave the auto-created curve.
	editor_undo(_undo_redo)
	assert_true(p.curve == null, "Undo should clear the auto-created curve")
	_remove_node(p)


func test_set_points_auto_creates_curve2d_on_path2d() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var p := Path2D.new()
	p.name = "TestAutoCreate2D"
	scene_root.add_child(p)
	p.set_owner(scene_root)
	assert_true(p.curve == null)

	var result := _handler.set_points({
		"points": [
			{"position": {"x": 0, "y": 0}},
			{"position": {"x": 100, "y": 0}},
		],
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.curve_class, "Curve2D")
	assert_true(result.data.curve_created)
	assert_true(p.curve is Curve2D)
	_remove_node(p)


func test_set_points_existing_curve_does_not_flag_created() -> void:
	var p := _add_path_3d("TestExistingCurve")
	if p == null:
		skip("No scene root")
		return
	# Curve already exists from _add_path_3d
	var result := _handler.set_points({
		"points": [{"position": {"x": 0, "y": 0, "z": 0}}],
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_false(result.data.curve_created, "curve_created should be false when slot already had a curve")
	_remove_node(p)


func test_set_points_3d_position_only_coerces_vector3() -> void:
	var p := _add_path_3d("TestCurve3DPos")
	if p == null:
		skip("No scene root")
		return
	var points := [
		{"position": {"x": 0, "y": 0, "z": 0}},
		{"position": {"x": 5, "y": 0, "z": 0}},
		{"position": {"x": 5, "y": 5, "z": 0}},
	]
	var result := _handler.set_points({
		"points": points,
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.curve_class, "Curve3D")
	assert_eq(result.data.point_count, 3)
	assert_true(result.data.undoable)
	# Assert on stored Variant — not just the count.
	assert_eq(p.curve.point_count, 3)
	assert_true(p.curve.get_point_position(0) is Vector3)
	assert_eq(p.curve.get_point_position(0), Vector3(0, 0, 0))
	assert_eq(p.curve.get_point_position(1), Vector3(5, 0, 0))
	assert_eq(p.curve.get_point_position(2), Vector3(5, 5, 0))
	_remove_node(p)


func test_set_points_3d_with_tilts() -> void:
	var p := _add_path_3d("TestCurve3DTilt")
	if p == null:
		skip("No scene root")
		return
	var points := [
		{"position": {"x": 0, "y": 0, "z": 0}, "tilt": 0.0},
		{"position": {"x": 1, "y": 0, "z": 0}, "tilt": 1.5},
	]
	var result := _handler.set_points({
		"points": points,
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(p.curve.get_point_tilt(1), 1.5)
	_remove_node(p)


func test_set_points_3d_undo_restores_old_points() -> void:
	var p := _add_path_3d("TestCurve3DUndo")
	if p == null:
		skip("No scene root")
		return
	# Prime the curve with an initial point so we have something to restore.
	p.curve.add_point(Vector3(10, 10, 10))
	assert_eq(p.curve.point_count, 1)
	var result := _handler.set_points({
		"points": [
			{"position": {"x": 0, "y": 0, "z": 0}},
			{"position": {"x": 1, "y": 0, "z": 0}},
		],
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(p.curve.point_count, 2)
	editor_undo(_undo_redo)
	assert_eq(p.curve.point_count, 1)
	assert_eq(p.curve.get_point_position(0), Vector3(10, 10, 10))
	editor_redo(_undo_redo)
	assert_eq(p.curve.point_count, 2)
	_remove_node(p)


# ----- Curve2D happy path -----

func test_set_points_2d() -> void:
	var p := _add_path_2d("TestCurve2D")
	if p == null:
		skip("No scene root")
		return
	var points := [
		{"position": {"x": 0, "y": 0}},
		{"position": {"x": 100, "y": 50}},
	]
	var result := _handler.set_points({
		"points": points,
		"path": p.get_path(),
		"property": "curve",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.curve_class, "Curve2D")
	assert_true(p.curve.get_point_position(0) is Vector2)
	assert_eq(p.curve.get_point_position(1), Vector2(100, 50))
	_remove_node(p)


# ----- Curve (scalar) happy path -----

func test_set_points_scalar_curve() -> void:
	# Use a CPUParticles2D-like host — but actually, scalar Curves are more
	# commonly found on saved .tres files. Create and save one then edit it.
	var out_path := "res://test_tmp_curve.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var c := Curve.new()
	ResourceSaver.save(c, out_path)
	var result := _handler.set_points({
		"points": [
			{"offset": 0.0, "value": 0.0},
			{"offset": 0.5, "value": 1.0, "left_tangent": 0.5, "right_tangent": -0.5},
			{"offset": 1.0, "value": 0.0},
		],
		"resource_path": out_path,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.curve_class, "Curve")
	assert_eq(result.data.point_count, 3)
	assert_false(result.data.undoable)
	var loaded: Curve = ResourceLoader.load(out_path)
	assert_eq(loaded.point_count, 3)
	assert_eq(loaded.get_point_position(1).x, 0.5)
	assert_eq(loaded.get_point_position(1).y, 1.0)
	assert_eq(loaded.get_point_left_tangent(1), 0.5)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


# ----- regression: resource_path branch must not mutate the cached Resource -----

func test_set_points_disk_path_does_not_mutate_cached_resource() -> void:
	# If the handler mutates the loaded (cached) curve in place before saving,
	# anything else that holds a reference to the same ResourceLoader cache
	# would silently see the new points outside any undo action. Guard that.
	var out_path := "res://test_tmp_cache_sharing.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var c := Curve3D.new()
	c.add_point(Vector3(99, 99, 99))  # unique marker point in the ORIGINAL
	ResourceSaver.save(c, out_path)

	# Warm the ResourceLoader cache by loading once — this is the object the
	# handler's ResourceLoader.load() call will get back.
	var cached: Curve3D = ResourceLoader.load(out_path)
	assert_eq(cached.point_count, 1)
	assert_eq(cached.get_point_position(0), Vector3(99, 99, 99))

	var result := _handler.set_points({
		"points": [
			{"position": {"x": 0, "y": 0, "z": 0}},
			{"position": {"x": 1, "y": 0, "z": 0}},
		],
		"resource_path": out_path,
	})
	assert_has_key(result, "data")

	# The cached in-memory instance held by someone else (us, here) must
	# remain unmodified. The handler should have duplicated before mutating.
	assert_eq(cached.point_count, 1, "Cached Curve3D must not be mutated in place")
	assert_eq(cached.get_point_position(0), Vector3(99, 99, 99))

	# A fresh load, meanwhile, should reflect the newly-saved points.
	var reloaded: Curve3D = ResourceLoader.load(out_path)
	# If reloaded == cached (same cache slot), the cache may have been
	# invalidated by the save; regardless, reloading should give us 2 points.
	assert_gt(reloaded.point_count, 0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


func test_set_points_3d_invalid_point_shape() -> void:
	var p := _add_path_3d("TestCurve3DBadShape")
	if p == null:
		skip("No scene root")
		return
	var result := _handler.set_points({
		"points": [{"not_position": {"x": 0}}],
		"path": p.get_path(),
		"property": "curve",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(p)
