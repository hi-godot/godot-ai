@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const PhysicsHandler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")
const CurveHandler := preload("res://addons/godot_ai/handlers/curve_handler.gd")
const UiHandler := preload("res://addons/godot_ai/handlers/ui_handler.gd")
const Fixture := preload("res://tests/fixtures/instance_editing.tscn")

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _root: Node
var _instance: Node3D
var _path: String


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
	_root.set_editable_instance(_instance.get_node("Nested"), false)
	_root.set_editable_instance(_instance, false)
	_root.remove_child(_instance)
	_instance.queue_free()


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
