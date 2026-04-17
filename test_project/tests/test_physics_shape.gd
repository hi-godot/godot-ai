@tool
extends McpTestSuite

## Tests for PhysicsShapeHandler — autofit CollisionShape* to sibling bounds.

var _handler: PhysicsShapeHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "physics_shape"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = PhysicsShapeHandler.new(_undo_redo)


# ----- helpers -----

func _add_body_3d(body_name: String, mesh_size: Vector3) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var body := StaticBody3D.new()
	body.name = body_name
	scene_root.add_child(body)
	body.set_owner(scene_root)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var box := BoxMesh.new()
	box.size = mesh_size
	mi.mesh = box
	body.add_child(mi)
	mi.set_owner(scene_root)

	var col := CollisionShape3D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)

	return {"body": body, "mesh": mi, "collision": col}


func _add_body_2d(body_name: String, rect_size: Vector2) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var body := StaticBody2D.new()
	body.name = body_name
	scene_root.add_child(body)
	body.set_owner(scene_root)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	# Create a tiny test texture so get_rect() returns non-zero bounds.
	var img := Image.create(int(rect_size.x), int(rect_size.y), false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	sprite.texture = ImageTexture.create_from_image(img)
	body.add_child(sprite)
	sprite.set_owner(scene_root)

	var col := CollisionShape2D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)

	return {"body": body, "sprite": sprite, "collision": col}


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()


# ----- validation errors -----

func test_autofit_missing_path() -> void:
	var result := _handler.autofit({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_autofit_node_not_found() -> void:
	var result := _handler.autofit({"path": "/Main/NopeNotHere"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_autofit_node_is_not_collision_shape() -> void:
	var result := _handler.autofit({"path": "/Main/Camera3D"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "CollisionShape")


func test_autofit_invalid_shape_type_for_3d() -> void:
	var parts := _add_body_3d("TestBadType3D", Vector3(2, 1, 1))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "rectangle",  # 2D-only type used in 3D context
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(parts.body)


# ----- 3D happy paths -----

func test_autofit_3d_box_creates_and_sizes_shape() -> void:
	var parts := _add_body_3d("TestAutofit3DBox", Vector3(3, 1, 2))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "BoxShape3D")
	assert_true(result.data.shape_created)
	assert_true(result.data.undoable)
	# The auto-detected source_path must be a clean scene path, not an
	# editor-internal viewport path. Regression guard.
	assert_true(result.data.source_path.begins_with("/"), "source_path should be a scene path")
	assert_false(result.data.source_path.contains("@SubViewport"), "source_path must not leak editor viewport wrapping")
	assert_true(parts.collision.shape is BoxShape3D)
	assert_true(parts.collision.shape.size is Vector3)
	assert_eq(parts.collision.shape.size.x, 3.0)
	assert_eq(parts.collision.shape.size.y, 1.0)
	assert_eq(parts.collision.shape.size.z, 2.0)
	editor_undo(_undo_redo)
	assert_true(parts.collision.shape == null)
	_remove_node(parts.body)


func test_autofit_3d_sphere_uses_max_extent() -> void:
	var parts := _add_body_3d("TestAutofit3DSphere", Vector3(4, 1, 2))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "sphere",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "SphereShape3D")
	assert_true(parts.collision.shape is SphereShape3D)
	assert_eq(parts.collision.shape.radius, 2.0)  # max(4,1,2) / 2
	_remove_node(parts.body)


func test_autofit_3d_capsule_dims() -> void:
	var parts := _add_body_3d("TestAutofit3DCap", Vector3(2, 4, 2))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "capsule",
	})
	assert_has_key(result, "data")
	assert_true(parts.collision.shape is CapsuleShape3D)
	assert_eq(parts.collision.shape.radius, 1.0)  # max(x,z) / 2
	assert_eq(parts.collision.shape.height, 4.0)
	_remove_node(parts.body)


func test_autofit_3d_reuses_existing_shape_of_same_type() -> void:
	var parts := _add_body_3d("TestAutofit3DReuse", Vector3(1, 1, 1))
	if parts.is_empty():
		skip("No scene root")
		return
	var existing := BoxShape3D.new()
	existing.size = Vector3(0.1, 0.1, 0.1)
	parts.collision.shape = existing
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_false(result.data.shape_created, "Existing BoxShape3D should be reused")
	assert_eq(parts.collision.shape, existing, "Shape object identity should be preserved on reuse")
	assert_eq(parts.collision.shape.size.x, 1.0)
	_remove_node(parts.body)


# ----- 2D happy path -----

func test_autofit_2d_rectangle() -> void:
	var parts := _add_body_2d("TestAutofit2DRect", Vector2(32, 48))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "RectangleShape2D")
	assert_true(parts.collision.shape is RectangleShape2D)
	assert_true(parts.collision.shape.size is Vector2)
	assert_eq(parts.collision.shape.size.x, 32.0)
	assert_eq(parts.collision.shape.size.y, 48.0)
	_remove_node(parts.body)


# ----- source auto-detection -----

func test_autofit_no_sibling_visual_errors() -> void:
	# Wrap in a fresh Node3D so the scene root's other children don't leak
	# in as sibling candidates.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var isolated := Node3D.new()
	isolated.name = "IsolatedCollisionHost"
	scene_root.add_child(isolated)
	isolated.set_owner(scene_root)
	var col := CollisionShape3D.new()
	col.name = "LonelyCollision"
	isolated.add_child(col)
	col.set_owner(scene_root)
	var result := _handler.autofit({"path": col.get_path()})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "source_path")
	_remove_node(isolated)


func test_autofit_explicit_source_path() -> void:
	var parts := _add_body_3d("TestAutofitExplicit", Vector3(5, 2, 3))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"source_path": parts.mesh.get_path(),
	})
	assert_has_key(result, "data")
	assert_eq(parts.collision.shape.size.x, 5.0)
	_remove_node(parts.body)
