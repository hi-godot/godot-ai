@tool
extends McpTestSuite

## Live-editor tests for ControlDrawRecipeHandler — control_draw_recipe command.
## Covers: op validation, value coercion (Color/Vector2/Rect2/PackedVector2Array),
## script attachment, meta persistence, undo/redo round-trips, error paths.

const DRAW_RECIPE_SCRIPT := preload("res://addons/godot_ai/runtime/draw_recipe.gd")

var _handler: ControlDrawRecipeHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "control_draw_recipe"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = ControlDrawRecipeHandler.new(_undo_redo)



# ----- happy-path op types -----


func test_line_op_lands_and_coerces() -> void:
	var path := _add_control("TestLineRecipe")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{
					"draw": "line",
					"from": [0, 0],
					"to": {"x": 18, "y": 0},
					"color": "#00eaff",
					"width": 2,
				}
			],
		}
	)
	assert_has_key(result, "data")
	assert_eq(result.data.ops_count, 1)
	assert_true(result.data.script_attached, "script should attach on clean node")
	assert_false(result.data.script_replaced)
	assert_true(result.data.undoable)

	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	assert_true(node.get_script() == DRAW_RECIPE_SCRIPT, "DrawRecipe script attached")
	assert_true(node.has_meta("_ops"), "_ops meta set")

	var stored: Array = node.get_meta("_ops")
	assert_eq(stored.size(), 1)
	var op: Dictionary = stored[0]
	assert_true(op.from is Vector2, "from coerced to Vector2")
	assert_eq(op.from, Vector2(0, 0))
	assert_true(op.to is Vector2, "to coerced to Vector2")
	assert_eq(op.to, Vector2(18, 0))
	assert_true(op.color is Color, "color coerced to Color")
	assert_eq(op.color, Color("#00eaff"))

	_remove_control(path)


func test_rect_op_all_dict_forms() -> void:
	var path := _add_control("TestRectRecipe")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{"draw": "rect", "rect": [0, 0, 10, 10], "color": "red"},
				{
					"draw": "rect",
					"rect": {"x": 5, "y": 5, "w": 20, "h": 20},
					"color": "#00ff00",
				},
				{
					"draw": "rect",
					"rect": {"position": {"x": 30, "y": 30}, "size": [5, 5]},
					"color": "blue",
				},
			],
		}
	)
	assert_has_key(result, "data")
	assert_eq(result.data.ops_count, 3)

	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	var stored: Array = node.get_meta("_ops")
	assert_true(stored[0].rect is Rect2)
	assert_eq(stored[0].rect, Rect2(0, 0, 10, 10))
	assert_eq(stored[1].rect, Rect2(5, 5, 20, 20))
	assert_eq(stored[2].rect, Rect2(30, 30, 5, 5))
	_remove_control(path)


func test_rect_outline_preserves_width() -> void:
	# filled=false takes the width branch of draw_recipe.gd's rect op.
	# When filled=true (the default), width is dropped to silence Godot's
	# "width has no effect when filled is true" warning (issue #98).
	var path := _add_control("TestRectOutline")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{
					"draw": "rect",
					"rect": [0, 0, 10, 10],
					"color": "red",
					"filled": false,
					"width": 3,
				}
			],
		}
	)
	assert_has_key(result, "data")

	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	var stored: Array = node.get_meta("_ops")
	assert_eq(stored[0].filled, false)
	assert_eq(stored[0].width, 3.0)
	_remove_control(path)


func test_polyline_points_stored_as_packed_array() -> void:
	var path := _add_control("TestPolylineRecipe")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{
					"draw": "polyline",
					"points": [[0, 0], [10, 5], {"x": 20, "y": 0}],
					"color": "#ff00ff",
					"width": 1.5,
				}
			],
		}
	)
	assert_has_key(result, "data")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	var stored: Array = node.get_meta("_ops")
	var pts: Variant = stored[0].points
	assert_eq(typeof(pts), TYPE_PACKED_VECTOR2_ARRAY, "points stored as PackedVector2Array")
	assert_eq(pts.size(), 3)
	assert_eq(pts[0], Vector2(0, 0))
	assert_eq(pts[2], Vector2(20, 0))
	_remove_control(path)


func test_all_op_types_accepted() -> void:
	var path := _add_control("TestAllOps")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{
					"draw": "line",
					"from": [0, 0],
					"to": [10, 10],
					"color": "red",
				},
				{
					"draw": "rect",
					"rect": [0, 0, 5, 5],
					"color": "red",
				},
				{
					"draw": "arc",
					"center": [10, 10],
					"radius": 5,
					"start_angle": 0.0,
					"end_angle": 1.57,
					"color": "blue",
				},
				{"draw": "circle", "center": [5, 5], "radius": 3, "color": "green"},
				{
					"draw": "polyline",
					"points": [[0, 0], [5, 5]],
					"color": "white",
				},
				{
					"draw": "polygon",
					"points": [[0, 0], [5, 0], [5, 5]],
					"color": "cyan",
				},
				{"draw": "string", "position": [1, 1], "text": "hi", "color": "white"},
			],
		}
	)
	assert_has_key(result, "data")
	assert_eq(result.data.ops_count, 7)
	_remove_control(path)


# ----- undo / redo -----


func test_undo_reverts_clean_node() -> void:
	var path := _add_control("TestUndoClean")
	if path.is_empty():
		skip("Scene not ready")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)

	var result := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[{"draw": "line", "from": [0, 0], "to": [5, 5], "color": "red"}],
		}
	)
	assert_has_key(result, "data")
	assert_true(node.has_meta("_ops"))
	assert_true(node.get_script() == DRAW_RECIPE_SCRIPT)

	_undo_redo.undo()
	assert_false(node.has_meta("_ops"), "undo should remove _ops meta")
	assert_true(node.get_script() == null, "undo should remove the script")

	_undo_redo.redo()
	assert_true(node.has_meta("_ops"), "redo re-applies meta")
	assert_true(node.get_script() == DRAW_RECIPE_SCRIPT, "redo re-attaches script")
	_remove_control(path)


func test_undo_preserves_prior_meta() -> void:
	# If the node already had _ops meta, undo must restore it (not remove it).
	var path := _add_control("TestUndoPrior")
	if path.is_empty():
		skip("Scene not ready")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)

	var ops_a: Array = [{"draw": "circle", "center": [1, 1], "radius": 1, "color": "red"}]
	var r1 := _handler.control_draw_recipe({"path": path, "ops": ops_a})
	assert_has_key(r1, "data")

	var ops_b: Array = [{"draw": "circle", "center": [2, 2], "radius": 2, "color": "blue"}]
	var r2 := _handler.control_draw_recipe({"path": path, "ops": ops_b})
	assert_has_key(r2, "data")
	var after_b: Array = node.get_meta("_ops")
	assert_eq(after_b[0].radius, 2.0)

	_undo_redo.undo()
	var restored: Array = node.get_meta("_ops")
	assert_eq(restored[0].radius, 1.0, "undo should restore prior _ops meta")
	assert_true(node.get_script() == DRAW_RECIPE_SCRIPT, "script still attached")
	_remove_control(path)


# ----- error paths -----


func test_missing_path_errors() -> void:
	var result := _handler.control_draw_recipe({"ops": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_non_array_ops_errors() -> void:
	var result := _handler.control_draw_recipe({"path": "/Main", "ops": "nope"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_node_not_found_errors() -> void:
	var result := _handler.control_draw_recipe({"path": "/Bogus/Path", "ops": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_non_control_rejected() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("Scene not ready")
		return
	var n := Node2D.new()
	n.name = "TestNonControl"
	scene_root.add_child(n)
	n.owner = scene_root
	var path := "/" + scene_root.name + "/" + n.name

	var result := _handler.control_draw_recipe({"path": path, "ops": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "Control")

	scene_root.remove_child(n)
	n.queue_free()


func test_missing_required_op_field_errors() -> void:
	var path := _add_control("TestMissingField")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{"path": path, "ops": [{"draw": "line", "from": [0, 0], "color": "red"}]}
	)
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "'to'")
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	assert_false(node.has_meta("_ops"), "invalid op must not mutate node")
	assert_true(node.get_script() == null)
	_remove_control(path)


func test_unknown_draw_type_errors() -> void:
	var path := _add_control("TestUnknownDraw")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe(
		{"path": path, "ops": [{"draw": "triangle", "color": "red"}]}
	)
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "unknown draw type")
	_remove_control(path)


func test_existing_user_script_rejected_when_clear_existing_false() -> void:
	var path := _add_control("TestUserScript")
	if path.is_empty():
		skip("Scene not ready")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)

	var user_script := GDScript.new()
	user_script.source_code = "@tool\nextends Control\n"
	user_script.reload()
	node.set_script(user_script)
	assert_true(node.get_script() != null)

	var r1 := _handler.control_draw_recipe(
		{"path": path, "ops": [], "clear_existing": false}
	)
	assert_is_error(r1, McpErrorCodes.INVALID_PARAMS)
	assert_true(node.get_script() == user_script, "user script preserved on error")

	var r2 := _handler.control_draw_recipe(
		{"path": path, "ops": [], "clear_existing": true}
	)
	assert_has_key(r2, "data")
	assert_true(r2.data.script_replaced, "script_replaced should be true")
	_remove_control(path)


func test_reinvoke_idempotent_replaces_meta() -> void:
	var path := _add_control("TestReinvoke")
	if path.is_empty():
		skip("Scene not ready")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)

	var r1 := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[{"draw": "circle", "center": [1, 1], "radius": 1, "color": "red"}],
		}
	)
	assert_has_key(r1, "data")
	assert_true(r1.data.script_attached)

	var r2 := _handler.control_draw_recipe(
		{
			"path": path,
			"ops":
			[
				{"draw": "circle", "center": [2, 2], "radius": 2, "color": "blue"},
				{
					"draw": "line",
					"from": [0, 0],
					"to": [3, 3],
					"color": "white",
				},
			],
		}
	)
	assert_has_key(r2, "data")
	var stored: Array = node.get_meta("_ops")
	assert_eq(stored.size(), 2, "re-invoking replaces ops list")
	_remove_control(path)


func test_zero_ops_succeeds() -> void:
	# Empty ops is a valid no-op draw — supports "clear the recipe" idioms.
	var path := _add_control("TestZeroOps")
	if path.is_empty():
		skip("Scene not ready")
		return
	var result := _handler.control_draw_recipe({"path": path, "ops": []})
	assert_has_key(result, "data")
	assert_eq(result.data.ops_count, 0)

	var scene_root := EditorInterface.get_edited_scene_root()
	var node := ScenePath.resolve(path, scene_root)
	assert_true(node.has_meta("_ops"))
	var stored: Array = node.get_meta("_ops")
	assert_eq(stored.size(), 0)
	_remove_control(path)
