@tool
extends McpTestSuite

signal generate_driver_frame

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")

const PhysicsShapeHandler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")

## Tests for PhysicsShapeHandler — autofit CollisionShape* to sibling bounds.

var _handler: PhysicsShapeHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "physics_shape"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	if _undo_redo != null:
		_undo_redo.clear_history()
	_handler = PhysicsShapeHandler.new(_undo_redo)


func teardown() -> void:
	## Generated bodies are committed as editor actions. Release each test's
	## history so a later undo cannot resurrect a collider removed by cleanup.
	if _undo_redo != null:
		_undo_redo.clear_history()


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


func _add_generate_mesh_with_mesh(mesh_name: String, mesh_resource: Mesh) -> MeshInstance3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var mesh := MeshInstance3D.new()
	mesh.name = mesh_name
	mesh.mesh = mesh_resource
	scene_root.add_child(mesh)
	mesh.set_owner(scene_root)
	return mesh


## The AABB spanned by a hull's points, so a baked scale can be asserted
## against the world-space mesh bounds.
func _points_aabb(points: PackedVector3Array) -> AABB:
	var aabb := AABB(points[0], Vector3.ZERO)
	for point in points:
		aabb = aabb.expand(point)
	return aabb


## A wavy triangle-grid ArrayMesh with exactly `triangles` faces, for the hull
## triangle-bound regression. Preallocated and generated in one pass so an
## over-cap mesh stays cheap to build.
func _grid_mesh(triangles: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	vertices.resize(triangles * 3)
	var index := 0
	for i in triangles:
		var x := float(i % 200)
		var y := float(i / 200)
		vertices[index] = Vector3(x, sin(x * 0.5) * cos(y * 0.5) * 0.5, y)
		vertices[index + 1] = Vector3(x + 1.0, sin((x + 1.0) * 0.5) * cos(y * 0.5) * 0.5, y)
		vertices[index + 2] = Vector3(x, sin(x * 0.5) * cos((y + 1.0) * 0.5) * 0.5, y + 1.0)
		index += 3
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Signed volume of a triangle soup: one winding gives a positive result, its
## mirror a negative one. Comparing two generations of the same mesh avoids
## hard-coding Godot's winding convention in the assertion.
func _trimesh_signed_volume(faces: PackedVector3Array) -> float:
	var volume := 0.0
	for index in range(0, faces.size(), 3):
		volume += faces[index].cross(faces[index + 1]).dot(faces[index + 2])
	return volume / 6.0


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


func test_generate_supports_convex_and_trimesh_shapes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var torus := TorusMesh.new()
	torus.inner_radius = 0.5
	torus.outer_radius = 1.5
	torus.rings = 8
	torus.ring_segments = 8
	var unsupported := PhysicsShapeHandler._validate_hull_workload(torus, "/Torus", "convex")
	assert_is_error(unsupported, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(unsupported.error.message, "no bounded geometry preflight")
	var baked := ArrayMesh.new()
	baked.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, torus.get_mesh_arrays())
	var mesh := _add_generate_mesh_with_mesh("GenerateTorusHull", baked)
	var path := McpScenePath.from_node(mesh, scene_root)
	var convex := _handler.generate({"paths": [path], "shape_type": "convex"})
	assert_has_key(convex, "data")
	assert_eq(convex.data.created[0].shape_type, "convex")
	var convex_nodes := _generated_nodes(convex, scene_root)
	var hull: ConvexPolygonShape3D = convex_nodes.collision.shape
	assert_true(hull is ConvexPolygonShape3D)
	assert_true(hull.points.size() >= 4, "a convex hull must have points")
	assert_true(
		convex_nodes.collision.transform.is_equal_approx(Transform3D.IDENTITY),
		"hull vertices carry the mesh transform, the collision node stays identity"
	)
	assert_true(
		_points_aabb(hull.points).size.is_equal_approx(torus.get_aabb().size),
		"the hull must span the mesh's own bounds"
	)
	_remove_node(convex_nodes.body)

	var trimesh := _handler.generate({"paths": [path], "shape_type": "trimesh"})
	assert_has_key(trimesh, "data")
	assert_eq(trimesh.data.created[0].shape_type, "trimesh")
	var trimesh_nodes := _generated_nodes(trimesh, scene_root)
	var concave: ConcavePolygonShape3D = trimesh_nodes.collision.shape
	assert_true(concave is ConcavePolygonShape3D)
	assert_true(concave.get_faces().size() > 0, "a trimesh needs faces")
	assert_true(trimesh_nodes.collision.transform.is_equal_approx(Transform3D.IDENTITY))
	_remove_node(trimesh_nodes.body)
	_remove_node(mesh)


func test_generate_bakes_mesh_scale_into_hull_and_trimesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateScaledHull", Vector3(2, 1, 3), Vector3(2, 1, 0.5))
	var path := McpScenePath.from_node(mesh, scene_root)
	for shape_type in ["convex", "trimesh"]:
		var result := _handler.generate({"paths": [path], "shape_type": shape_type})
		assert_has_key(result, "data")
		var nodes := _generated_nodes(result, scene_root)
		assert_true(
			nodes.collision.transform.is_equal_approx(Transform3D.IDENTITY),
			"baked vertices must leave the collision transform at identity"
		)
		var aabb: AABB
		if shape_type == "convex":
			aabb = _points_aabb((nodes.collision.shape as ConvexPolygonShape3D).points)
		else:
			aabb = _points_aabb((nodes.collision.shape as ConcavePolygonShape3D).get_faces())
		assert_true(
			aabb.size.is_equal_approx(Vector3(4, 1, 1.5)),
			"the mesh's own scale must be baked into the %s vertices" % shape_type
		)
		_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_mirrored_trimesh_restores_winding() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var upright := _add_generate_mesh("GenerateWindingBase", Vector3(2, 1, 3))
	var mirrored := _add_generate_mesh("GenerateWindingMirror", Vector3(2, 1, 3), Vector3(-1, 1, 1))
	var base := _handler.generate({
		"paths": [McpScenePath.from_node(upright, scene_root)],
		"shape_type": "trimesh",
	})
	assert_has_key(base, "data")
	var mirrored_result := _handler.generate({
		"paths": [McpScenePath.from_node(mirrored, scene_root)],
		"shape_type": "trimesh",
	})
	assert_has_key(mirrored_result, "data")
	var base_nodes := _generated_nodes(base, scene_root)
	var mirrored_nodes := _generated_nodes(mirrored_result, scene_root)
	var base_faces: PackedVector3Array = (base_nodes.collision.shape as ConcavePolygonShape3D).get_faces()
	var mirrored_faces: PackedVector3Array = (mirrored_nodes.collision.shape as ConcavePolygonShape3D).get_faces()
	var base_volume := _trimesh_signed_volume(base_faces)
	var mirrored_volume := _trimesh_signed_volume(mirrored_faces)
	assert_true(
		signf(base_volume) == signf(mirrored_volume),
		"a mirrored mesh must keep its triangle winding (base %f, mirrored %f)" % [base_volume, mirrored_volume]
	)
	assert_true(
		absf(absf(base_volume) - absf(mirrored_volume)) < 0.001,
		"mirroring must preserve the collider volume (base %f, mirrored %f)" % [base_volume, mirrored_volume]
	)
	_remove_node(base_nodes.body)
	_remove_node(mirrored_nodes.body)
	_remove_node(upright)
	_remove_node(mirrored)


func test_generate_faceless_preflight_allocates_no_nodes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	## Apply-time preflight must refuse faceless geometry before allocating
	## the body or collision node, even when called directly with a plan.
	var mesh := _add_generate_mesh_with_mesh("GenerateDegenerateHull", PointMesh.new())
	var plan := {
		"mesh": mesh,
		"mesh_path": McpScenePath.from_node(mesh, scene_root),
		"parent": scene_root,
		"collider_name": "GenerateDegenerateHullCollider",
		"top_level": false,
		"source_transform": mesh.transform,
		"body_transform": mesh.transform,
		"mesh_to_body": Transform3D.IDENTITY,
		"bounds": AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE),
	}
	var before := Node.get_orphan_node_ids()
	## Prove the orphan diff sees detached nodes before trusting it below.
	var probe := Node3D.new()
	var probe_id := probe.get_instance_id()
	assert_true(probe_id in Node.get_orphan_node_ids(), "a detached node must be an orphan")
	probe.free()
	assert_false(probe_id in Node.get_orphan_node_ids(), "a freed node must leave the orphan list")
	var entry := PhysicsShapeHandler._create_generated_entry(plan, "trimesh", "static", false)
	assert_true(entry.has("error"), "a faceless mesh cannot produce a trimesh")
	assert_contains(entry.error.message, "no faces")
	var leaked: Array = []
	for orphan_id in Node.get_orphan_node_ids():
		if orphan_id not in before:
			leaked.append(orphan_id)
	assert_true(
		leaked.is_empty(),
		"faceless preflight must allocate no detached nodes (leaked %d)" % leaked.size()
	)
	assert_true(_find_named_child(scene_root, "GenerateDegenerateHullCollider") == null)
	_remove_node(mesh)


func test_generate_supports_rigid_and_character_bodies() -> void:
	## A dynamic body must own its visual: the default wraps the mesh under the
	## generated body, so the physics step that moves the body carries the mesh
	## (a detached sibling body falls away from the stationary visual).
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var cases := {"rigid": "RigidBody3D", "character": "CharacterBody3D"}
	for body_type in cases:
		var mesh := _add_generate_mesh("GenerateBody%s" % body_type.capitalize(), Vector3(2, 1, 3))
		mesh.rotation_degrees = Vector3(0, 30, 0)
		mesh.position = Vector3(1, 2, 3)
		var world_before := mesh.global_transform
		var result := _handler.generate({
			"paths": [McpScenePath.from_node(mesh, scene_root)],
			"body_type": body_type,
		})
		assert_has_key(result, "data")
		assert_eq(result.data.created[0].body_type, body_type)
		var nodes := _generated_nodes(result, scene_root)
		assert_eq(nodes.body.get_class(), cases[body_type])
		assert_eq(mesh.get_parent(), nodes.body, "a dynamic body must wrap its mesh by default")
		assert_true(
			mesh.global_transform.is_equal_approx(world_before),
			"wrapping must preserve the mesh's world transform"
		)
		assert_true(
			nodes.body.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			"the generated body must not copy mesh scale"
		)
		## Move the body the way a physics step would: the visual must follow.
		nodes.body.global_position += Vector3(0, -2.75, 0)
		assert_true(
			mesh.global_transform.origin.is_equal_approx(world_before.origin + Vector3(0, -2.75, 0)),
			"body motion must carry the wrapped mesh"
		)
		assert_true(editor_undo(_undo_redo), "undo should succeed")
		assert_true(
			mesh.global_transform.is_equal_approx(world_before),
			"undo must restore the unwrapped layout"
		)
		assert_true(mesh.get_parent() != nodes.body)
		_remove_node(nodes.body)
		_remove_node(mesh)


func test_generate_rejects_detached_dynamic_bodies() -> void:
	## An explicit reparent_mesh=false would leave a rigid/character body to
	## fall away from the stationary mesh; static/area keep the published
	## sibling default.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateDetachedDynamic", Vector3.ONE)
	var path := McpScenePath.from_node(mesh, scene_root)
	for body_type in ["rigid", "character"]:
		var result := _handler.generate({
			"paths": [path], "body_type": body_type, "reparent_mesh": false,
		})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		assert_contains(result.error.message, "own its visual mesh")
		assert_true(_find_named_child(scene_root, "GenerateDetachedDynamicCollider") == null)
	## A non-boolean flag is a type error, not a truthy coercion.
	var bad_type := _handler.generate({"paths": [path], "reparent_mesh": "false"})
	assert_is_error(bad_type, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_type.error.message, "reparent_mesh")
	## static/area still default to a detached sibling collider.
	var static_ok := _handler.generate({"paths": [path]})
	assert_has_key(static_ok, "data")
	var body := _find_named_child(scene_root, "GenerateDetachedDynamicCollider")
	assert_true(body != null)
	assert_eq(mesh.get_parent(), scene_root, "a static sibling must not wrap the mesh")
	_remove_node(body)
	_remove_node(mesh)


func test_generate_rejects_trimesh_for_moving_bodies() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateTrimeshMoving", Vector3.ONE)
	var path := McpScenePath.from_node(mesh, scene_root)
	for body_type in ["rigid", "character"]:
		var result := _handler.generate({
			"paths": [path], "shape_type": "trimesh", "body_type": body_type,
		})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		assert_contains(result.error.message, "trimesh")
	assert_true(_find_named_child(scene_root, "GenerateTrimeshMovingCollider") == null)
	## A static body still accepts it.
	var static_ok := _handler.generate({"paths": [path], "shape_type": "trimesh"})
	assert_has_key(static_ok, "data")
	_remove_node(_find_named_child(scene_root, "GenerateTrimeshMovingCollider"))
	_remove_node(mesh)


func test_generate_rejects_faceless_meshes_for_hull_and_trimesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh_with_mesh("GenerateFaceless", PointMesh.new())
	var path := McpScenePath.from_node(mesh, scene_root)
	for shape_type in ["convex", "trimesh"]:
		var result := _handler.generate({"paths": [path], "shape_type": shape_type})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		assert_contains(result.error.message, "no faces")
	assert_true(_find_named_child(scene_root, "GenerateFacelessCollider") == null)
	_remove_node(mesh)


func test_generate_faceless_mesh_fails_the_whole_batch() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var good := _add_generate_mesh("GenerateBatchGood", Vector3.ONE)
	var faceless := _add_generate_mesh_with_mesh("GenerateBatchFaceless", PointMesh.new())
	var result := _handler.generate({
		"paths": [
			McpScenePath.from_node(good, scene_root),
			McpScenePath.from_node(faceless, scene_root),
		],
		"shape_type": "convex",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(_find_named_child(scene_root, "GenerateBatchGoodCollider") == null)
	_remove_node(good)
	_remove_node(faceless)


func test_generate_rejects_meshes_over_the_hull_triangle_bound() -> void:
	## Hull/concave work runs synchronously inside one item, so the triangle
	## count is measured during planning and an oversized mesh is refused
	## before any hull build or vertex loop starts.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var cap: int = PhysicsShapeHandler._GENERATE_HULL_MAX_TRIANGLES
	var over := _add_generate_mesh_with_mesh("GenerateHullOver", _grid_mesh(cap + 1))
	var path := McpScenePath.from_node(over, scene_root)
	for shape_type in ["convex", "trimesh"]:
		var result := _handler.generate({"paths": [path], "shape_type": shape_type})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		assert_contains(result.error.message, str(cap))
		assert_true(_find_named_child(scene_root, "GenerateHullOverCollider") == null)
	_remove_node(over)
	## A mesh at the bound still generates.
	var under := _add_generate_mesh_with_mesh("GenerateHullUnder", _grid_mesh(cap))
	var ok := _handler.generate({
		"paths": [McpScenePath.from_node(under, scene_root)], "shape_type": "convex",
	})
	assert_has_key(ok, "data", str(ok.get("error", {})))
	_remove_node(_find_named_child(scene_root, "GenerateHullUnderCollider"))
	_remove_node(under)


func test_generate_rejects_reparent_for_top_level_mesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateTopLevelWrap", Vector3.ONE)
	mesh.top_level = true
	var result := _handler.generate({
		"paths": [McpScenePath.from_node(mesh, scene_root)],
		"reparent_mesh": true,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "top_level")
	assert_true(_find_named_child(scene_root, "GenerateTopLevelWrapCollider") == null)
	_remove_node(mesh)


func test_generate_reparent_mesh_wraps_and_preserves_world_transform() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateWrapped", Vector3(2, 1, 3), Vector3(2, 1, 0.5))
	mesh.rotation_degrees = Vector3(10, 20, 30)
	mesh.position = Vector3(4, 2, -1)
	var world_before := mesh.global_transform
	var result := _handler.generate({
		"paths": [McpScenePath.from_node(mesh, scene_root)],
		"reparent_mesh": true,
	})
	assert_has_key(result, "data")
	var entry: Dictionary = result.data.created[0]
	var body := McpScenePath.resolve(entry.body_path, scene_root)
	assert_eq(mesh.get_parent(), body, "the mesh must move under the generated body")
	assert_eq(body.get_parent(), scene_root)
	assert_true(
		entry.mesh_path.ends_with("/GenerateWrappedCollider/GenerateWrapped"),
		"the reported mesh path must reflect the wrapped layout, got %s" % entry.mesh_path
	)
	assert_true(
		mesh.global_transform.is_equal_approx(world_before),
		"wrapping must preserve the mesh's world transform"
	)
	var collision := McpScenePath.resolve(entry.shape_path, scene_root)
	assert_eq(collision.get_parent(), body)
	assert_true(
		collision.shape.size.is_equal_approx(Vector3(4, 1, 1.5)),
		"the wrapped mesh's scaled bounds must fit the shape, got %s" % collision.shape.size
	)
	_remove_node(body)


func test_generate_reparent_mesh_undo_restores_layout() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var neighbor := _add_generate_mesh("GenerateWrapNeighbor", Vector3.ONE)
	var mesh := _add_generate_mesh("GenerateUndoWrap", Vector3(2, 1, 3))
	var original_parent := mesh.get_parent()
	var original_index := mesh.get_index()
	var original_transform := mesh.transform
	var original_owner := mesh.owner
	var result := _handler.generate({
		"paths": [McpScenePath.from_node(mesh, scene_root)],
		"reparent_mesh": true,
	})
	assert_has_key(result, "data")
	var body := McpScenePath.resolve(result.data.created[0].body_path, scene_root)
	assert_eq(mesh.get_parent(), body)
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(mesh.get_parent(), original_parent, "undo must restore the original parent")
	assert_eq(mesh.get_index(), original_index, "undo must restore the original sibling index")
	assert_true(mesh.transform.is_equal_approx(original_transform), "undo must restore the original transform")
	assert_eq(mesh.owner, original_owner, "undo must restore the original owner")
	assert_true(body.get_parent() == null, "undo must detach the generated body")
	var did_redo := editor_redo(_undo_redo)
	assert_true(did_redo, "redo should succeed")
	assert_eq(mesh.get_parent(), body, "redo must wrap the mesh again")
	_remove_node(body)
	_remove_node(neighbor)


func test_generate_reparent_mesh_rollback_restores_mesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var kept := _add_generate_mesh("GenerateWrapRollbackA", Vector3.ONE)
	var moved := _add_generate_mesh("GenerateWrapRollbackB", Vector3.ONE)
	var original_parent := kept.get_parent()
	var original_index := kept.get_index()
	var original_transform := kept.transform
	var original_owner := kept.owner
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([
		McpScenePath.from_node(kept, scene_root),
		McpScenePath.from_node(moved, scene_root),
	], connection, {"reparent_mesh": true})
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan A")
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan B")
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply A wraps its mesh")
	assert_true(
		kept.get_parent() != null and str(kept.get_parent().name) == "GenerateWrapRollbackACollider",
		"apply must wrap the first mesh before the second one fails"
	)
	moved.position = Vector3(1, 2, 3)
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "the moved mesh fails the request")
	assert_is_error(job.result, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_eq(kept.get_parent(), original_parent, "rollback must unwrap the mesh")
	assert_eq(kept.get_index(), original_index, "rollback must restore the original index")
	assert_true(kept.transform.is_equal_approx(original_transform), "rollback must restore the transform")
	assert_eq(kept.owner, original_owner, "rollback must restore the owner")
	assert_true(_find_named_child(scene_root, "GenerateWrapRollbackACollider") == null)
	_remove_node(kept)
	_remove_node(moved)
	connection.free()


func test_generate_rollback_keeps_mesh_when_original_parent_is_gone() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var parent := Node3D.new()
	parent.name = "GenerateGoneParent"
	scene_root.add_child(parent)
	parent.set_owner(scene_root)
	var mesh := MeshInstance3D.new()
	mesh.name = "GenerateGoneParentMesh"
	var box := BoxMesh.new()
	mesh.mesh = box
	parent.add_child(mesh)
	mesh.set_owner(scene_root)
	var body := StaticBody3D.new()
	body.name = "GenerateGoneParentCollider"
	parent.add_child(body)
	body.set_owner(scene_root)
	## Simulate the wrapped state: the mesh sits under the generated body.
	mesh.reparent(body, true)
	var entry := {
		"mesh": mesh,
		"mesh_local_transform": Transform3D.IDENTITY,
		"parent": parent,
		"body": body,
		"collision": null,
		"reparent_mesh": true,
		"mesh_parent": parent,
		"mesh_index": 0,
		"mesh_transform": mesh.transform,
		"mesh_owner": scene_root,
	}
	## The body moves elsewhere and the captured parent is freed while the
	## deferred job still owns the entry.
	body.reparent(scene_root, true)
	parent.free()
	PhysicsShapeHandler._restore_reparented_mesh(entry)
	assert_eq(
		mesh.get_parent(), scene_root,
		"the mesh must survive under the body's parent when its own parent is gone"
	)
	_remove_node(body)
	assert_true(is_instance_valid(mesh), "the rollback must not free the mesh with the body")
	_remove_node(mesh)


func test_generate_snaps_tiny_collision_offset() -> void:
	assert_eq(
		PhysicsShapeHandler._snap_tiny(Vector3(1.19e-07, -3.0e-07, 0.0)),
		Vector3.ZERO,
		"float noise from AABB centering must snap to zero"
	)
	assert_eq(
		PhysicsShapeHandler._snap_tiny(Vector3(0.5, 0.0, -2.0)),
		Vector3(0.5, 0.0, -2.0),
		"real offsets must survive the snap"
	)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 2.2
	var mesh := _add_generate_mesh_with_mesh("GenerateSnapCapsule", capsule)
	var result := _handler.generate({
		"paths": [McpScenePath.from_node(mesh, scene_root)],
		"shape_type": "capsule",
	})
	assert_has_key(result, "data")
	var nodes := _generated_nodes(result, scene_root)
	assert_eq(nodes.collision.position, Vector3.ZERO, "a centered mesh must yield an exact zero offset")
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_autofit_still_rejects_hull_and_concave_types() -> void:
	var parts := _add_body_3d("TestAutofitHullGuard", Vector3(2, 1, 3))
	if parts.is_empty():
		skip("No scene root")
		return
	for shape_type in ["convex", "trimesh"]:
		var result := _handler.autofit({"path": parts.collision.get_path(), "shape_type": shape_type})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
		assert_contains(result.error.message, "Valid:")
	assert_true(parts.collision.shape == null, "autofit must not touch the shape on a rejected type")
	_remove_node(parts.body)


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
	assert_eq(result.data.created.size(), 1)
	var nodes := _generated_nodes(result, scene_root)
	assert_eq(nodes.body.transform.origin, mesh.transform.origin)
	assert_true(nodes.body.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
		"generated body must not copy mesh scale")
	var size: Vector3 = nodes.collision.shape.size
	assert_true(size.is_equal_approx(Vector3(4, 1, 2)),
		"rotated mesh bounds must be measured in body-local space")
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_top_level_mesh_preserves_global_alignment() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var parent := Node3D.new()
	parent.name = "GenerateTopLevelParent"
	parent.position = Vector3(20, -3, 8)
	parent.rotation_degrees = Vector3(0, 35, 0)
	parent.scale = Vector3(2, 3, 4)
	scene_root.add_child(parent)
	parent.set_owner(scene_root)
	var mesh := MeshInstance3D.new()
	mesh.name = "GenerateTopLevel"
	var box := BoxMesh.new()
	box.size = Vector3(2, 1, 3)
	mesh.mesh = box
	parent.add_child(mesh)
	mesh.set_owner(scene_root)
	mesh.top_level = true
	mesh.global_position = Vector3(4, 5, -6)
	mesh.global_rotation_degrees = Vector3(10, 25, -15)
	mesh.scale = Vector3(2, 1, 0.5)
	var expected_global_transform := mesh.global_transform

	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	assert_eq(result.data.created.size(), 1)
	var nodes := _generated_nodes(result, scene_root)
	assert_true(nodes.body.top_level, "generated body must preserve top_level")
	assert_true(nodes.body.global_position.is_equal_approx(expected_global_transform.origin),
		"generated body must preserve the mesh's global position")
	assert_true(nodes.body.global_transform.basis.get_rotation_quaternion().is_equal_approx(
		expected_global_transform.basis.get_rotation_quaternion()
	), "generated body must preserve the mesh's global rotation")
	assert_true(nodes.collision.shape.size.is_equal_approx(Vector3(4, 1, 1.5)))
	_remove_node(nodes.body)
	_remove_node(parent)


func test_generate_negative_scale_produces_positive_bounds() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateNegativeScale", Vector3.ONE, Vector3(-2, 3, 4))
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)]})
	assert_has_key(result, "data")
	assert_eq(result.data.created.size(), 1)
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
	assert_eq(result.data.created.size(), 1)
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


func test_generate_already_applied_batch_is_one_undo_redo_action() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var first := _add_generate_mesh("GenerateDeferredUndoA", Vector3.ONE)
	var second := _add_generate_mesh("GenerateDeferredUndoB", Vector3.ONE)
	var entries: Array[Dictionary] = []
	for mesh in [first, second]:
		var path := McpScenePath.from_node(mesh, scene_root)
		var planned := PhysicsShapeHandler._plan_generate_mesh(path, "", scene_root, "box", false)
		assert_has_key(planned, "plan")
		var entry := PhysicsShapeHandler._create_generated_entry(planned.plan, "box", "static", false)
		entry.parent.add_child(entry.body, true)
		entry.body.set_owner(scene_root)
		entry.collision.set_owner(scene_root)
		entries.append(entry)

	PhysicsShapeHandler._commit_generated_action(entries, scene_root, _undo_redo, false)
	assert_eq(entries[0].body.get_parent(), scene_root)
	assert_eq(entries[1].body.get_parent(), scene_root)
	assert_true(editor_undo(_undo_redo), "already-applied bulk undo should succeed")
	assert_true(entries[0].body.get_parent() == null)
	assert_true(entries[1].body.get_parent() == null)
	assert_true(editor_redo(_undo_redo), "already-applied bulk redo should succeed")
	assert_eq(entries[0].body.get_parent(), scene_root)
	assert_eq(entries[1].body.get_parent(), scene_root)
	_remove_node(entries[0].body)
	_remove_node(entries[1].body)
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
	var bad_shape := _handler.generate({"paths": [path], "shape_type": "donut"})
	assert_is_error(bad_shape, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_shape.error.message, "convex")
	assert_contains(bad_shape.error.message, "trimesh")
	var bad_body := _handler.generate({"paths": [path], "body_type": "ghost"})
	assert_is_error(bad_body, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(bad_body.error.message, "rigid")
	assert_contains(bad_body.error.message, "character")
	assert_true(_find_named_child(scene_root, "GenerateBadOptionsCollider") == null)
	_remove_node(mesh)


func test_generate_rejects_empty_non_array_and_non_mesh_paths() -> void:
	var empty := _handler.generate({"paths": []})
	assert_is_error(empty, ErrorCodes.MISSING_REQUIRED_PARAM)
	var non_array := _handler.generate({"paths": "/Main/Mesh"})
	assert_is_error(non_array, ErrorCodes.WRONG_TYPE)
	var non_string_entry := _handler.generate({"paths": [42]})
	assert_is_error(non_string_entry, ErrorCodes.WRONG_TYPE)
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


class _CapturingConnection:
	extends McpConnection
	var captured: Array = []

	func send_deferred_response(request_id: String, payload: Dictionary) -> void:
		captured.append({"request_id": request_id, "payload": payload})


class _GoneDispatcher:
	extends RefCounted

	func has_pending_deferred_response(_request_id: String) -> bool:
		return false


class _LateRegistrationDispatcher:
	extends RefCounted
	var registered := false

	func has_pending_deferred_response(_request_id: String) -> bool:
		return registered


func _generate_job_for(paths: Array, connection = null, extra: Dictionary = {}) -> Dictionary:
	var params := {"paths": paths}
	params.merge(extra)
	var validated := PhysicsShapeHandler._validate_generate_request(params)
	assert_has_key(validated, "data")
	return PhysicsShapeHandler._generate_job(validated, _undo_redo, connection, "rid-generate")


func test_generate_rejects_the_scene_root() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var result := _handler.generate({"paths": [McpScenePath.from_node(scene_root, scene_root)]})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "scene root")


func test_generate_rejects_a_mesh_without_a_mesh_resource() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var empty := MeshInstance3D.new()
	empty.name = "GenerateNoMesh"
	scene_root.add_child(empty)
	empty.set_owner(scene_root)
	var result := _handler.generate({"paths": [McpScenePath.from_node(empty, scene_root)]})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)
	assert_contains(result.error.message, "no mesh resource")
	assert_true(_find_named_child(scene_root, "GenerateNoMeshCollider") == null)
	_remove_node(empty)


func test_generate_rejects_duplicate_paths_and_existing_colliders() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateOnce", Vector3.ONE)
	var path := McpScenePath.from_node(mesh, scene_root)
	var duplicate := _handler.generate({"paths": [path, path]})
	assert_is_error(duplicate, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(duplicate.error.message, "twice")
	assert_true(_find_named_child(scene_root, "GenerateOnceCollider") == null)
	var first := _handler.generate({"paths": [path]})
	assert_has_key(first, "data")
	## A retry after a lost reply must not stack a second collider.
	var again := _handler.generate({"paths": [path]})
	assert_is_error(again, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(again.error.message, "already has a collider sibling")
	var colliders := 0
	for child in scene_root.get_children():
		if str(child.name).begins_with("GenerateOnceCollider"):
			colliders += 1
	assert_eq(colliders, 1, "the retry must leave exactly one collider")
	_remove_node(_find_named_child(scene_root, "GenerateOnceCollider"))
	_remove_node(mesh)


func test_generate_refuses_non_uniform_parent_scale_for_round_shapes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var parent := Node3D.new()
	parent.name = "GenerateScaledParent"
	parent.scale = Vector3(1, 2, 1)
	scene_root.add_child(parent)
	parent.set_owner(scene_root)
	var mesh := MeshInstance3D.new()
	mesh.name = "GenerateUnderScaledParent"
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	mesh.mesh = box
	parent.add_child(mesh)
	mesh.set_owner(scene_root)
	var path := McpScenePath.from_node(mesh, scene_root)
	var sphere := _handler.generate({"paths": [path], "shape_type": "sphere"})
	assert_is_error(sphere, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(sphere.error.message, "non-uniformly")
	assert_true(_find_named_child(parent, "GenerateUnderScaledParentCollider") == null)
	## Hull and concave shapes inherit the parent chain's scale too.
	var trimesh := _handler.generate({"paths": [path], "shape_type": "trimesh"})
	assert_is_error(trimesh, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(trimesh.error.message, "non-uniformly")
	## A box inherits the parent's scale exactly like the mesh does.
	var boxed := _handler.generate({"paths": [path], "shape_type": "box"})
	assert_has_key(boxed, "data")
	_remove_node(_find_named_child(parent, "GenerateUnderScaledParentCollider"))
	## A uniform parent scale keeps a sphere a sphere.
	parent.scale = Vector3(2, 2, 2)
	var uniform := _handler.generate({"paths": [path], "shape_type": "sphere"})
	assert_has_key(uniform, "data")
	_remove_node(parent)


func test_generate_job_applies_one_item_per_step_and_replies_once() -> void:
	## The production path: a deferred request advances one editor frame at a
	## time. A zero budget makes each step do exactly one item.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var first := _add_generate_mesh("GenerateJobA", Vector3.ONE)
	var second := _add_generate_mesh("GenerateJobB", Vector3.ONE)
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([
		McpScenePath.from_node(first, scene_root), McpScenePath.from_node(second, scene_root),
	], connection)
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan A")
	assert_eq(job.plans.size(), 1)
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan B")
	assert_eq(job.plans.size(), 2)
	assert_true(_find_named_child(scene_root, "GenerateJobACollider") == null, "planning mutates nothing")
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply A")
	assert_true(_find_named_child(scene_root, "GenerateJobACollider") != null)
	assert_true(_find_named_child(scene_root, "GenerateJobBCollider") == null)
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "apply B and commit")
	assert_has_key(job.result, "data")
	assert_eq(job.result.data.created.size(), 2)
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "a finished job stays finished")
	var body_a := _find_named_child(scene_root, "GenerateJobACollider")
	var body_b := _find_named_child(scene_root, "GenerateJobBCollider")
	assert_true(editor_undo(_undo_redo), "the deferred batch is one undo action")
	assert_true(body_a.get_parent() == null and body_b.get_parent() == null)
	assert_true(editor_redo(_undo_redo))
	assert_eq(body_a.get_parent(), scene_root)
	_remove_node(body_a)
	_remove_node(body_b)
	_remove_node(first)
	_remove_node(second)
	connection.free()


func test_generate_job_revalidates_each_mesh_when_it_is_applied() -> void:
	## Plan-time state is never applied blindly: a mesh removed, moved or
	## reparented between planning and applying fails the whole request and
	## rolls back the bodies already added.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var kept := _add_generate_mesh("GenerateStaleKept", Vector3.ONE)
	var moved := _add_generate_mesh("GenerateStaleMoved", Vector3.ONE)
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([
		McpScenePath.from_node(kept, scene_root), McpScenePath.from_node(moved, scene_root),
	], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	PhysicsShapeHandler._generate_step(job, 0)
	assert_eq(str(job.phase), "apply")
	moved.position = Vector3(1, 2, 3)
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply the untouched mesh")
	assert_true(_find_named_child(scene_root, "GenerateStaleKeptCollider") != null)
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "the moved mesh fails the request")
	assert_is_error(job.result, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_contains(job.result.error.message, "moved")
	assert_true(_find_named_child(scene_root, "GenerateStaleKeptCollider") == null, "rolled back")
	assert_true(_find_named_child(scene_root, "GenerateStaleMovedCollider") == null)

	var removed := _add_generate_mesh("GenerateStaleRemoved", Vector3.ONE)
	var removed_job := _generate_job_for([
		McpScenePath.from_node(kept, scene_root), McpScenePath.from_node(removed, scene_root),
	], connection)
	PhysicsShapeHandler._generate_step(removed_job, 0)
	PhysicsShapeHandler._generate_step(removed_job, 0)
	_remove_node(removed)
	PhysicsShapeHandler._generate_step(removed_job, 0)
	assert_true(PhysicsShapeHandler._generate_step(removed_job, 0))
	assert_is_error(removed_job.result, ErrorCodes.NODE_NOT_FOUND)
	assert_true(_find_named_child(scene_root, "GenerateStaleKeptCollider") == null, "rolled back")
	_remove_node(kept)
	_remove_node(moved)
	connection.free()


func test_generate_job_frees_a_planned_mesh_without_script_errors() -> void:
	## A mesh freed (not merely removed) between planning and applying must be
	## reported through the stale check. Assigning it to a typed local first
	## raises "invalid previously freed instance" and never reaches the check.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var kept := _add_generate_mesh("GenerateFreedMeshKept", Vector3.ONE)
	var doomed := _add_generate_mesh("GenerateFreedMeshDoomed", Vector3.ONE)
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([
		McpScenePath.from_node(kept, scene_root), McpScenePath.from_node(doomed, scene_root),
	], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	PhysicsShapeHandler._generate_step(job, 0)
	assert_eq(str(job.phase), "apply")
	scene_root.remove_child(doomed)
	doomed.free()
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply the untouched mesh")
	assert_true(_find_named_child(scene_root, "GenerateFreedMeshKeptCollider") != null)
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "the freed mesh fails the request")
	assert_is_error(job.result, ErrorCodes.NODE_NOT_FOUND)
	assert_contains(job.result.error.message, "was removed")
	assert_true(_find_named_child(scene_root, "GenerateFreedMeshKeptCollider") == null, "rolled back")
	_remove_node(kept)
	connection.free()


func test_generate_job_frees_a_planned_parent_without_script_errors() -> void:
	## The captured parent can be freed while the mesh survives because it was
	## reparented away. The stale check must report the reparent, not raise on
	## the typed parent local.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var wrapper := Node3D.new()
	wrapper.name = "GenerateFreedParent"
	scene_root.add_child(wrapper)
	wrapper.set_owner(scene_root)
	var mesh := MeshInstance3D.new()
	mesh.name = "GenerateFreedParentMesh"
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mesh.mesh = box
	wrapper.add_child(mesh)
	mesh.set_owner(scene_root)
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([McpScenePath.from_node(mesh, scene_root)], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	assert_eq(str(job.phase), "apply")
	wrapper.remove_child(mesh)
	scene_root.add_child(mesh)
	mesh.set_owner(scene_root)
	scene_root.remove_child(wrapper)
	wrapper.free()
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "the freed parent fails the request")
	assert_is_error(job.result, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_contains(job.result.error.message, "reparented")
	assert_true(_find_named_child(scene_root, "GenerateFreedParentMeshCollider") == null)
	_remove_node(mesh)
	connection.free()


func test_generate_job_abandoned_by_the_dispatcher_leaves_nothing_behind() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("GenerateAbandoned", Vector3.ONE)
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([McpScenePath.from_node(mesh, scene_root)], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	connection.dispatcher = _GoneDispatcher.new()
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "an abandoned request ends")
	assert_true(job.result.is_empty(), "nothing is answered")
	assert_true(_find_named_child(scene_root, "GenerateAbandonedCollider") == null)
	_remove_node(mesh)
	connection.free()


func test_generate_bounds_direct_and_total_batch_sizes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var direct_paths: Array[String] = []
	for index in range(PhysicsShapeHandler._GENERATE_DIRECT_MAX_PATHS + 1):
		direct_paths.append("/Main/DirectGenerate%d" % index)
	var direct_result := _handler.generate({"paths": direct_paths})
	assert_is_error(direct_result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(direct_result.error.message, "batch_execute")

	var oversized_paths: Array[String] = []
	for index in range(PhysicsShapeHandler._GENERATE_MAX_PATHS + 1):
		oversized_paths.append("/Main/OversizedGenerate%d" % index)
	var oversized_result := _handler.generate({"paths": oversized_paths})
	assert_is_error(oversized_result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(oversized_result.error.message, "at most")


func test_generate_driver_disconnect_rolls_back_and_releases_script_work() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var first := _add_generate_mesh("DriverDisconnectA", Vector3.ONE)
	var second := _add_generate_mesh("DriverDisconnectB", Vector3.ONE)
	var connection := _CapturingConnection.new()
	root.add_child(connection)
	connection.set_process(false)
	var job := _generate_job_for([McpScenePath.from_node(first, root), McpScenePath.from_node(second, root)], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	PhysicsShapeHandler._generate_step(job, 0)
	assert_false(PhysicsShapeHandler._generate_step(job, 0))
	assert_eq(job.created.size(), 1, "disconnect must interrupt actual partial mutation")
	PhysicsShapeHandler._drive_generate_job(job, connection, generate_driver_frame)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 1, "worker is tracked before the first yield")
	root.remove_child(connection)
	connection.free()
	## The rollback waits for the next driven frame: running it from the
	## connection's tree_exiting would call remove_child() on a parent that is
	## still removing children, then free a still parented body, corrupting the
	## scene tree.
	assert_eq(job.created.size(), 1, "nothing is rolled back before the next frame")
	generate_driver_frame.emit()
	assert_eq(job.phase, "done")
	assert_eq(job.created.size(), 0)
	assert_true(job.result.is_empty())
	assert_true(_find_named_child(root, "DriverDisconnectACollider") == null)
	assert_true(_find_named_child(root, "DriverDisconnectBCollider") == null)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0)
	_remove_node(first)
	_remove_node(second)


func test_generate_driver_abandonment_and_success_release_script_work() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var first := _add_generate_mesh("DriverLifecycleA", Vector3.ONE)
	var second := _add_generate_mesh("DriverLifecycleB", Vector3.ONE)
	var connection := _CapturingConnection.new()
	root.add_child(connection)
	connection.set_process(false)
	var paths := [McpScenePath.from_node(first, root), McpScenePath.from_node(second, root)]
	var abandoned := _generate_job_for(paths, connection)
	PhysicsShapeHandler._generate_step(abandoned, 0)
	PhysicsShapeHandler._generate_step(abandoned, 0)
	assert_false(PhysicsShapeHandler._generate_step(abandoned, 0))
	assert_eq(abandoned.created.size(), 1)
	connection.dispatcher = _GoneDispatcher.new()
	PhysicsShapeHandler._drive_generate_job(abandoned, connection, generate_driver_frame)
	assert_eq(
		ScriptWork.active_count("physics_shape_generate"), 1,
		"the abandoned-request check runs after the dispatcher's registration window"
	)
	generate_driver_frame.emit()
	assert_true(abandoned.result.is_empty())
	assert_eq(abandoned.created.size(), 0)
	assert_eq(connection.captured.size(), 0)
	assert_true(_find_named_child(root, "DriverLifecycleACollider") == null)
	assert_true(_find_named_child(root, "DriverLifecycleBCollider") == null)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0)
	connection.dispatcher = null
	var success := _generate_job_for(paths, connection)
	PhysicsShapeHandler._drive_generate_job(success, connection, generate_driver_frame)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 1)
	for _frame in range(10):
		if ScriptWork.active_count("physics_shape_generate") == 0:
			break
		generate_driver_frame.emit()
	assert_eq(connection.captured.size(), 1)
	assert_eq(connection.captured[0].payload.data.created.size(), 2)
	assert_eq(success.result.data.created.size(), 2)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0)
	var body_a := _find_named_child(root, "DriverLifecycleACollider")
	var body_b := _find_named_child(root, "DriverLifecycleBCollider")
	assert_true(body_a != null and body_b != null)
	assert_true(editor_undo(_undo_redo))
	assert_true(body_a.get_parent() == null and body_b.get_parent() == null)
	assert_true(editor_redo(_undo_redo))
	assert_eq(body_a.get_parent(), root)
	assert_eq(body_b.get_parent(), root)
	_remove_node(body_a)
	_remove_node(body_b)
	_remove_node(first)
	_remove_node(second)
	connection.free()


func test_generate_driver_waits_for_dispatcher_registration_before_first_frame() -> void:
	## The real dispatcher registers the deferred request only after the handler
	## returns its sentinel. A pending check before the first yield would cancel
	## every real call; the job must survive that window and reply once the
	## registration lands.
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("DriverLateRegistration", Vector3.ONE)
	var dispatcher := _LateRegistrationDispatcher.new()
	var connection := _CapturingConnection.new()
	root.add_child(connection)
	connection.set_process(false)
	connection.dispatcher = dispatcher
	var job := _generate_job_for([McpScenePath.from_node(mesh, root)], connection)
	PhysicsShapeHandler._drive_generate_job(job, connection, generate_driver_frame)
	assert_eq(
		ScriptWork.active_count("physics_shape_generate"), 1,
		"the job must not cancel before the dispatcher registers the request"
	)
	dispatcher.registered = true
	for _frame in range(10):
		if not connection.captured.is_empty():
			break
		generate_driver_frame.emit()
	assert_eq(connection.captured.size(), 1, "the job must reply once registration lands")
	assert_eq(connection.captured[0].payload.data.created.size(), 1)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0)
	var body := _find_named_child(root, "DriverLateRegistrationCollider")
	assert_true(body != null)
	_remove_node(body)
	_remove_node(mesh)
	connection.dispatcher = null
	root.remove_child(connection)
	connection.free()


func test_generate_driver_early_exit_preserves_committed_results() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var detached_mesh := _add_generate_mesh("DriverDetachedCommitted", Vector3.ONE)
	var detached_connection := _CapturingConnection.new()
	var detached_job := _generate_job_for([
		McpScenePath.from_node(detached_mesh, root),
	], detached_connection)
	assert_true(PhysicsShapeHandler._generate_step(detached_job, -1))
	assert_true(detached_job.committed)
	PhysicsShapeHandler._drive_generate_job(detached_job, detached_connection)
	var detached_body := _find_named_child(root, "DriverDetachedCommittedCollider")
	assert_true(detached_body != null, "a detached reply target must not undo committed work")
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0, "detached early exit releases ScriptWork")

	var freed_mesh := _add_generate_mesh("DriverFreedCommitted", Vector3.ONE)
	var freed_connection := _CapturingConnection.new()
	root.add_child(freed_connection)
	freed_connection.set_process(false)
	var freed_job := _generate_job_for([
		McpScenePath.from_node(freed_mesh, root),
	], freed_connection)
	assert_true(PhysicsShapeHandler._generate_step(freed_job, -1))
	assert_true(freed_job.committed)
	root.remove_child(freed_connection)
	freed_connection.free()
	PhysicsShapeHandler._drive_generate_job(freed_job, freed_connection)
	var freed_body := _find_named_child(root, "DriverFreedCommittedCollider")
	assert_true(freed_body != null, "a lost reply target must not undo committed work")
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0, "invalid-connection early exit releases ScriptWork")

	_remove_node(detached_body)
	_remove_node(freed_body)
	_remove_node(detached_mesh)
	_remove_node(freed_mesh)
	detached_connection.free()


func test_generate_driver_frees_the_scene_root_and_releases_the_lease() -> void:
	## A scene root freed while the job is in flight must fail and answer on
	## the next driven frame. Before the validity check, the typed assignment
	## errored every frame and the lease was held until the dispatcher timeout.
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("DriverFreedSceneRoot", Vector3.ONE)
	var connection := _CapturingConnection.new()
	root.add_child(connection)
	connection.set_process(false)
	var validated := PhysicsShapeHandler._validate_generate_request({
		"paths": [McpScenePath.from_node(mesh, root)],
	})
	assert_has_key(validated, "data")
	var doomed_root := Node3D.new()
	doomed_root.name = "DriverFreedSceneRootStandin"
	doomed_root.free()
	validated["scene_root"] = doomed_root
	var job := PhysicsShapeHandler._generate_job(validated, _undo_redo, connection, "rid-generate")
	PhysicsShapeHandler._drive_generate_job(job, connection, generate_driver_frame)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 1, "worker is tracked before the first yield")
	generate_driver_frame.emit()
	assert_eq(str(job.phase), "done")
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0, "a freed scene root must release the lease")
	assert_is_error(job.result, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_eq(connection.captured.size(), 1, "the stale scene must be answered, not left to the timeout")
	_remove_node(mesh)
	connection.free()


func test_generate_driver_rolls_back_survivors_when_an_applied_parent_is_freed() -> void:
	## Plan two meshes, apply the first collider, free that item's parent, then
	## resume the second item. Finalization used to error on the freed entry,
	## record committed=true with an empty result and leave the second collider
	## behind; the request must instead fail cleanly, roll the survivor back and
	## release its work receipt.
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var first_parent := Node3D.new()
	first_parent.name = "GenerateAppliedParentA"
	root.add_child(first_parent)
	first_parent.set_owner(root)
	var second_parent := Node3D.new()
	second_parent.name = "GenerateAppliedParentB"
	root.add_child(second_parent)
	second_parent.set_owner(root)
	var first := MeshInstance3D.new()
	first.name = "GenerateAppliedA"
	var first_box := BoxMesh.new()
	first_box.size = Vector3.ONE
	first.mesh = first_box
	first_parent.add_child(first)
	first.set_owner(root)
	var second := MeshInstance3D.new()
	second.name = "GenerateAppliedB"
	var second_box := BoxMesh.new()
	second_box.size = Vector3.ONE
	second.mesh = second_box
	second_parent.add_child(second)
	second.set_owner(root)
	var connection := _CapturingConnection.new()
	root.add_child(connection)
	connection.set_process(false)
	var job := _generate_job_for([
		McpScenePath.from_node(first, root), McpScenePath.from_node(second, root),
	], connection)
	PhysicsShapeHandler._generate_step(job, 0)
	PhysicsShapeHandler._generate_step(job, 0)
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply the first collider")
	assert_eq(job.created.size(), 1)
	PhysicsShapeHandler._drive_generate_job(job, connection, generate_driver_frame)
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 1, "worker is tracked before the first yield")
	root.remove_child(first_parent)
	first_parent.free()
	generate_driver_frame.emit()
	assert_eq(str(job.phase), "done")
	assert_false(job.committed, "a failed finalization must not claim the batch is committed")
	assert_eq(ScriptWork.active_count("physics_shape_generate"), 0, "the receipt is released")
	assert_eq(connection.captured.size(), 1, "the failure is answered once")
	assert_is_error(connection.captured[0].payload, ErrorCodes.NODE_NOT_FOUND)
	assert_true(job.result.has("error"))
	assert_true(_find_named_child(second_parent, "GenerateAppliedBCollider") == null,
		"the surviving body is rolled back")
	assert_true(_find_named_child(root, "GenerateAppliedBCollider") == null)
	_remove_node(second_parent)
	root.remove_child(connection)
	connection.free()


func test_hull_preflight_counts_without_extracting_oversized_primitive() -> void:
	var plane := PlaneMesh.new()
	plane.subdivide_width = 600
	plane.subdivide_depth = 600
	var workload := PhysicsShapeHandler._mesh_workload(plane)
	assert_eq(workload.triangles, 2 * 601 * 601)
	assert_true(int(workload.vertices) > PhysicsShapeHandler._GENERATE_HULL_MAX_VERTICES)


func test_hull_preflight_bounds_supported_primitive_geometry() -> void:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 8
	sphere.rings = 4
	var cylinder := CylinderMesh.new()
	cylinder.radial_segments = 8
	cylinder.rings = 4
	var capsule := CapsuleMesh.new()
	capsule.radial_segments = 8
	capsule.rings = 4
	for mesh in [BoxMesh.new(), PlaneMesh.new(), sphere, cylinder, capsule]:
		var workload := PhysicsShapeHandler._mesh_workload(mesh)
		assert_false(workload.has("error"))
		assert_true(int(workload.triangles) >= mesh.get_faces().size() / 3,
			"preflight must not undercount actual primitive triangles")
		assert_true(int(workload.vertices) >= mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
			"preflight must not undercount generated vertices")


func test_hull_preflight_rejects_unused_vertex_overflow() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var vertices := PackedVector3Array()
	vertices.resize(PhysicsShapeHandler._GENERATE_HULL_MAX_VERTICES + 1)
	vertices[0] = Vector3.ZERO
	vertices[1] = Vector3.RIGHT
	vertices[2] = Vector3.FORWARD
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var source := ArrayMesh.new()
	source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mesh := _add_generate_mesh_with_mesh("UnusedVertices", source)
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, scene_root)], "shape_type": "convex"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "vertices")
	assert_true(_find_named_child(scene_root, "UnusedVerticesCollider") == null)
	_remove_node(mesh)


func test_hull_preflight_rechecks_geometry_grown_after_planning() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var mesh := _add_generate_mesh("HullGrewAfterPlanning", Vector3.ONE)
	var box := BoxMesh.new()
	mesh.mesh = box
	var connection := _CapturingConnection.new()
	var job := _generate_job_for([McpScenePath.from_node(mesh, root)], connection, {"shape_type": "trimesh"})
	assert_false(PhysicsShapeHandler._generate_step(job, 0), "planning yields before application")
	assert_eq(str(job.phase), "apply")
	box.subdivide_width = 600
	box.subdivide_height = 600
	assert_true(PhysicsShapeHandler._generate_step(job, 0), "growth is refused before construction")
	assert_is_error(job.result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_true(_find_named_child(root, "HullGrewAfterPlanningCollider") == null)
	assert_false(job.committed)
	_remove_node(mesh)
	connection.free()


func test_generate_auto_mixed_primitives_and_fallback() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var box := BoxMesh.new()
	box.size = Vector3(2, 4, 6)
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	var capsule := CapsuleMesh.new()
	capsule.radius = 1.0
	capsule.height = 4.0
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 2.0
	cylinder.height = 5.0
	var imported := ArrayMesh.new()
	imported.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.surface_get_arrays(0))
	var resources: Array[Mesh] = [box, sphere, capsule, cylinder, imported, TorusMesh.new()]
	var expected := ["box", "sphere", "capsule", "cylinder", "box", "box"]
	var expected_classes := ["BoxShape3D", "SphereShape3D", "CapsuleShape3D", "CylinderShape3D", "BoxShape3D", "BoxShape3D"]
	var paths: Array[String] = []
	var meshes: Array[MeshInstance3D] = []
	for index in resources.size():
		var mesh := _add_generate_mesh_with_mesh("AutoMixed%d" % index, resources[index])
		meshes.append(mesh)
		paths.append(McpScenePath.from_node(mesh, root))
	var result := _handler.generate({"paths": paths, "shape_type": "auto"})
	assert_has_key(result, "data")
	assert_eq(result.data.created.size(), resources.size())
	var bodies: Array[Node] = []
	for index in resources.size():
		var row: Dictionary = result.data.created[index]
		var collision := McpScenePath.resolve(row.shape_path, root) as CollisionShape3D
		bodies.append(McpScenePath.resolve(row.body_path, root))
		assert_eq(row.shape_type, expected[index])
		assert_eq(collision.shape.get_class(), expected_classes[index])
		match expected[index]:
			"box":
				assert_eq(collision.shape.size, meshes[index].get_aabb().size)
			"sphere":
				assert_true(is_equal_approx(collision.shape.radius, 2.0))
			"capsule":
				assert_true(is_equal_approx(collision.shape.radius, 1.0))
				assert_true(is_equal_approx(collision.shape.height, 4.0))
			"cylinder":
				assert_true(is_equal_approx(collision.shape.radius, 2.0), "tapered cylinders use bounding radius")
				assert_true(is_equal_approx(collision.shape.height, 5.0))
	assert_true(editor_undo(_undo_redo), "the mixed batch is one undo action")
	for body in bodies:
		assert_true(body.get_parent() == null)
	assert_true(editor_redo(_undo_redo), "native redo restores the mixed batch")
	for index in bodies.size():
		assert_true(bodies[index].get_parent() == root)
		assert_eq(bodies[index].get_node("CollisionShape3D").shape.get_class(), expected_classes[index])
	for body in bodies:
		_remove_node(body)
	for mesh in meshes:
		_remove_node(mesh)


func test_generate_auto_does_not_change_default_box() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	var mesh := _add_generate_mesh_with_mesh("AutoDefaultSphere", sphere)
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, root)]})
	assert_has_key(result, "data")
	assert_eq(result.data.created[0].shape_type, "box")
	var nodes := _generated_nodes(result, root)
	assert_true(nodes.collision.shape is BoxShape3D)
	assert_eq(nodes.collision.shape.size, mesh.get_aabb().size)
	_remove_node(nodes.body)
	_remove_node(mesh)


func test_generate_auto_dynamic_mesh_ownership_and_undo() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	for body_type in ["rigid", "character"]:
		var mesh := _add_generate_mesh_with_mesh("AutoDynamic%s" % body_type, SphereMesh.new())
		mesh.position = Vector3(2, 3, 4)
		var transform := mesh.global_transform
		var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, root)], "shape_type": "auto", "body_type": body_type})
		assert_has_key(result, "data")
		assert_eq(result.data.created[0].shape_type, "sphere")
		var nodes := _generated_nodes(result, root)
		assert_true(nodes.collision.shape is SphereShape3D)
		assert_true(mesh.get_parent() == nodes.body)
		assert_eq(mesh.global_transform, transform)
		assert_true(editor_undo(_undo_redo))
		assert_true(mesh.get_parent() == root)
		assert_eq(mesh.global_transform, transform)
		assert_true(editor_redo(_undo_redo))
		assert_true(mesh.get_parent() == nodes.body)
		assert_eq(mesh.global_transform, transform)
		_remove_node(nodes.body)


func test_generate_auto_rejects_resource_or_bounds_changes_atomically() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	for change in ["resource", "bounds", "applied_bounds"]:
		var first := _add_generate_mesh("AutoStaleFirst", Vector3.ONE)
		var second := _add_generate_mesh("AutoStaleSecond", Vector3.ONE)
		var connection := _CapturingConnection.new()
		var job := _generate_job_for([McpScenePath.from_node(first, root), McpScenePath.from_node(second, root)], connection, {"shape_type": "auto"})
		assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan first")
		assert_false(PhysicsShapeHandler._generate_step(job, 0), "plan second")
		assert_false(PhysicsShapeHandler._generate_step(job, 0), "apply first")
		match change:
			"resource":
				second.mesh = SphereMesh.new()
			"bounds":
				(second.mesh as BoxMesh).size = Vector3(2, 3, 4)
			"applied_bounds":
				(first.mesh as BoxMesh).size = Vector3(2, 3, 4)
		assert_true(PhysicsShapeHandler._generate_step(job, 0))
		assert_is_error(job.result, ErrorCodes.EDITED_SCENE_MISMATCH)
		assert_contains(job.result.error.message, "changed its mesh")
		assert_true(_find_named_child(root, "AutoStaleFirstCollider") == null)
		assert_true(_find_named_child(root, "AutoStaleSecondCollider") == null)
		assert_false(job.committed)
		_remove_node(first)
		_remove_node(second)
		connection.free()


func test_generate_auto_resolves_before_parent_scale_validation() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene root")
		return
	var parent := Node3D.new()
	parent.name = "AutoScaledParent"
	parent.scale = Vector3(1, 2, 3)
	root.add_child(parent)
	parent.owner = root
	var mesh := _add_generate_mesh_with_mesh("AutoScaledSphere", SphereMesh.new())
	mesh.reparent(parent, false)
	var result := _handler.generate({"paths": [McpScenePath.from_node(mesh, root)], "shape_type": "auto"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "non-uniformly")
	assert_true(_find_named_child(parent, "AutoScaledSphereCollider") == null)
	_remove_node(parent)
