@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
const INSTANCE_FIXTURE := preload("res://tests/fixtures/instance_editing.tscn")

## Tests for MaterialHandler — StandardMaterial3D, ORM, CanvasItemMaterial,
## ShaderMaterial authoring.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: MaterialHandler
var _undo_redo: EditorUndoRedoManager

const TEST_MATERIAL_PATH := "res://tests/_mcp_test_material.tres"
const TEST_MATERIAL_PATH_2 := "res://tests/_mcp_test_material_2.tres"
const TEST_SHADER_PATH := "res://tests/_mcp_test_shader.gdshader"
const TEST_SHADER_MAT_PATH := "res://tests/_mcp_test_shader_mat.tres"


func suite_name() -> String:
	return "material"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = MaterialHandler.new(_undo_redo)


func suite_teardown() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	_cleanup_file(TEST_MATERIAL_PATH_2)
	_cleanup_file(TEST_SHADER_PATH)
	_cleanup_file(TEST_SHADER_MAT_PATH)


func _cleanup_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _make_material(path: String = TEST_MATERIAL_PATH, type_str: String = "standard") -> void:
	_cleanup_file(path)
	_handler.create_material({"path": path, "type": type_str})


func _add_mesh_node(node_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = BoxMesh.new()
	scene_root.add_child(mesh)
	mesh.owner = scene_root
	return mesh


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


# ============================================================================
# material_create
# ============================================================================

func test_create_standard_writes_file() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "standard"})
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_MATERIAL_PATH)
	assert_eq(result.data.type, "standard")
	assert_eq(result.data.class, "StandardMaterial3D")
	assert_true(FileAccess.file_exists(TEST_MATERIAL_PATH), "Material file should exist")


func test_create_orm() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "orm"})
	assert_has_key(result, "data")
	assert_eq(result.data.class, "ORMMaterial3D")


func test_create_canvas_item() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "canvas_item"})
	assert_has_key(result, "data")
	assert_eq(result.data.class, "CanvasItemMaterial")


func test_create_invalid_type() -> void:
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "nonsense"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_requires_res_path() -> void:
	var result := _handler.create_material({"path": "/tmp/foo.tres"})
	assert_is_error(result)


func test_create_requires_valid_suffix() -> void:
	var result := _handler.create_material({"path": "res://foo.txt"})
	assert_is_error(result)


func test_create_rejects_existing_without_overwrite() -> void:
	_make_material()
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH})
	assert_is_error(result)


func test_create_overwrite_allowed() -> void:
	_make_material()
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "overwrite": true})
	assert_has_key(result, "data")
	assert_eq(result.data.overwritten, true,
		"overwritten flag must reflect the pre-existing file")
	assert_true(FileAccess.file_exists(TEST_MATERIAL_PATH),
		"material file should still exist after overwrite")


## Spy McpConnection that counts pause()/resume() calls instead of actually
## touching WebSocket processing state — proves a handler routes its
## ResourceSaver.save through the #288 reentrancy guard without needing a
## live connection.
class _PauseSpyConnection:
	extends McpConnection
	var pause_calls := 0
	var resume_calls := 0

	func pause() -> void:
		pause_calls += 1
		super()

	func resume() -> void:
		resume_calls += 1
		super()


func test_create_material_saves_through_pause_guard() -> void:
	var spy := _PauseSpyConnection.new()
	var handler := MaterialHandler.new(_undo_redo, spy)
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := handler.create_material({"path": TEST_MATERIAL_PATH, "type": "standard"})
	assert_has_key(result, "data")
	assert_eq(spy.pause_calls, 1, "create_material's save must pause processing once (#288 guard)")
	assert_eq(spy.resume_calls, 1, "create_material's save must resume processing once (#288 guard)")
	assert_false(spy.pause_processing, "guard must not leave the connection paused")
	spy.free()


func test_apply_to_node_save_to_saves_through_pause_guard() -> void:
	var spy := _PauseSpyConnection.new()
	var handler := MaterialHandler.new(_undo_redo, spy)
	_cleanup_file(TEST_MATERIAL_PATH)
	var mesh := _add_mesh_node("_McpPauseGuardMesh")
	if mesh == null:
		skip("no open scene to attach a mesh node to")
		spy.free()
		return
	var result := handler.apply_to_node({
		"node_path": McpScenePath.from_node(mesh, EditorInterface.get_edited_scene_root()),
		"type": "standard",
		"save_to": TEST_MATERIAL_PATH,
	})
	assert_has_key(result, "data")
	assert_eq(spy.pause_calls, 1, "apply_to_node's save_to branch must pause processing once (#288 guard)")
	assert_eq(spy.resume_calls, 1, "apply_to_node's save_to branch must resume processing once (#288 guard)")
	_remove_node(mesh)
	spy.free()


func test_create_shader_requires_shader_path() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "shader"})
	assert_is_error(result)


func test_create_material_embeds_uid() -> void:
	# #737: a bare ResourceSaver.save() (what guarded_save used before the fix)
	# writes a .tres with no uid= at all, unlike Godot's own "New Resource"
	# editor flow. create_material must come out matching the editor.
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "standard"})
	assert_has_key(result, "data")
	var uid := ResourceLoader.get_resource_uid(TEST_MATERIAL_PATH)
	assert_true(uid != ResourceUID.INVALID_ID, "freshly created material must carry a uid")


# ============================================================================
# material_set_param
# ============================================================================

func test_set_param_color_hex() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "albedo_color",
		"value": "#ff0000",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	var c: Color = mat.get("albedo_color")
	assert_true(c is Color)
	assert_true(abs(c.r - 1.0) < 0.01, "Red should be 1.0")


func test_set_param_preserves_uid_across_resave() -> void:
	# #737: set_param's undo-callable (_apply_param) loads the material,
	# mutates a property, and resaves via McpResourceIO.guarded_save. Before
	# the fix, a bare ResourceSaver.save() resave silently dropped whatever
	# uid the file already had -- this must survive unchanged.
	_make_material()
	var original_uid := ResourceLoader.get_resource_uid(TEST_MATERIAL_PATH)
	assert_true(original_uid != ResourceUID.INVALID_ID, "precondition: fresh material must have a uid")

	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "albedo_color",
		"value": "#00ff00",
	})
	assert_has_key(result, "data")
	var uid_after_resave := ResourceLoader.get_resource_uid(TEST_MATERIAL_PATH)
	assert_eq(uid_after_resave, original_uid, "resaving an existing material must keep its original uid")


func test_set_param_color_dict() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "albedo_color",
		"value": {"r": 0.5, "g": 0.25, "b": 0.75, "a": 1.0},
	})
	assert_has_key(result, "data")
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	var c: Color = mat.get("albedo_color")
	assert_true(c is Color)
	assert_true(abs(c.r - 0.5) < 0.01, "Red should be 0.5")
	assert_true(abs(c.g - 0.25) < 0.01, "Green should be 0.25")
	assert_true(abs(c.b - 0.75) < 0.01, "Blue should be 0.75")
	assert_true(abs(c.a - 1.0) < 0.01, "Alpha should be 1.0")


func test_set_param_metallic_float() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "metallic",
		"value": 0.9,
	})
	assert_has_key(result, "data")
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	assert_true(abs(float(mat.get("metallic")) - 0.9) < 0.01)


func test_set_param_bool() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "emission_enabled",
		"value": true,
	})
	assert_has_key(result, "data")
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	assert_eq(mat.get("emission_enabled"), true,
		"emission_enabled should be stored as the bool we passed")


func test_set_param_transparency_enum_by_name() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "transparency",
		"value": "alpha",
	})
	assert_has_key(result, "data")
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	assert_eq(int(mat.get("transparency")), BaseMaterial3D.TRANSPARENCY_ALPHA)


func test_set_param_shading_mode_enum() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "shading_mode",
		"value": "unshaded",
	})
	assert_has_key(result, "data")
	var mat: Material = ResourceLoader.load(TEST_MATERIAL_PATH)
	assert_eq(int(mat.get("shading_mode")), BaseMaterial3D.SHADING_MODE_UNSHADED)


func test_set_param_invalid_enum_by_name() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "transparency",
		"value": "not_a_mode",
	})
	assert_is_error(result)


func test_set_param_unknown_property() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "does_not_exist",
		"value": 1.0,
	})
	assert_is_error(result, ErrorCodes.PROPERTY_NOT_ON_CLASS)


func test_set_param_material_not_found() -> void:
	var result := _handler.set_param({
		"path": "res://nope_material.tres",
		"param": "metallic",
		"value": 0.5,
	})
	assert_is_error(result)


func test_set_param_missing_value() -> void:
	_make_material()
	var result := _handler.set_param({
		"path": TEST_MATERIAL_PATH,
		"param": "metallic",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


# ============================================================================
# material_set_shader_param
# ============================================================================

func _make_shader_material() -> bool:
	_cleanup_file(TEST_SHADER_PATH)
	_cleanup_file(TEST_SHADER_MAT_PATH)
	var code := """shader_type spatial;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform vec3 base_color : source_color = vec3(1.0, 1.0, 1.0);
void fragment() { ALBEDO = base_color * (1.0 + pulse); }
"""
	var shader := Shader.new()
	shader.code = code
	if ResourceSaver.save(shader, TEST_SHADER_PATH) != OK:
		return false
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(TEST_SHADER_PATH)
	var result := _handler.create_material({
		"path": TEST_SHADER_MAT_PATH,
		"type": "shader",
		"shader_path": TEST_SHADER_PATH,
	})
	return result.has("data")


func test_set_shader_param_float() -> void:
	if not _make_shader_material():
		assert_true(false, "shader material setup failed")
		return
	var result := _handler.set_shader_param({
		"path": TEST_SHADER_MAT_PATH,
		"param": "pulse",
		"value": 0.7,
	})
	assert_has_key(result, "data")
	var mat: ShaderMaterial = ResourceLoader.load(TEST_SHADER_MAT_PATH)
	assert_true(abs(float(mat.get_shader_parameter("pulse")) - 0.7) < 0.01)


func test_set_shader_param_unknown_uniform() -> void:
	if not _make_shader_material():
		assert_true(false, "shader material setup failed")
		return
	var result := _handler.set_shader_param({
		"path": TEST_SHADER_MAT_PATH,
		"param": "missing_uniform",
		"value": 0.5,
	})
	assert_is_error(result)


func test_set_shader_param_on_non_shader_material() -> void:
	_make_material()  # creates a StandardMaterial3D
	var result := _handler.set_shader_param({
		"path": TEST_MATERIAL_PATH,
		"param": "pulse",
		"value": 0.5,
	})
	assert_is_error(result)


# ============================================================================
# material_get
# ============================================================================

func test_get_returns_properties() -> void:
	_make_material()
	var result := _handler.get_material({"path": TEST_MATERIAL_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.class, "StandardMaterial3D")
	assert_eq(result.data.type, "standard")
	assert_gt(result.data.property_count, 0)


func test_get_includes_shader_parameters() -> void:
	if not _make_shader_material():
		assert_true(false, "shader material setup failed")
		return
	_handler.set_shader_param({"path": TEST_SHADER_MAT_PATH, "param": "pulse", "value": 0.5})
	var result := _handler.get_material({"path": TEST_SHADER_MAT_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.class, "ShaderMaterial")
	assert_gt(result.data.shader_parameters.size(), 0)


# ============================================================================
# material_assign
# ============================================================================

func test_assign_material_to_mesh() -> void:
	_make_material()
	var node := _add_mesh_node("TestAssignMesh") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.assign_material({
		"node_path": McpScenePath.from_node(node, scene_root),
		"resource_path": TEST_MATERIAL_PATH,
		"slot": "override",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	assert_eq(result.data.property, "material_override")
	assert_eq(result.data.material_created, false)
	## Read back from the node: the response fields are computed before
	## commit_action, so only the stored override proves the assign landed.
	var gi := node as GeometryInstance3D
	assert_true(gi != null and gi.material_override != null, "material_override should actually be set on the node")
	if gi != null and gi.material_override != null:
		assert_eq(gi.material_override.resource_path, TEST_MATERIAL_PATH)
	_remove_node(node)


func test_assign_create_if_missing() -> void:
	var node := _add_mesh_node("TestAssignCreate") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.assign_material({
		"node_path": McpScenePath.from_node(node, scene_root),
		"create_if_missing": true,
		"type": "standard",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.material_created, true)
	assert_eq(result.data.material_class, "StandardMaterial3D")
	_remove_node(node)


func test_assign_without_resource_or_create_fails() -> void:
	var node := _add_mesh_node("TestAssignFail") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.assign_material({
		"node_path": McpScenePath.from_node(node, scene_root),
	})
	assert_is_error(result)
	_remove_node(node)


func test_assign_surface_index_out_of_range() -> void:
	_make_material()
	var node := _add_mesh_node("TestAssignSurface") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.assign_material({
		"node_path": McpScenePath.from_node(node, scene_root),
		"resource_path": TEST_MATERIAL_PATH,
		"slot": "surface_99",
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	_remove_node(node)


func test_assign_node_not_found() -> void:
	_make_material()
	var result := _handler.assign_material({
		"node_path": "/DoesNotExist",
		"resource_path": TEST_MATERIAL_PATH,
	})
	assert_is_error(result, ErrorCodes.NODE_NOT_FOUND)


# ============================================================================
# material_inspect_surfaces
# ============================================================================

func _test_resource_descriptor(resource: Resource) -> Variant:
	if resource == null:
		return null
	return {
		"class": resource.get_class(),
		"resource_name": resource.resource_name,
		"resource_path": resource.resource_path,
		"instance_id": str(resource.get_instance_id()),
	}


func _test_surface(index: int, surface_name: Variant, base: Material, local: Material,
		active: Material, source: String) -> Dictionary:
	return {
		"index": index,
		"name": surface_name,
		"slot": "surface_%d" % index,
		"mesh_material": _test_resource_descriptor(base),
		"surface_override": _test_resource_descriptor(local),
		"active_material": _test_resource_descriptor(active),
		"active_source": source,
	}


func _make_door_mesh(wood: Material, glass: Material) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.RIGHT, Vector3(2, 0, 0), Vector3(1, 1, 0)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_name(0, "Wood")
	mesh.surface_set_name(1, "Glass")
	mesh.surface_set_material(0, wood)
	mesh.surface_set_material(1, glass)
	mesh.resource_name = "DoorMesh"
	return mesh


func test_inspect_surfaces_reports_door_layers_and_assignable_slots() -> void:
	var door := track(_add_mesh_node("_McpSurfaceDoor")) as MeshInstance3D
	if door == null:
		skip("No scene open")
		return
	var wood := StandardMaterial3D.new()
	wood.resource_name = "Wood material"
	var glass := ORMMaterial3D.new()
	glass.resource_name = "Glass material"
	var overlay := StandardMaterial3D.new()
	var whole := StandardMaterial3D.new()
	var mesh := _make_door_mesh(wood, glass)
	door.mesh = mesh
	door.material_overlay = overlay
	var root := EditorInterface.get_edited_scene_root()
	var path := McpScenePath.from_node(door, root)
	var params := {"node_path": String(door.name), "scene_file": root.scene_file_path}
	var base := _handler.inspect_surfaces(params)
	assert_eq(base, {"data": {
		"node_path": path,
		"mesh": _test_resource_descriptor(mesh),
		"material_override": null,
		"material_overlay": _test_resource_descriptor(overlay),
		"surface_count": 2,
		"surfaces": [
			_test_surface(0, "Wood", wood, null, wood, "mesh"),
			_test_surface(1, "Glass", glass, null, glass, "mesh"),
		],
	}})
	var rows: Array = base.get("data", {}).get("surfaces", [])
	if rows.size() != 2:
		assert_eq(rows.size(), 2, "Both door surfaces must be present before assigning")
		return

	_make_material()
	var assigned := _handler.assign_material({
		"node_path": path,
		"resource_path": TEST_MATERIAL_PATH,
		"slot": rows[1].get("slot", ""),
	})
	assert_eq(assigned.get("data", {}).get("slot"), "surface_1")
	var surface_material := door.get_surface_override_material(1)
	if surface_material == null:
		assert_ne(surface_material, null, "The reported slot must accept a material assignment")
		return
	assert_eq(surface_material.resource_path, TEST_MATERIAL_PATH)
	assert_eq(door.get_surface_override_material(0), null)

	door.material_override = whole
	var covered: Dictionary = _handler.inspect_surfaces(params).get("data", {})
	assert_eq(covered.get("material_override"), _test_resource_descriptor(whole))
	assert_eq(covered.get("material_overlay"), _test_resource_descriptor(overlay))
	assert_eq(covered.get("surfaces"), [
		_test_surface(0, "Wood", wood, null, whole, "material_override"),
		_test_surface(1, "Glass", glass, surface_material, whole, "material_override"),
	])

	door.material_override = null
	var uncovered: Dictionary = _handler.inspect_surfaces(params).get("data", {})
	assert_has_key(uncovered, "material_override")
	assert_eq(uncovered.get("material_override"), null)
	assert_eq(uncovered.get("surfaces"), [
		_test_surface(0, "Wood", wood, null, wood, "mesh"),
		_test_surface(1, "Glass", glass, surface_material, surface_material, "surface_override"),
	])
	assert_true(editor_undo(_undo_redo), "Undoing the fixture assignment should succeed")
	assert_eq(door.get_surface_override_material(1), null)
	assert_eq(_handler.inspect_surfaces(params), base)


func test_inspect_surfaces_reports_anonymous_identity_without_editing() -> void:
	var door := track(_add_mesh_node("_McpAnonymousMaterials")) as MeshInstance3D
	if door == null:
		skip("No scene open")
		return
	var shared := StandardMaterial3D.new()
	var distinct := StandardMaterial3D.new()
	var mesh := _make_door_mesh(shared, distinct)
	mesh.surface_set_name(1, "")
	door.mesh = mesh
	door.set_surface_override_material(0, shared)
	door.material_override = shared
	var root := EditorInterface.get_edited_scene_root()
	var params := {"node_path": McpScenePath.from_node(door, root)}
	var scene_history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(root))
	var global_history := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	var scene_version := scene_history.get_version()
	var global_version := global_history.get_version()
	# mark_scene_as_unsaved() emits history_changed even when the undo version stays fixed.
	var history_changes := [0]
	var on_history_change := func() -> void: history_changes[0] += 1
	_undo_redo.history_changed.connect(on_history_change)
	var first := _handler.inspect_surfaces(params)
	var second := _handler.inspect_surfaces(params)
	_undo_redo.history_changed.disconnect(on_history_change)

	assert_eq(second, first, "Repeated reads retain the same live resource IDs")
	var rows: Variant = first.get("data", {}).get("surfaces")
	assert_eq(rows, [
		_test_surface(0, "Wood", shared, shared, shared, "material_override"),
		_test_surface(1, null, distinct, null, shared, "material_override"),
	], "Precedence is independent of resource identity, and anonymous resources get distinct IDs")
	assert_eq(scene_history.get_version(), scene_version)
	assert_eq(global_history.get_version(), global_version)
	assert_eq(history_changes[0], 0, "Inspection must not mark the scene as unsaved")
	assert_eq(door.mesh, mesh)
	assert_eq(mesh.surface_get_material(0), shared)
	assert_eq(mesh.surface_get_material(1), distinct)
	assert_eq(door.get_surface_override_material(0), shared)
	assert_eq(door.material_override, shared)
	assert_eq(shared.resource_name, "")
	assert_eq(shared.resource_path, "")
	assert_eq(distinct.resource_name, "")
	assert_eq(distinct.resource_path, "")

	door.material_override = null
	var without_whole := _handler.inspect_surfaces(params)
	assert_eq(without_whole.get("data", {}).get("surfaces"), [
		_test_surface(0, "Wood", shared, shared, shared, "surface_override"),
		_test_surface(1, null, distinct, null, distinct, "mesh"),
	])


func test_inspect_surfaces_distinguishes_meshless_empty_and_primitive() -> void:
	var node := track(_add_mesh_node("_McpSurfaceMeshKinds")) as MeshInstance3D
	if node == null:
		skip("No scene open")
		return
	var box := node.mesh
	var path := McpScenePath.from_node(node, EditorInterface.get_edited_scene_root())
	var params := {"node_path": path}
	var overlay := StandardMaterial3D.new()
	node.material_overlay = overlay
	var primitive: Dictionary = _handler.inspect_surfaces(params).get("data", {})
	assert_eq(primitive.get("mesh"), _test_resource_descriptor(box))
	assert_eq(primitive.get("material_overlay"), _test_resource_descriptor(overlay))
	assert_eq(primitive.get("surface_count"), 1)
	assert_eq(primitive.get("surfaces"), [_test_surface(0, null, null, null, null, "none")])

	var empty_mesh := ArrayMesh.new()
	node.mesh = empty_mesh
	var empty: Dictionary = _handler.inspect_surfaces(params).get("data", {})
	assert_eq(empty.get("mesh"), _test_resource_descriptor(empty_mesh))
	assert_eq(empty.get("surface_count"), 0)
	assert_eq(empty.get("surfaces"), [])

	node.mesh = null
	var meshless := _handler.inspect_surfaces(params)
	assert_eq(meshless, {"data": {
		"node_path": path,
		"mesh": null,
		"material_override": null,
		"material_overlay": _test_resource_descriptor(overlay),
		"surface_count": 0,
		"surfaces": [],
	}})


func test_inspect_surfaces_reads_a_locked_instance_child() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene open")
		return
	var instance := track(INSTANCE_FIXTURE.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)) as Node3D
	instance.name = "_McpLockedSurfaceInstance"
	root.add_child(instance)
	instance.owner = root
	var child := instance.get_node("Mesh") as MeshInstance3D
	var path := McpScenePath.from_node(child, root)
	assert_eq(child.owner, instance)
	assert_false(root.is_editable_instance(instance))
	var result := _handler.inspect_surfaces({"node_path": path})
	assert_eq(result, {"data": {
		"node_path": path,
		"mesh": _test_resource_descriptor(child.mesh),
		"material_override": null,
		"material_overlay": null,
		"surface_count": 1,
		"surfaces": [_test_surface(0, null, null, null, null, "none")],
	}})
	assert_false(root.is_editable_instance(instance))


func test_inspect_surfaces_rejects_wrong_paths_and_scene_mismatch() -> void:
	var mesh := track(_add_mesh_node("_McpSurfacePath")) as MeshInstance3D
	if mesh == null:
		skip("No scene open")
		return
	var root := EditorInterface.get_edited_scene_root()
	var non_mesh := track(Node3D.new()) as Node3D
	non_mesh.name = "_McpSurfaceNotMesh"
	root.add_child(non_mesh)
	var outside := track(MeshInstance3D.new()) as MeshInstance3D
	outside.name = "_McpSurfaceOutside"
	root.get_tree().root.add_child(outside)
	var outside_path := String(outside.get_path())
	for path in [outside_path, String(root.get_path_to(outside))]:
		assert_eq(root.get_node_or_null(path), outside, "Outside path resolves in the live tree: %s" % path)
		assert_is_error(_handler.inspect_surfaces({"node_path": path}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_handler.inspect_surfaces({"node_path": "/_MissingSurfaceNode"}), ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_handler.inspect_surfaces({"node_path": String(non_mesh.name)}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.inspect_surfaces({}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_handler.inspect_surfaces({"node_path": 12}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.inspect_surfaces({"node_path": String(mesh.name), "scene_file": false}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.inspect_surfaces({
		"node_path": String(mesh.name),
		"scene_file": "res://_mcp_wrong_material_scene.tscn",
	}), ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_eq(EditorInterface.get_edited_scene_root(), root)


# ============================================================================
# material_apply_to_node
# ============================================================================

func test_apply_to_node_inline() -> void:
	var node := _add_mesh_node("TestApplyInline") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_to_node({
		"node_path": McpScenePath.from_node(node, scene_root),
		"type": "standard",
		"params": {"albedo_color": "#00ff00", "metallic": 0.5},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.material_created, true)
	assert_eq(result.data.saved_to, "")
	assert_contains(result.data.applied_params, "albedo_color")
	assert_contains(result.data.applied_params, "metallic")
	# Verify the node actually got a material.
	var mi := node as MeshInstance3D
	assert_true(mi.material_override != null, "material_override should be set")
	_remove_node(node)


func test_apply_to_node_invalid_type() -> void:
	var node := _add_mesh_node("TestApplyInvalid") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_to_node({
		"node_path": McpScenePath.from_node(node, scene_root),
		"type": "garbage",
		"params": {},
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	_remove_node(node)


func test_apply_to_node_with_save_to() -> void:
	_cleanup_file(TEST_MATERIAL_PATH_2)
	var node := _add_mesh_node("TestApplySave") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_to_node({
		"node_path": McpScenePath.from_node(node, scene_root),
		"type": "standard",
		"params": {"metallic": 0.8},
		"save_to": TEST_MATERIAL_PATH_2,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.saved_to, TEST_MATERIAL_PATH_2)
	assert_true(FileAccess.file_exists(TEST_MATERIAL_PATH_2))
	_remove_node(node)


func test_apply_to_node_save_to_refuses_existing_file_without_overwrite() -> void:
	# #685: save_to must not silently clobber an existing .tres — undo only
	# restores the node's slot assignment, never the file contents.
	_make_material(TEST_MATERIAL_PATH_2)
	var before := FileAccess.get_file_as_bytes(TEST_MATERIAL_PATH_2)
	var node := _add_mesh_node("TestApplyNoClobber") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_to_node({
		"node_path": McpScenePath.from_node(node, scene_root),
		"type": "standard",
		"save_to": TEST_MATERIAL_PATH_2,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_true(
		result.error.message.contains("overwrite=true"),
		"Error should name the overwrite escape hatch"
	)
	var after := FileAccess.get_file_as_bytes(TEST_MATERIAL_PATH_2)
	assert_eq(after, before, "Refused save must leave the existing file untouched")
	_remove_node(node)


func test_apply_to_node_save_to_overwrites_with_flag() -> void:
	_make_material(TEST_MATERIAL_PATH_2)
	var node := _add_mesh_node("TestApplyOverwrite") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_to_node({
		"node_path": McpScenePath.from_node(node, scene_root),
		"type": "standard",
		"params": {"metallic": 0.5},
		"save_to": TEST_MATERIAL_PATH_2,
		"overwrite": true,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.saved_to, TEST_MATERIAL_PATH_2)
	assert_true(result.data.overwritten, "Response should report the overwrite")
	_remove_node(node)


# ============================================================================
# material_apply_preset
# ============================================================================

func test_apply_preset_metal_to_node() -> void:
	var node := _add_mesh_node("TestPresetMetal") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_preset({
		"preset": "metal",
		"node_path": McpScenePath.from_node(node, scene_root),
	})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "metal")
	assert_true(result.data.assigned)
	_remove_node(node)


func test_apply_preset_glass_to_node() -> void:
	var node := _add_mesh_node("TestPresetGlass") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_preset({
		"preset": "glass",
		"node_path": McpScenePath.from_node(node, scene_root),
	})
	assert_has_key(result, "data")
	# Glass preset must coerce transparency="alpha" -> enum
	var mi := node as MeshInstance3D
	var mat := mi.material_override as BaseMaterial3D
	assert_true(mat != null)
	assert_eq(int(mat.transparency), BaseMaterial3D.TRANSPARENCY_ALPHA)
	_remove_node(node)


func test_metal_preset_inline_values_survive_resource_save_reload() -> void:
	var node := _add_mesh_node("MetalPresetInlinePersistence") as MeshInstance3D
	assert_true(node != null)
	if node == null:
		return
	var node_path := McpScenePath.from_node(node, EditorInterface.get_edited_scene_root())
	for overrides in [{}, {"metallic": 0.5, "roughness": 0.75}]:
		var result := _handler.apply_preset({"preset": "metal", "node_path": node_path, "overrides": overrides})
		assert_eq(result.get("data", {}).get("assigned", false), true)
		var material := node.material_override as BaseMaterial3D
		var metallic: float = overrides.get("metallic", 1.0)
		var roughness: float = overrides.get("roughness", 0.25)
		assert_eq(material.metallic, metallic)
		assert_eq(material.roughness, roughness)
		var path := "res://tests/_metal_inline_%d.tres" % Time.get_ticks_usec()
		assert_eq(ResourceSaver.save(material, path), OK)
		var stored: BaseMaterial3D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		_cleanup_file(path)
		assert_eq(stored.metallic, metallic, "saved metal preset must retain metallic strength")
		assert_eq(stored.roughness, roughness, "saved metal preset must retain roughness")
		assert_true(stored is StandardMaterial3D)
	_remove_node(node)


func test_metal_preset_disk_and_assigned_values_survive_reload() -> void:
	var node := _add_mesh_node("MetalPresetDiskPersistence") as MeshInstance3D
	assert_true(node != null)
	if node == null:
		return
	var node_path := McpScenePath.from_node(node, EditorInterface.get_edited_scene_root())
	for assign in [false, true]:
		var path := "res://tests/_metal_saved_%d.tres" % Time.get_ticks_usec()
		var params := {"preset": "metal", "path": path}
		if assign:
			params.node_path = node_path
			params.overrides = {"metallic": 0.5, "roughness": 0.75}
		var result := _handler.apply_preset(params)
		assert_eq(result.get("data", {}).get("saved_to_disk", false), true)
		assert_eq(result.data.assigned, assign)
		var stored: BaseMaterial3D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		_cleanup_file(path)
		assert_eq(stored.metallic, 0.5 if assign else 1.0)
		assert_eq(stored.roughness, 0.75 if assign else 0.25)
		assert_true(stored is StandardMaterial3D)
		if assign:
			assert_eq(node.material_override.metallic, stored.metallic)
			assert_eq(node.material_override.roughness, stored.roughness)
	_remove_node(node)


func test_apply_preset_unknown() -> void:
	var node := _add_mesh_node("TestPresetUnknown") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_preset({
		"preset": "not_a_real_preset",
		"node_path": McpScenePath.from_node(node, scene_root),
	})
	assert_is_error(result)
	_remove_node(node)


func test_apply_preset_to_disk() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.apply_preset({
		"preset": "emissive",
		"path": TEST_MATERIAL_PATH,
	})
	assert_has_key(result, "data")
	assert_true(FileAccess.file_exists(TEST_MATERIAL_PATH))


func test_apply_preset_requires_target() -> void:
	var result := _handler.apply_preset({"preset": "metal"})
	assert_is_error(result)


func test_apply_preset_with_overrides() -> void:
	var node := _add_mesh_node("TestPresetOverrides") as Node
	if node == null:
		skip("No scene root — is a scene open?")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.apply_preset({
		"preset": "metal",
		"node_path": McpScenePath.from_node(node, scene_root),
		"overrides": {"metallic": 0.5, "roughness": 0.9},
	})
	assert_has_key(result, "data")
	var mi := node as MeshInstance3D
	var mat := mi.material_override as BaseMaterial3D
	assert_true(mat != null)
	assert_true(abs(mat.metallic - 0.5) < 0.01)
	assert_true(abs(mat.roughness - 0.9) < 0.01)
	_remove_node(node)


func test_apply_preset_invalid_path_reported_before_overwrite() -> void:
	## Order parity with create_material: a path that both EXISTS and is
	## invalid must fail path validation, not the exists/overwrite check.
	var result := _handler.apply_preset({
		"preset": "metal",
		"path": "res://project.godot",
	})
	assert_has_key(result, "error")
	assert_false(str(result.error.message).contains("already exists"),
		"invalid path must be reported as invalid, not as an overwrite conflict")
