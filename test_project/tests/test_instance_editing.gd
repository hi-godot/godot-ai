@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const PhysicsHandler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")
const CurveHandler := preload("res://addons/godot_ai/handlers/curve_handler.gd")
const CameraHandler := preload("res://addons/godot_ai/handlers/camera_handler.gd")
const UiHandler := preload("res://addons/godot_ai/handlers/ui_handler.gd")
const Fixture := preload("res://tests/fixtures/instance_editing.tscn")
const SAVED_INSTANCE_PATH := "res://tests/_editable_children_roundtrip.tscn"

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _root: Node
var _instance: Node3D
var _path: String
var _files: Array[String] = []


func suite_name() -> String:
	return "instance_editing"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.undo_redo
	_handler = NodeHandler.new(_undo_redo)
	_root = EditorInterface.get_edited_scene_root()


func setup() -> void:
	_instance = Fixture.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_instance.name = "_McpTestInstanceEditing"
	_root.add_child(_instance)
	_instance.owner = _root
	_path = McpScenePath.from_node(_instance, _root)


func teardown() -> void:
	for path in _files:
		DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".uid"):
			DirAccess.remove_absolute(path + ".uid")
	_files.clear()
	_root.set_editable_instance(_instance.get_node("Nested"), false)
	_root.set_editable_instance(_instance, false)
	_root.remove_child(_instance)
	_instance.queue_free()
	if FileAccess.file_exists(SAVED_INSTANCE_PATH):
		DirAccess.remove_absolute(SAVED_INSTANCE_PATH)


func test_locked_instance_refuses_edits_without_undo_or_mutation() -> void:
	var mesh: MeshInstance3D = _instance.get_node("Mesh")
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	_assert_locked(_handler.create_node({"type": "Node3D", "name": "Socket", "parent_path": _path + "/Mesh"}))
	_assert_locked(_handler.set_property({"path": _path + "/Mesh", "property": "visible", "value": false}))
	_assert_locked(_handler.set_property({"path": _path + "/Mesh", "property": "cast_shadow", "value": 0}))
	assert_eq(mesh.get_node_or_null("Socket"), null)
	assert_true(mesh.visible)
	assert_eq(mesh.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	assert_eq(history.get_version(), version, "refusals must not create undo actions")
	var read := _handler.get_node_properties({"path": _path + "/Mesh", "fields": ["visible"]})
	assert_eq(read.data.properties[0].value, true, "locked descendants remain readable")


func test_specialized_assignments_refuse_locked_instance() -> void:
	_assert_locked(MaterialHandler.new(_undo_redo).apply_to_node({"node_path": _path + "/Mesh"}))
	_assert_locked(ScriptHandler.new(_undo_redo).attach_script({"path": _path + "/Mesh", "script_path": "res://tests/test_instance_editing.gd"}))
	_assert_locked(ResourceHandler.new(_undo_redo).assign_resource({"path": _path + "/Mesh", "property": "mesh", "resource_path": "res://tests/fixtures/instance_editing.tscn"}))
	_assert_locked(UiHandler.new(_undo_redo).set_text({"path": _path + "/Label", "text": "Lost"}))
	assert_eq(_instance.get_node("Mesh").material_override, null)
	assert_eq(_instance.get_node("Mesh").get_script(), null)
	assert_eq(_instance.get_node("Label").text, "Original")


func test_camera_follow_refuses_source_structure_but_allows_existing_parent_override() -> void:
	_root.set_editable_instance(_instance, true)
	var camera: Camera2D = _instance.get_node("Canvas/Camera")
	var parent := camera.get_parent()
	var handler := CameraHandler.new(_undo_redo)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	var rejected := handler.follow_2d({"camera_path": _path + "/Canvas/Camera", "target_path": McpScenePath.from_node(_root, _root)})
	assert_is_error(rejected, McpErrorCodes.INVALID_PARAMS)
	assert_eq(camera.get_parent(), parent)
	assert_eq(camera.owner, _instance)
	assert_false(camera.position_smoothing_enabled)
	assert_eq(history.get_version(), version)
	if not rejected.has("error"):
		camera.reparent(parent)
		camera.owner = _instance
		return
	var accepted := handler.follow_2d({"camera_path": _path + "/Canvas/Camera", "target_path": _path + "/Canvas", "smoothing_speed": 8.0})
	assert_eq(accepted.get("data", {}).get("reparented", true), false)
	assert_eq(camera.position_smoothing_speed, 8.0)
	var restored := _roundtrip()
	assert_eq(restored.get_node(str(_instance.name) + "/Canvas/Camera").position_smoothing_speed, 8.0)
	restored.free()
	assert_true(editor_undo(_undo_redo))
	assert_false(camera.position_smoothing_enabled)


func test_camera_follow_checks_destination_and_persists_editable_local_attachment() -> void:
	var camera := Camera2D.new()
	camera.name = "LocalCamera"
	camera.enabled = false
	camera.position = Vector2(12, 34)
	_instance.add_child(camera)
	camera.owner = _root
	var handler := CameraHandler.new(_undo_redo)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	var params := {"camera_path": _path + "/LocalCamera", "target_path": _path + "/Canvas"}
	var rejected := handler.follow_2d(params)
	_assert_locked(rejected)
	assert_eq(camera.get_parent(), _instance)
	assert_eq(camera.position, Vector2(12, 34))
	assert_false(camera.position_smoothing_enabled)
	assert_eq(history.get_version(), version)
	if not rejected.has("error"):
		camera.reparent(_instance)
		camera.owner = _root
		return
	_root.set_editable_instance(_instance, true)
	var accepted := handler.follow_2d(params)
	assert_eq(accepted.get("data", {}).get("reparented", false), true)
	assert_eq(camera.get_parent(), _instance.get_node("Canvas"))
	assert_eq(camera.owner, _root)
	var restored := _roundtrip()
	assert_true(restored.get_node(str(_instance.name) + "/Canvas/LocalCamera") is Camera2D)
	restored.free()
	assert_true(editor_undo(_undo_redo))
	assert_eq(camera.get_parent(), _instance)
	assert_eq(camera.position, Vector2(12, 34))
	assert_true(editor_redo(_undo_redo))
	assert_eq(camera.get_parent(), _instance.get_node("Canvas"))


func test_material_preset_refusals_leave_disk_node_and_undo_unchanged() -> void:
	var handler := MaterialHandler.new(_undo_redo)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	for target in [{"node_path": _path + "/Mesh"}, {"node_path": _path + "/Missing"}, {"node_path": _path, "slot": "surface_99"}]:
		var path := "res://tests/_preset_refusal_%d.tres" % Time.get_ticks_usec()
		_files.append(path)
		var params := {"preset": "metal", "path": path}
		params.merge(target)
		assert_is_error(handler.apply_preset(params))
		assert_false(FileAccess.file_exists(path), "invalid target must not create a material")
		var original := StandardMaterial3D.new()
		original.albedo_color = Color.BLUE
		assert_eq(ResourceSaver.save(original, path), OK)
		var bytes := FileAccess.get_file_as_bytes(path)
		params.overwrite = true
		assert_is_error(handler.apply_preset(params))
		assert_eq(FileAccess.get_file_as_bytes(path), bytes, "invalid target must not overwrite a material")
	assert_eq(_instance.get_node("Mesh").material_override, null)
	assert_eq(history.get_version(), version)
	_root.set_editable_instance(_instance, true)
	var accepted_path := "res://tests/_preset_accepted_%d.tres" % Time.get_ticks_usec()
	_files.append(accepted_path)
	var accepted := handler.apply_preset({"preset": "glass", "path": accepted_path, "node_path": _path + "/Mesh"})
	assert_eq(accepted.get("data", {}).get("assigned", false), true)
	var material: Material = _instance.get_node("Mesh").material_override
	assert_true(material is StandardMaterial3D)
	assert_eq(material.metallic, 0.0)
	assert_true(is_equal_approx(material.roughness, 0.05))
	assert_eq(material.resource_path, accepted_path)
	assert_true(editor_undo(_undo_redo))
	assert_eq(_instance.get_node("Mesh").material_override, null)
	assert_true(FileAccess.file_exists(accepted_path), "undo reverts assignment, not the saved file")


func test_structural_operations_and_reparent_destination_refuse_locked_nodes() -> void:
	_assert_locked(_handler.delete_node({"path": _path + "/Mesh"}))
	_assert_locked(_handler.rename_node({"path": _path + "/Mesh", "new_name": "Renamed"}))
	_assert_locked(_handler.move_node({"path": _path + "/Mesh", "index": 1}))
	_assert_locked(_handler.reparent_node({"path": _path + "/Mesh", "new_parent": McpScenePath.from_node(_root, _root)}))
	_assert_locked(_handler.duplicate_node({"path": _path + "/Mesh/Tip"}))
	var local := Node3D.new()
	local.name = "Local"
	_instance.add_child(local)
	local.owner = _root
	_assert_locked(_handler.reparent_node({"path": _path + "/Local", "new_parent": _path + "/Mesh"}))
	assert_eq(local.get_parent(), _instance)
	assert_eq(_instance.get_node("Mesh").get_index(), 0)
	assert_eq(_instance.get_node("Mesh").get_child_count(), 1)


func test_instance_root_and_direct_local_attachments_survive_serialization() -> void:
	var changed := _handler.set_property({"path": _path, "property": "visible", "value": false})
	assert_eq(changed.data.value, false)
	var created := _handler.create_node({"type": "Node3D", "name": "Socket", "parent_path": _path})
	assert_eq(created.data.path, _path + "/Socket")
	var local_changed := _handler.set_property({"path": _path + "/Socket", "property": "position", "value": {"x": 2.0, "y": 0.0, "z": 0.0}})
	assert_true(local_changed.data.undoable)
	var restored := _roundtrip()
	assert_false(restored.get_node(str(_instance.name)).visible)
	assert_eq(restored.get_node(str(_instance.name) + "/Socket").position, Vector3(2, 0, 0))
	restored.free()
	assert_true(editor_undo(_undo_redo))
	assert_eq(_instance.get_node("Socket").position, Vector3.ZERO)
	assert_true(editor_redo(_undo_redo))
	assert_eq(_instance.get_node("Socket").position, Vector3(2, 0, 0))


func test_editable_instance_overrides_and_nested_local_attachments_survive() -> void:
	_root.set_editable_instance(_instance, true)
	var changed := _handler.set_property({"path": _path + "/Mesh", "property": "visible", "value": false})
	assert_eq(changed.data.value, false)
	var created := _handler.create_node({"type": "Node3D", "name": "Socket", "parent_path": _path + "/Mesh"})
	assert_eq(created.data.path, _path + "/Mesh/Socket")
	var local_changed := _handler.set_property({"path": _path + "/Mesh/Socket", "property": "visible", "value": false})
	assert_eq(local_changed.data.value, false)
	var restored := _roundtrip()
	assert_false(restored.get_node(str(_instance.name) + "/Mesh").visible)
	assert_false(restored.get_node(str(_instance.name) + "/Mesh/Socket").visible)
	restored.free()


func test_local_node_under_locked_ancestor_is_also_refused() -> void:
	var local := Node3D.new()
	local.name = "Local"
	_instance.get_node("Mesh").add_child(local)
	local.owner = _root
	_assert_locked(_handler.set_property({"path": _path + "/Mesh/Local", "property": "visible", "value": false}))
	_assert_locked(_handler.create_node({"type": "Node3D", "name": "Socket", "parent_path": _path + "/Mesh/Local"}))
	assert_true(local.visible)
	assert_eq(local.get_child_count(), 0)


func test_nested_instance_requires_its_own_editable_children() -> void:
	_root.set_editable_instance(_instance, true)
	_assert_locked(_handler.set_property({"path": _path + "/Nested/Tip", "property": "visible", "value": false}))
	_root.set_editable_instance(_instance.get_node("Nested"), true)
	var changed := _handler.set_property({"path": _path + "/Nested/Tip", "property": "visible", "value": false})
	assert_eq(changed.data.value, false)
	var restored := _roundtrip()
	assert_false(restored.get_node(str(_instance.name) + "/Nested/Tip").visible)
	restored.free()


func test_editable_children_does_not_allow_changing_source_structure() -> void:
	_root.set_editable_instance(_instance, true)
	for result in [
		_handler.delete_node({"path": _path + "/Mesh"}),
		_handler.rename_node({"path": _path + "/Mesh", "new_name": "Renamed"}),
		_handler.set_property({"path": _path + "/Mesh", "property": "name", "value": "Renamed"}),
		_handler.move_node({"path": _path + "/Mesh", "index": 1}),
		_handler.reparent_node({"path": _path + "/Mesh", "new_parent": McpScenePath.from_node(_root, _root)}),
	]:
		assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
		assert_contains(str(result.error.message), "source scene")
	assert_eq(_instance.get_node("Mesh").get_index(), 0)
	assert_eq(_instance.get_node("Mesh").get_parent(), _instance)


func _roundtrip() -> Node:
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	return packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)


func _assert_locked(result: Dictionary) -> void:
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(str(result.get("error", {}).get("message", "")), "Editable Children")
	assert_contains(str(result.get("error", {}).get("message", "")), _path)


func test_curve_assignment_refuses_locked_instance_and_persists_when_editable() -> void:
	var curve_handler := CurveHandler.new(_undo_redo)
	var params := {"path": _path + "/Path", "property": "curve", "points": [{"position": {"x": 2, "y": 3, "z": 4}}]}
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	_assert_locked(curve_handler.set_points(params))
	assert_eq(_instance.get_node("Path").curve, null)
	assert_eq(history.get_version(), version, "refusal must not add undo history")
	_root.set_editable_instance(_instance, true)
	var result := curve_handler.set_points(params)
	assert_eq(result.data.point_count, 1)
	var restored := _roundtrip()
	assert_eq(restored.get_node(str(_instance.name) + "/Path").curve.get_point_position(0), Vector3(2, 3, 4))
	restored.free()


func test_physics_reparent_refuses_source_mesh_but_allows_editable_sibling_collider() -> void:
	_root.set_editable_instance(_instance, true)
	var physics := PhysicsHandler.new(_undo_redo)
	var params := {"paths": [_path + "/Mesh"], "body_type": "static", "shape_type": "box", "reparent_mesh": true}
	var mesh: MeshInstance3D = _instance.get_node("Mesh")
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	var rejected := physics.generate(params)
	assert_is_error(rejected, McpErrorCodes.INVALID_PARAMS)
	assert_contains(rejected.error.message, "source scene")
	assert_eq(mesh.get_parent(), _instance)
	assert_eq(_instance.get_node_or_null("MeshCollider"), null)
	assert_eq(history.get_version(), version)
	params.reparent_mesh = false
	var accepted := physics.generate(params)
	assert_eq(accepted.data.created[0].body_path, _path + "/MeshCollider")
	assert_eq(mesh.get_parent(), _instance)
	var restored := _roundtrip()
	var restored_instance := restored.get_node(str(_instance.name))
	assert_true(restored_instance.get_node("Mesh") is MeshInstance3D)
	assert_true(restored_instance.get_node("MeshCollider") is StaticBody3D)
	var shape: Shape3D = restored_instance.get_node("MeshCollider/CollisionShape3D").shape
	assert_true(shape is BoxShape3D)
	assert_eq(shape.size, mesh.get_aabb().size)
	restored.free()
	assert_true(editor_undo(_undo_redo))
	assert_eq(_instance.get_node_or_null("MeshCollider"), null)


func _toggle(editable: bool, path: String = "") -> Dictionary:
	return _handler.set_editable_children({"path": _path if path.is_empty() else path, "editable": editable})


func test_explicit_editable_children_toggle_undo_redo_and_noop() -> void:
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var enabled := _toggle(true)
	assert_eq(enabled.data.editable, true)
	assert_eq(enabled.data.previous_editable, false)
	assert_true(enabled.data.changed)
	assert_true(enabled.data.undoable)
	assert_true(_root.is_editable_instance(_instance))
	assert_true(editor_undo(_undo_redo))
	assert_false(_root.is_editable_instance(_instance))
	assert_true(editor_redo(_undo_redo))
	assert_true(_root.is_editable_instance(_instance))
	var version := history.get_version()
	var unchanged := _toggle(true)
	assert_false(unchanged.data.changed)
	assert_false(unchanged.data.undoable)
	assert_eq(history.get_version(), version)
	var disabled := _toggle(false)
	assert_eq(disabled.data.editable, false)
	assert_true(editor_undo(_undo_redo))
	assert_true(_root.is_editable_instance(_instance))
	assert_true(editor_redo(_undo_redo))
	assert_false(_root.is_editable_instance(_instance))


func test_editable_children_validation_does_not_mutate() -> void:
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	assert_is_error(_handler.set_editable_children({"path": _path}), McpErrorCodes.MISSING_REQUIRED_PARAM)
	for value in [1, "true", null]:
		assert_is_error(_handler.set_editable_children({"path": _path, "editable": value}), McpErrorCodes.WRONG_TYPE)
	assert_is_error(_toggle(true, McpScenePath.from_node(_root, _root)), McpErrorCodes.INVALID_PARAMS)
	assert_is_error(_toggle(true, "/Main/Camera3D"), McpErrorCodes.INVALID_PARAMS)
	assert_is_error(_toggle(true, "/Main/DoesNotExist"), McpErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_handler.set_editable_children({"path": _path, "editable": true, "scene_file": "res://wrong_scene.tscn"}), McpErrorCodes.EDITED_SCENE_MISMATCH)
	assert_false(_root.is_editable_instance(_instance))
	assert_eq(history.get_version(), version)


func test_nested_editable_children_never_enables_ancestors() -> void:
	var nested := _instance.get_node("Nested")
	_assert_locked(_toggle(true, _path + "/Nested"))
	assert_false(_root.is_editable_instance(_instance))
	assert_false(_root.is_editable_instance(nested))
	assert_eq(_toggle(true).data.editable, true)
	assert_eq(_toggle(true, _path + "/Nested").data.editable, true)
	var refused := _toggle(false)
	assert_is_error(refused, McpErrorCodes.INVALID_PARAMS)
	assert_contains(refused.error.message, "would be lost")
	assert_true(_root.is_editable_instance(_instance))
	assert_true(_root.is_editable_instance(nested))
	assert_eq(_toggle(false, _path + "/Nested").data.editable, false)
	assert_eq(_toggle(false).data.editable, false)


func test_editable_children_enable_and_overrides_survive_disk_reload() -> void:
	assert_eq(_toggle(true).data.editable, true)
	assert_eq(_handler.set_property({"path": _path + "/Mesh", "property": "visible", "value": false}).data.value, false)
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	var refused := _toggle(false)
	assert_is_error(refused, McpErrorCodes.INVALID_PARAMS)
	assert_contains(refused.error.message, _path + "/Mesh")
	assert_eq(history.get_version(), version)
	assert_true(_root.is_editable_instance(_instance))
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	assert_eq(ResourceSaver.save(packed, SAVED_INSTANCE_PATH), OK)
	var loaded: PackedScene = ResourceLoader.load(SAVED_INSTANCE_PATH, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var restored := loaded.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var child := restored.get_node(str(_instance.name))
	assert_true(restored.is_editable_instance(child))
	assert_false(child.get_node("Mesh").visible)
	restored.free()
	assert_true(editor_undo(_undo_redo), "refusal must leave the property edit as the latest undo")
	assert_true(_instance.get_node("Mesh").visible)
	assert_eq(_toggle(false).data.editable, false)


func test_disabling_preserves_safe_instance_root_and_direct_local_edits() -> void:
	assert_eq(_toggle(true).data.editable, true)
	assert_eq(_handler.set_property({"path": _path, "property": "visible", "value": false}).data.value, false)
	var created := _handler.create_node({"type": "Node3D", "name": "DirectLocal", "parent_path": _path})
	assert_eq(created.data.path, _path + "/DirectLocal")
	assert_eq(_toggle(false).data.editable, false)
	var restored := _roundtrip()
	var child := restored.get_node(str(_instance.name))
	assert_false(restored.is_editable_instance(child))
	assert_false(child.visible)
	assert_true(child.has_node("DirectLocal"))
	restored.free()


func test_disabling_refuses_local_attachment_beneath_source_owned_child() -> void:
	assert_eq(_toggle(true).data.editable, true)
	assert_eq(_handler.create_node({"type": "Node3D", "name": "NestedLocal", "parent_path": _path + "/Mesh"}).data.path, _path + "/Mesh/NestedLocal")
	var refused := _toggle(false)
	assert_is_error(refused, McpErrorCodes.INVALID_PARAMS)
	assert_true(_root.is_editable_instance(_instance))
	var restored := _roundtrip()
	assert_true(restored.has_node(str(_instance.name) + "/Mesh/NestedLocal"))
	restored.free()
	assert_true(editor_undo(_undo_redo))
	assert_false(_instance.has_node("Mesh/NestedLocal"))
	assert_eq(_toggle(false).data.editable, false)


func test_disabling_refuses_persistent_child_signal_and_group() -> void:
	assert_eq(_toggle(true).data.editable, true)
	var mesh := _instance.get_node("Mesh")
	mesh.connect("visibility_changed", _instance.hide, CONNECT_PERSIST)
	assert_is_error(_toggle(false), McpErrorCodes.INVALID_PARAMS)
	assert_true(mesh.is_connected("visibility_changed", _instance.hide))
	assert_true(_root.is_editable_instance(_instance))
	mesh.disconnect("visibility_changed", _instance.hide)
	mesh.add_to_group("editable_probe_group", true)
	assert_is_error(_toggle(false), McpErrorCodes.INVALID_PARAMS)
	assert_true(mesh.is_in_group("editable_probe_group"))
	assert_true(_root.is_editable_instance(_instance))
	mesh.remove_from_group("editable_probe_group")
	assert_eq(_toggle(false).data.editable, false)
