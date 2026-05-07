@tool
extends McpTestSuite

const PhysicsShapeHandler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")

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


## Build the issue-#263 nested layout under a fresh container:
##   Container
##     <visual_name>(MeshInstance3D, BoxMesh size=mesh_size)*  (one per entry)
##     Body(StaticBody3D)
##       Collision(CollisionShape3D)
## Returns {container, visuals: Array[MeshInstance3D], body, collision} or
## {} when no scene root is open.
func _add_nested_body_3d(container_name: String, visuals: Array) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var container := Node3D.new()
	container.name = container_name
	scene_root.add_child(container)
	container.set_owner(scene_root)
	var visual_nodes: Array[Node] = []
	for v in visuals:
		var mesh := MeshInstance3D.new()
		mesh.name = v.name
		var box := BoxMesh.new()
		box.size = v.size
		mesh.mesh = box
		container.add_child(mesh)
		mesh.set_owner(scene_root)
		visual_nodes.append(mesh)
	var body := StaticBody3D.new()
	body.name = "Body"
	container.add_child(body)
	body.set_owner(scene_root)
	var col := CollisionShape3D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)
	return {"container": container, "visuals": visual_nodes, "body": body, "collision": col}


# ----- validation errors -----

func test_autofit_missing_path() -> void:
	var result := _handler.autofit({})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)


func test_autofit_node_not_found() -> void:
	var result := _handler.autofit({"path": "/Main/NopeNotHere"})
	assert_is_error(result, McpErrorCodes.NODE_NOT_FOUND)


func test_autofit_node_is_not_collision_shape() -> void:
	var result := _handler.autofit({"path": "/Main/Camera3D"})
	assert_is_error(result)
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
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
	_remove_node(parts.body)


# ----- regression #395: shape_type accepts Godot class names -----

func test_autofit_3d_accepts_godot_class_name() -> void:
	# Issue #395: passing the Godot class name (what
	# resource_get_info(type="Shape3D").concrete_subclasses returns)
	# must work the same as the short form.
	var parts := _add_body_3d("TestAutofit3DClassName", Vector3(3, 1, 2))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "BoxShape3D",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "BoxShape3D")
	# Response normalizes to the short form so callers using either input
	# get a stable shape_type echoed back.
	assert_eq(result.data.shape_type, "box")
	assert_true(parts.collision.shape is BoxShape3D)
	assert_eq(parts.collision.shape.size.x, 3.0)
	_remove_node(parts.body)


func test_autofit_2d_accepts_godot_class_name() -> void:
	var parts := _add_body_2d("TestAutofit2DClassName", Vector2(32, 48))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "RectangleShape2D",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "RectangleShape2D")
	assert_eq(result.data.shape_type, "rectangle")
	assert_true(parts.collision.shape is RectangleShape2D)
	assert_eq(parts.collision.shape.size.x, 32.0)
	assert_eq(parts.collision.shape.size.y, 48.0)
	_remove_node(parts.body)


func test_autofit_3d_rejects_2d_class_name() -> void:
	# Cross-dim class names must still error: RectangleShape2D for a
	# CollisionShape3D is invalid even though the class exists.
	var parts := _add_body_3d("TestAutofit3DCrossDim", Vector3(1, 1, 1))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "RectangleShape2D",
	})
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
	# Error message lists both short and class-name forms so the next
	# attempt can pick a valid one.
	assert_contains(result.error.message, "BoxShape3D")
	assert_contains(result.error.message, "box")
	_remove_node(parts.body)


func test_autofit_3d_rejects_unknown_class_name() -> void:
	var parts := _add_body_3d("TestAutofit3DUnknownClass", Vector3(1, 1, 1))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "TotallyMadeUpShape3D",
	})
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
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
	assert_true(editor_undo(_undo_redo), "undo should succeed")
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
	# Two-level nesting so neither tier-1 (direct siblings) nor tier-2
	# (parent siblings / uncles) leaks in scene-root-level visuals — e.g.
	# a `ReloadTestCube` left over from `script/ci-reload-test`, which
	# otherwise becomes an uncle of LonelyCollision and makes autofit
	# return data instead of the expected error.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var outer := Node3D.new()
	outer.name = "IsolatedCollisionOuter"
	scene_root.add_child(outer)
	outer.set_owner(scene_root)
	var isolated := Node3D.new()
	isolated.name = "IsolatedCollisionHost"
	outer.add_child(isolated)
	isolated.set_owner(scene_root)
	var col := CollisionShape3D.new()
	col.name = "LonelyCollision"
	isolated.add_child(col)
	col.set_owner(scene_root)
	var result := _handler.autofit({"path": col.get_path()})
	assert_is_error(result)
	assert_contains(result.error.message, "source_path")
	_remove_node(outer)


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


# ----- nested layout: visual is a parent-sibling, not a direct sibling -----

func test_autofit_3d_finds_uncle_mesh_in_nested_body_layout() -> void:
	# Issue #263: visual is a sibling of the body, not of the collision shape.
	var parts := _add_nested_body_3d("TestNestedAutofit3D", [{"name": "Visual", "size": Vector3(7, 3, 5)}])
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_eq(result.data.shape_class, "BoxShape3D")
	assert_true(parts.collision.shape is BoxShape3D)
	assert_eq(parts.collision.shape.size.x, 7.0)
	assert_eq(parts.collision.shape.size.y, 3.0)
	assert_eq(parts.collision.shape.size.z, 5.0)
	assert_true(result.data.source_path.ends_with("/Visual"), "source_path should resolve to the uncle visual")
	_remove_node(parts.container)


func test_autofit_3d_ambiguous_uncles_lists_candidates() -> void:
	# Two measurable uncles → no auto-pick; error must list candidate
	# scene paths in error.data.candidates so the agent can pick one.
	var parts := _add_nested_body_3d("TestAmbiguousAutofit3D", [
		{"name": "VisualA", "size": Vector3(1, 1, 1)},
		{"name": "VisualB", "size": Vector3(1, 1, 1)},
	])
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_is_error(result)
	assert_contains(result.error.message, "Multiple visual candidates")
	assert_contains(result.error.message, "source_path")
	assert_has_key(result.error, "data")
	var candidates: Array = result.error.data.get("candidates", [])
	assert_eq(candidates.size(), 2)
	var joined := ", ".join(candidates)
	assert_true(joined.contains("/VisualA"), "candidates should include VisualA path")
	assert_true(joined.contains("/VisualB"), "candidates should include VisualB path")
	_remove_node(parts.container)


func test_autofit_3d_uncle_search_skips_lights() -> void:
	# Tier 2 must reject Light3D — DirectionalLight3D extends
	# VisualInstance3D and would silently produce a huge collider. The
	# stricter GeometryInstance3D filter is what prevents it.
	var parts := _add_nested_body_3d("TestLightOnlyAutofit3D", [])
	if parts.is_empty():
		skip("No scene root")
		return
	var light := OmniLight3D.new()
	light.name = "OnlyLight"
	parts.container.add_child(light)
	light.set_owner(EditorInterface.get_edited_scene_root())
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_is_error(result)
	assert_contains(result.error.message, "source_path")
	_remove_node(parts.container)


func test_autofit_2d_finds_uncle_sprite_in_nested_body_layout() -> void:
	# 2D variant of the nested-body layout from issue #263.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var container := Node2D.new()
	container.name = "TestNestedAutofit2D"
	scene_root.add_child(container)
	container.set_owner(scene_root)
	var sprite := Sprite2D.new()
	sprite.name = "Visual"
	var img := Image.create(40, 24, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	sprite.texture = ImageTexture.create_from_image(img)
	container.add_child(sprite)
	sprite.set_owner(scene_root)
	var body := StaticBody2D.new()
	body.name = "Body"
	container.add_child(body)
	body.set_owner(scene_root)
	var col := CollisionShape2D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)

	var result := _handler.autofit({"path": col.get_path()})
	assert_has_key(result, "data")
	assert_true(col.shape is RectangleShape2D)
	assert_eq(col.shape.size.x, 40.0)
	assert_eq(col.shape.size.y, 24.0)
	assert_true(result.data.source_path.ends_with("/Visual"))
	_remove_node(container)


# ----- regression: capsule silent clamp (height >= 2*radius) -----

func test_autofit_3d_capsule_reports_actual_stored_values_after_clamp() -> void:
	# Wide-short source: 4×1×4 mesh. Naive code would try radius=2, height=1,
	# but CapsuleShape3D enforces height >= 2*radius and silently clamps.
	# The response must reflect what Godot actually stored, not what we asked.
	var parts := _add_body_3d("TestAutofitCapsuleClamp", Vector3(4, 1, 4))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "capsule",
	})
	assert_has_key(result, "data")
	var cap: CapsuleShape3D = parts.collision.shape
	assert_true(cap != null)
	# Regression: response.size.{radius,height} must equal cap.{radius,height}
	# after Godot's clamp. If this assertion fires with mismatched values,
	# the tool was lying about what it stored.
	assert_eq(result.data.size.radius, cap.radius)
	assert_eq(result.data.size.height, cap.height)
	# Invariant Godot enforces: height >= 2*radius
	assert_true(cap.height >= 2.0 * cap.radius, "CapsuleShape3D invariant must hold")
	_remove_node(parts.body)


func test_autofit_2d_capsule_reports_actual_stored_values_after_clamp() -> void:
	var parts := _add_body_2d("TestAutofit2DCapsuleClamp", Vector2(100, 20))
	if parts.is_empty():
		skip("No scene root")
		return
	var result := _handler.autofit({
		"path": parts.collision.get_path(),
		"shape_type": "capsule",
	})
	assert_has_key(result, "data")
	var cap: CapsuleShape2D = parts.collision.shape
	assert_true(cap != null)
	assert_eq(result.data.size.radius, cap.radius)
	assert_eq(result.data.size.height, cap.height)
	assert_true(cap.height >= 2.0 * cap.radius, "CapsuleShape2D invariant must hold")
	_remove_node(parts.body)


# ----- regression: _measure_bounds must honor source scale -----

func test_autofit_3d_honors_source_scale() -> void:
	# Unit mesh scaled by (2,2,2) — the collider should match the visible
	# 2×2×2 volume, not the 1×1×1 local AABB.
	var parts := _add_body_3d("TestAutofitScaled3D", Vector3(1, 1, 1))
	if parts.is_empty():
		skip("No scene root")
		return
	(parts.mesh as MeshInstance3D).scale = Vector3(2, 2, 2)
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_true(parts.collision.shape is BoxShape3D)
	assert_eq(parts.collision.shape.size.x, 2.0, "Scaled source must produce 2-unit collider")
	assert_eq(parts.collision.shape.size.y, 2.0)
	assert_eq(parts.collision.shape.size.z, 2.0)
	_remove_node(parts.body)


func test_autofit_2d_sprite_honors_source_scale() -> void:
	var parts := _add_body_2d("TestAutofitScaled2D", Vector2(32, 32))
	if parts.is_empty():
		skip("No scene root")
		return
	(parts.sprite as Sprite2D).scale = Vector2(2, 2)
	var result := _handler.autofit({"path": parts.collision.get_path()})
	assert_has_key(result, "data")
	assert_true(parts.collision.shape is RectangleShape2D)
	assert_eq(parts.collision.shape.size.x, 64.0, "Scaled Sprite2D should yield 64px width")
	assert_eq(parts.collision.shape.size.y, 64.0)
	_remove_node(parts.body)


# ----- regression: TextureRect with zero layout size -----

func test_autofit_2d_texture_rect_zero_size_falls_back_to_texture() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := StaticBody2D.new()
	body.name = "TestTexRectFallback"
	scene_root.add_child(body)
	body.set_owner(scene_root)

	var tr := TextureRect.new()
	tr.name = "Visual"
	# Intentionally leave size = (0, 0) — this is what you'd see just after
	# creating the node via MCP before any layout pass has run.
	var img := Image.create(24, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	tr.texture = ImageTexture.create_from_image(img)
	body.add_child(tr)
	tr.set_owner(scene_root)

	var col := CollisionShape2D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)

	var result := _handler.autofit({"path": col.get_path()})
	assert_has_key(result, "data")
	assert_true(col.shape is RectangleShape2D)
	# Should fall back to texture.get_size() = (24, 48), NOT silently produce zero.
	assert_eq(col.shape.size.x, 24.0)
	assert_eq(col.shape.size.y, 48.0)
	_remove_node(body)


func test_autofit_2d_texture_rect_zero_size_no_texture_errors() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var body := StaticBody2D.new()
	body.name = "TestTexRectNoTex"
	scene_root.add_child(body)
	body.set_owner(scene_root)

	var tr := TextureRect.new()
	tr.name = "Visual"  # no texture assigned, no size
	body.add_child(tr)
	tr.set_owner(scene_root)

	var col := CollisionShape2D.new()
	col.name = "Collision"
	body.add_child(col)
	col.set_owner(scene_root)

	var result := _handler.autofit({"path": col.get_path()})
	assert_is_error(result)
	assert_contains(result.error.message, "zero")
	_remove_node(body)
