@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

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
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_autofit_node_not_found() -> void:
	var result := _handler.autofit({"path": "/Main/NopeNotHere"})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


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
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
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
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
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
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
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


# ----- physics_shape_generate -----

func _add_generate_mesh(
	mesh_name: String,
	mesh_size: Vector3,
	mesh_scale := Vector3.ONE,
) -> MeshInstance3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var mesh := MeshInstance3D.new()
	mesh.name = mesh_name
	var box := BoxMesh.new()
	box.size = mesh_size
	mesh.mesh = box
	mesh.scale = mesh_scale
	scene_root.add_child(mesh)
	mesh.set_owner(scene_root)
	return mesh


func _find_named_child(parent: Node, child_name: String) -> Node:
	for child in parent.get_children():
		if child.name == child_name:
			return child
	return null


func _generated_nodes(result: Dictionary, scene_root: Node) -> Dictionary:
	var entry: Dictionary = result.data.created[0]
	return {
		"body": McpScenePath.resolve(entry.body_path, scene_root),
		"collision": McpScenePath.resolve(entry.shape_path, scene_root),
	}


func test_generate_static_box_defaults() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateStatic", Vector3(2, 1, 3))
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	assert_eq(result.data.created.size(), 1)
	assert_eq(result.data.created[0].shape_type, "box")
	assert_eq(result.data.created[0].body_type, "static")
	var nodes := _generated_nodes(result, scene_root)
	assert_true(nodes.body is StaticBody3D)
	assert_true(nodes.collision is CollisionShape3D)
	assert_true(nodes.collision.shape is BoxShape3D)
	assert_eq(nodes.collision.shape.size, Vector3(2, 1, 3))
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_area_body() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateArea", Vector3.ONE)
	var result := _handler.generate({
		"paths": [McpScenePath.from_node(mesh, scene_root)],
		"body_type": "area",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.created[0].body_type, "area")
	var nodes := _generated_nodes(result, scene_root)
	assert_true(nodes.body is Area3D)
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_supports_every_shape_type() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var cases := {
		"box": "BoxShape3D",
		"sphere": "SphereShape3D",
		"capsule": "CapsuleShape3D",
		"cylinder": "CylinderShape3D",
	}
	for shape_type in cases:
		var mesh := _add_generate_mesh("Generate%s" % shape_type.capitalize(), Vector3(2, 4, 2))
		var result := _handler.generate({
			"paths": [McpScenePath.from_node(mesh, scene_root)],
			"shape_type": shape_type,
		})
		assert_has_key(result, "data")
		assert_eq(result.data.created[0].shape_type, shape_type)
		var nodes := _generated_nodes(result, scene_root)
		assert_eq(nodes.collision.shape.get_class(), cases[shape_type])
		if shape_type == "box":
			assert_eq(nodes.collision.shape.size, Vector3(2, 4, 2))
		elif shape_type == "sphere":
			assert_eq(nodes.collision.shape.radius, 2.0)
		else:
			assert_eq(nodes.collision.shape.radius, 1.0)
			assert_eq(nodes.collision.shape.height, 4.0)
		_remove_node(nodes.body)
		_remove_node(mesh)


func test_generate_rotated_scaled_mesh_uses_body_local_bounds() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateRotated", Vector3(2, 1, 4), Vector3(2, 1, 0.5))
	mesh.rotation_degrees = Vector3(15, 45, 10)
	mesh.position = Vector3(4, 2, -1)
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	var nodes := _generated_nodes(result, scene_root)
	assert_eq(nodes.body.transform.origin, mesh.transform.origin)
	assert_true(nodes.body.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
		"generated body must not copy mesh scale")
	var size: Vector3 = nodes.collision.shape.size
	assert_true(size.is_equal_approx(Vector3(4, 1, 2)),
		"rotated mesh bounds must be measured in body-local space")
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_negative_scale_produces_positive_bounds() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateNegativeScale", Vector3.ONE, Vector3(-2, 3, 4))
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	var nodes := _generated_nodes(result, scene_root)
	assert_true(nodes.collision.shape.size.is_equal_approx(Vector3(2, 3, 4)))
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_centers_offset_mesh_geometry() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := MeshInstance3D.new()
	mesh.name = "GenerateOffsetGeometry"
	var vertices := PackedVector3Array([
		Vector3(1, 2, 3), Vector3(3, 2, 3), Vector3(3, 5, 7),
		Vector3(1, 2, 3), Vector3(3, 5, 7), Vector3(1, 5, 7),
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.mesh = array_mesh
	scene_root.add_child(mesh)
	mesh.set_owner(scene_root)
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	var nodes := _generated_nodes(result, scene_root)
	assert_true(nodes.collision.position.is_equal_approx(Vector3(2, 3.5, 5)))
	assert_true(nodes.collision.shape.size.is_equal_approx(Vector3(2, 3, 4)))
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_bulk_is_one_undo_redo_action() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var first := _add_generate_mesh("GenerateBulkA", Vector3.ONE)
	var second := _add_generate_mesh("GenerateBulkB", Vector3.ONE)
	var result := _handler.generate({"paths": [
		McpScenePath.from_node(first, scene_root),
		McpScenePath.from_node(second, scene_root),
	]})
	assert_has_key(result, "data")
	assert_eq(result.data.created.size(), 2)
	var first_body := McpScenePath.resolve(result.data.created[0].body_path, scene_root)
	var second_body := McpScenePath.resolve(result.data.created[1].body_path, scene_root)
	assert_true(first_body is StaticBody3D)
	assert_true(second_body is StaticBody3D)
	assert_true(editor_undo(_undo_redo), "bulk undo should succeed")
	assert_true(first_body.get_parent() == null)
	assert_true(second_body.get_parent() == null)
	assert_true(editor_redo(_undo_redo), "bulk redo should succeed")
	assert_eq(first_body.get_parent(), scene_root)
	assert_eq(second_body.get_parent(), scene_root)
	_remove_node(first_body)
	_remove_node(second_body)
	_remove_node(first)
	_remove_node(second)


func test_generate_prevalidates_entire_batch() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateAllOrNothing", Vector3.ONE)
	var result := _handler.generate({"paths": [
		McpScenePath.from_node(mesh, scene_root),
		"/Main/DefinitelyMissingGenerateMesh",
	]})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)
	assert_true(_find_named_child(scene_root, "GenerateAllOrNothingCollider") == null,
		"a later invalid path must leave the valid prefix untouched")
	_remove_node(mesh)


func test_generate_rejects_invalid_options_before_mutation() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateBadOptions", Vector3.ONE)
	var path := McpScenePath.from_node(mesh, scene_root)
	var bad_shape := _handler.generate({"paths": [path], "shape_type": "convex"})
	assert_is_error(bad_shape, ErrorCodes.VALUE_OUT_OF_RANGE)
	var bad_body := _handler.generate({"paths": [path], "body_type": "rigid"})
	assert_is_error(bad_body, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(_find_named_child(scene_root, "GenerateBadOptionsCollider") == null)
	_remove_node(mesh)


func test_generate_rejects_empty_non_array_and_non_mesh_paths() -> void:
	var empty := _handler.generate({"paths": []})
	assert_is_error(empty, ErrorCodes.MISSING_REQUIRED_PARAM)
	var non_array := _handler.generate({"paths": "/Main/Mesh"})
	assert_is_error(non_array, ErrorCodes.INVALID_PARAMS)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var plain := Node3D.new()
	plain.name = "GenerateNotMesh"
	scene_root.add_child(plain)
	plain.set_owner(scene_root)
	var wrong_type := _handler.generate({"paths": [McpScenePath.from_node(plain, scene_root)]})
	assert_is_error(wrong_type, ErrorCodes.WRONG_TYPE)
	_remove_node(plain)
