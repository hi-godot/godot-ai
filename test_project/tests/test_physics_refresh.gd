@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")
const Refresh := preload("res://addons/godot_ai/handlers/physics_shape_refresh.gd")
const Errors := preload("res://addons/godot_ai/utils/error_codes.gd")
var _handler: Handler
var _undo: EditorUndoRedoManager
var _root: Node


func suite_name() -> String:
	return "physics_refresh"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.undo_redo
	_handler = Handler.new(_undo)
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		fail_setup("Needs edited scene")


func teardown() -> void:
	_undo.clear_history()


func _mesh(name: String) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = name
	mesh.mesh = BoxMesh.new()
	_root.add_child(mesh)
	mesh.owner = _root
	return mesh


func _generate(mesh: MeshInstance3D, extra: Dictionary = {}) -> Dictionary:
	var params := {"paths": [McpScenePath.from_node(mesh, _root)]}
	params.merge(extra)
	return _handler.generate(params)


func _body(result: Dictionary) -> CollisionObject3D:
	return McpScenePath.resolve(result.data.created[0].body_path, _root)


func test_refresh_preserves_identity_user_state_shared_resource_and_exact_undo() -> void:
	var mesh := _mesh("RefreshIdentity")
	var first := _generate(mesh)
	assert_has_key(first, "data")
	var body := _body(first)
	var collision := body.get_node("CollisionShape3D") as CollisionShape3D
	body.collision_layer = 7
	var extra := Node.new()
	extra.name = "UserChild"
	body.add_child(extra)
	extra.owner = _root
	var old_shape := collision.shape
	var shared := CollisionShape3D.new()
	shared.shape = old_shape
	body.add_child(shared)
	shared.owner = _root
	var old_transform := Transform3D(Basis.from_euler(Vector3(0.2, 0.3, 0.1)), Vector3(1, 2, 3))
	collision.transform = old_transform
	mesh.mesh.size = Vector3(2, 4, 6)
	var result := _generate(mesh, {"overwrite": true})
	assert_eq(result.data.created[0].operation, "refresh")
	assert_true(_body(result) == body)
	assert_true(body.get_node("CollisionShape3D") == collision)
	assert_true(collision.shape is BoxShape3D)
	assert_eq(collision.shape.size, Vector3(2, 4, 6))
	assert_true(collision.shape != old_shape)
	assert_true(shared.shape == old_shape)
	assert_eq(old_shape.size, Vector3.ONE)
	assert_eq(body.collision_layer, 7)
	assert_true(extra.get_parent() == body)
	var replacement := collision.shape
	assert_true(editor_undo(_undo))
	assert_true(collision.shape == old_shape)
	assert_eq(collision.transform, old_transform)
	assert_true(editor_redo(_undo))
	assert_true(collision.shape == replacement)
	assert_true(shared.shape == old_shape)


func test_default_refusal_legacy_body_and_topology_mismatch() -> void:
	var mesh := _mesh("RefreshRefusal")
	var initial := _generate(mesh)
	var body := _body(initial)
	var shape: Shape3D = body.get_node("CollisionShape3D").shape
	assert_is_error(_generate(mesh), Errors.VALUE_OUT_OF_RANGE)
	assert_is_error(_generate(mesh, {"overwrite": true, "body_type": "area"}), Errors.VALUE_OUT_OF_RANGE)
	assert_is_error(_generate(mesh, {"overwrite": true, "reparent_mesh": true}), Errors.VALUE_OUT_OF_RANGE)
	mesh.remove_meta(Refresh.MARKER)
	assert_is_error(_generate(mesh, {"overwrite": true}), Errors.VALUE_OUT_OF_RANGE)
	assert_true(body.get_node("CollisionShape3D").shape == shape)
	assert_true(body.get_parent() == _root)


func test_wrapped_refresh_does_not_nest_body_and_creation_undo_restores_metadata() -> void:
	var mesh := _mesh("RefreshWrapped")
	var first := _generate(mesh, {"body_type": "rigid"})
	var body := _body(first) as RigidBody3D
	body.mass = 12.5
	mesh.mesh.size = Vector3(2, 3, 4)
	var result := _generate(mesh, {"overwrite": true, "body_type": "rigid"})
	assert_true(_body(result) == body)
	assert_true(mesh.get_parent() == body)
	assert_eq(body.mass, 12.5)
	assert_eq(body.get_node("CollisionShape3D").shape.size, Vector3(2, 3, 4))
	assert_true(editor_undo(_undo))
	assert_true(editor_undo(_undo))
	assert_false(mesh.has_meta(Refresh.MARKER))
	assert_true(mesh.get_parent() == _root)
	assert_true(editor_redo(_undo))
	assert_eq(typeof(mesh.get_meta(Refresh.MARKER).body), TYPE_NODE_PATH)
	assert_true(mesh.get_parent() == body)


func test_mixed_create_refresh_is_one_action_and_failed_plan_changes_neither() -> void:
	var existing := _mesh("RefreshMixedExisting")
	var first := _generate(existing)
	var body := _body(first)
	var old: Shape3D = body.get_node("CollisionShape3D").shape
	var fresh := _mesh("RefreshMixedFresh")
	existing.mesh.size = Vector3(3, 3, 3)
	var paths := [McpScenePath.from_node(existing, _root), McpScenePath.from_node(fresh, _root)]
	var failed := _handler.generate({"paths": paths + ["/MissingRefreshMesh"], "overwrite": true})
	assert_is_error(failed, Errors.NODE_NOT_FOUND)
	assert_true(body.get_node("CollisionShape3D").shape == old)
	assert_false(_root.has_node("RefreshMixedFreshCollider"))
	var result := _handler.generate({"paths": paths, "overwrite": true})
	assert_eq(result.data.created[0].operation, "refresh")
	assert_eq(result.data.created[1].operation, "create")
	assert_eq(body.get_node("CollisionShape3D").shape.size, Vector3(3, 3, 3))
	assert_true(editor_undo(_undo))
	assert_true(body.get_node("CollisionShape3D").shape == old)
	assert_false(_root.has_node("RefreshMixedFreshCollider"))
	assert_false(fresh.has_meta(Refresh.MARKER))
	assert_true(editor_redo(_undo))
	assert_eq(body.get_node("CollisionShape3D").shape.size, Vector3(3, 3, 3))
	assert_true(_root.has_node("RefreshMixedFreshCollider"))


func test_prepared_batch_rejects_intervening_geometry_shape_and_relationship_edits() -> void:
	for mutation in ["geometry", "resource", "shape", "transform", "link"]:
		var mesh := _mesh("RefreshStale" + mutation)
		var first := _generate(mesh)
		var body := _body(first)
		var collision := body.get_node("CollisionShape3D") as CollisionShape3D
		var original := collision.shape
		var validated := Handler._validate_generate_request({"paths": [McpScenePath.from_node(mesh, _root)], "overwrite": true})
		var job := Handler._generate_job(validated, _undo, null, "")
		assert_false(Handler._generate_step(job, 0), "plan only")
		assert_false(Handler._generate_step(job, 0), "prepare only")
		assert_true(collision.shape == original)
		match mutation:
			"geometry": mesh.mesh.subdivide_width += 1
			"resource": mesh.mesh = SphereMesh.new()
			"shape": original.size = Vector3(7, 7, 7)
			"transform": collision.position.x += 3
			"link": mesh.set_meta(Refresh.MARKER, {"version": 1})
		assert_true(Handler._generate_step(job, 0))
		assert_is_error(job.result, Errors.EDITED_SCENE_MISMATCH)
		assert_false(job.committed)
		assert_true(collision.shape == original)
		assert_true(body.get_parent() == _root)
		if mutation == "shape":
			assert_eq(original.size, Vector3(7, 7, 7), "user edits survive refused refresh")


func test_cancelled_preparation_keeps_existing_and_discards_detached_creation() -> void:
	var mesh := _mesh("RefreshCancel")
	var body := _body(_generate(mesh))
	var old: Shape3D = body.get_node("CollisionShape3D").shape
	var fresh := _mesh("RefreshCancelFresh")
	var validated := Handler._validate_generate_request({"paths": [McpScenePath.from_node(mesh, _root), McpScenePath.from_node(fresh, _root)], "overwrite": true})
	var job := Handler._generate_job(validated, _undo, null, "")
	for index in 4:
		assert_false(Handler._generate_step(job, 0))
	assert_eq(job.created.size(), 2)
	Handler._cancel_generate_job(job)
	assert_true(body.get_node("CollisionShape3D").shape == old)
	assert_false(_root.has_node("RefreshCancelFreshCollider"))
	assert_false(fresh.has_meta(Refresh.MARKER))
	assert_eq(job.created.size(), 0)


func test_native_nodepath_provenance_survives_packed_scene_roundtrip() -> void:
	for wrapped in [false, true]:
		var mesh := _mesh("RefreshPacked" + str(wrapped))
		_generate(mesh, {"reparent_mesh": wrapped})
		var packed := PackedScene.new()
		assert_eq(packed.pack(_root), OK)
		var scene_path := "user://physics-refresh-roundtrip.tscn"
		assert_eq(ResourceSaver.save(packed, scene_path), OK)
		var loaded := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var copy := loaded.instantiate()
		var mesh_path := _root.get_path_to(mesh)
		var copied_mesh := copy.get_node(mesh_path) as MeshInstance3D
		assert_eq(typeof(copied_mesh.get_meta(Refresh.MARKER).body), TYPE_NODE_PATH)
		var linked := Refresh.relationship(copied_mesh, copy, "static", wrapped)
		assert_false(linked.is_empty())
		assert_true(linked.collision.shape is BoxShape3D)
		copy.free()
		assert_eq(DirAccess.remove_absolute(scene_path), OK)


func test_convex_and_trimesh_refresh_bake_full_body_relative_transform() -> void:
	for kind in ["convex", "trimesh"]:
		var mesh := _mesh("RefreshHull" + kind)
		var first := _generate(mesh, {"shape_type": kind})
		var body := _body(first)
		body.transform = Transform3D(Basis.from_euler(Vector3(0.2, 0.5, 0.3)), Vector3(4, 2, -3))
		mesh.transform = Transform3D(Basis.from_euler(Vector3(0.4, -0.3, 0.2)).scaled(Vector3(-2, 3, 4)), Vector3(-1, 5, 2))
		var before := body.transform
		var mesh_to_body := body.global_transform.affine_inverse() * mesh.global_transform
		var expected_points: PackedVector3Array = mesh.mesh.create_convex_shape().points if kind == "convex" else mesh.mesh.create_trimesh_shape().get_faces()
		for index in expected_points.size():
			expected_points[index] = mesh_to_body * expected_points[index]
		if kind == "trimesh" and mesh_to_body.basis.determinant() < 0:
			for index in range(0, expected_points.size(), 3):
				var swap := expected_points[index + 1]
				expected_points[index + 1] = expected_points[index + 2]
				expected_points[index + 2] = swap
		var result := _generate(mesh, {"overwrite": true, "shape_type": kind})
		assert_eq(result.data.created[0].shape_type, kind)
		var collision := body.get_node("CollisionShape3D") as CollisionShape3D
		var points: PackedVector3Array = collision.shape.points if kind == "convex" else collision.shape.get_faces()
		assert_eq(points.size(), expected_points.size())
		for index in points.size():
			assert_true(points[index].is_equal_approx(expected_points[index]))
		assert_eq(collision.transform, Transform3D.IDENTITY)
		assert_eq(body.transform, before)


func test_missing_wrapped_source_marker_cannot_create_nested_body() -> void:
	var mesh := _mesh("RefreshMissingMarker")
	var body := _body(_generate(mesh, {"body_type": "rigid"}))
	mesh.remove_meta(Refresh.MARKER)
	assert_is_error(_generate(mesh, {"body_type": "rigid"}), Errors.VALUE_OUT_OF_RANGE)
	var result := _generate(mesh, {"overwrite": true, "body_type": "rigid"})
	assert_is_error(result, Errors.VALUE_OUT_OF_RANGE)
	assert_true(mesh.get_parent() == body)
	assert_eq(body.get_child_count(), 2)


func test_top_level_collision_refuses_before_replacing_shape() -> void:
	var mesh := _mesh("RefreshTopLevel")
	var body := _body(_generate(mesh))
	body.position = Vector3(4, 5, 6)
	var collision := body.get_node("CollisionShape3D") as CollisionShape3D
	collision.top_level = true
	var before := collision.transform
	var original := collision.shape
	var result := _generate(mesh, {"overwrite": true})
	assert_is_error(result, Errors.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "top_level")
	assert_true(collision.shape == original)
	assert_eq(collision.transform, before)


func test_collision_script_native_set_interception_is_bypassed_and_preserved() -> void:
	var mesh := _mesh("RefreshScript")
	var body := _body(_generate(mesh))
	var collision := body.get_node("CollisionShape3D") as CollisionShape3D
	var script := GDScript.new()
	script.source_code = "@tool\nextends CollisionShape3D\nvar reads := 0\nfunc _get(key: StringName) -> Variant:\n\treads += 1\n\tif key == &'shape':\n\t\treturn SphereShape3D.new()\n\treturn null\nvar writes := 0\nfunc _set(key: StringName, _value: Variant) -> bool:\n\twrites += 1\n\treturn key == &'shape' or key == &'transform'\n"
	assert_eq(script.reload(), OK)
	collision.set_script(script)
	collision.set("writes", 0)
	collision.set("reads", 0)
	mesh.mesh.size = Vector3(3, 4, 5)
	var result := _generate(mesh, {"overwrite": true})
	assert_eq(result.data.created[0].operation, "refresh")
	assert_true(collision.get_script() == script)
	var stored: Shape3D = ClassDB.class_get_property(collision, "shape")
	assert_eq(stored.size, Vector3(3, 4, 5))
	assert_eq(collision.get("writes"), 0)
	assert_eq(collision.get("reads"), 0)
	assert_true(editor_undo(_undo))
	assert_eq((ClassDB.class_get_property(collision, "shape") as BoxShape3D).size, Vector3.ONE)
	assert_eq(collision.get("writes"), 0)
	assert_eq(collision.get("reads"), 0)


func test_malformed_marker_and_fresh_owner_edit_refuse_without_mutation() -> void:
	var mesh := _mesh("RefreshMalformed")
	var body := _body(_generate(mesh))
	var marker: Dictionary = mesh.get_meta(Refresh.MARKER).duplicate(true)
	for value in ["false", 1, null]:
		var malformed := marker.duplicate(true)
		malformed.wrapped = value
		mesh.set_meta(Refresh.MARKER, malformed)
		assert_is_error(_generate(mesh, {"overwrite": true}), Errors.VALUE_OUT_OF_RANGE)
		assert_true(body.get_parent() == _root)
	mesh.set_meta(Refresh.MARKER, marker)
	var fresh := _mesh("RefreshOwner")
	var validated := Handler._validate_generate_request({"paths": [McpScenePath.from_node(fresh, _root)], "overwrite": true, "body_type": "rigid"})
	var job := Handler._generate_job(validated, _undo, null, "")
	assert_false(Handler._generate_step(job, 0))
	fresh.owner = null
	assert_true(Handler._generate_step(job, 0))
	assert_is_error(job.result, Errors.EDITED_SCENE_MISMATCH)
	assert_true(fresh.owner == null)
	assert_true(fresh.get_parent() == _root)
	assert_false(_root.has_node("RefreshOwnerCollider"))


func test_fresh_source_rename_after_preparation_refuses_stale_provenance() -> void:
	var mesh := _mesh("RefreshRename")
	var validated := Handler._validate_generate_request({"paths": [McpScenePath.from_node(mesh, _root)], "overwrite": true})
	var job := Handler._generate_job(validated, _undo, null, "")
	assert_false(Handler._generate_step(job, 0))
	assert_false(Handler._generate_step(job, 0))
	mesh.name = "RefreshRenamed"
	assert_true(Handler._generate_step(job, 0))
	assert_is_error(job.result, Errors.EDITED_SCENE_MISMATCH)
	assert_false(mesh.has_meta(Refresh.MARKER))
	assert_false(_root.has_node("RefreshRenameCollider"))
	assert_eq(mesh.name, &"RefreshRenamed")


func test_fresh_scripted_mesh_snapshot_uses_native_world_transform() -> void:
	var mesh := _mesh("RefreshFreshScript")
	mesh.position = Vector3(4, 5, 6)
	var script := GDScript.new()
	script.source_code = "@tool\nextends MeshInstance3D\nvar reads := 0\nfunc _get(key: StringName) -> Variant:\n\tif key == &'global_transform':\n\t\treads += 1\n\t\treturn Transform3D.IDENTITY\n\treturn null\n"
	assert_eq(script.reload(), OK)
	mesh.set_script(script)
	mesh.set("reads", 0)
	var result := _generate(mesh, {"overwrite": true})
	assert_has_key(result, "data")
	assert_eq(result.data.created[0].operation, "create")
	assert_eq(_body(result).global_position, Vector3(4, 5, 6))
	assert_eq(mesh.get("reads"), 0)
	assert_true(mesh.get_script() == script)
