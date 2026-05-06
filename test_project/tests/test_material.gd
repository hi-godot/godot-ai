@tool
extends McpTestSuite

const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")

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
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)


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


func test_create_shader_requires_shader_path() -> void:
	_cleanup_file(TEST_MATERIAL_PATH)
	var result := _handler.create_material({"path": TEST_MATERIAL_PATH, "type": "shader"})
	assert_is_error(result)


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
	assert_is_error(result, McpErrorCodes.PROPERTY_NOT_ON_CLASS)


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
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_remove_node(node)


func test_assign_node_not_found() -> void:
	_make_material()
	var result := _handler.assign_material({
		"node_path": "/DoesNotExist",
		"resource_path": TEST_MATERIAL_PATH,
	})
	assert_is_error(result, McpErrorCodes.NODE_NOT_FOUND)


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
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
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
