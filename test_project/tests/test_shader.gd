@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const ShaderHandler := preload("res://addons/godot_ai/handlers/shader_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")

## Tests for ShaderHandler — raw .gdshader / .gdshaderinc create, read,
## validate, list, and patch, plus inline shader materials.
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

const TEST_SHADER_PATH := "res://tests/_mcp_test_shader_suite.gdshader"
const TEST_INCLUDE_PATH := "res://tests/_mcp_test_shader_suite.gdshaderinc"
const TEST_MATERIAL_PATH := "res://tests/_mcp_test_shader_suite_mat.tres"

const VALID_SHADER := """shader_type spatial;
render_mode unshaded;

uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.0, 1.0);
uniform float pulse : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	ALBEDO = tint.rgb * pulse;
}
"""

const VALID_INCLUDE := """uniform float shared_strength : hint_range(0.0, 1.0) = 1.0;

float amplify(float value) {
	return value * shared_strength;
}
"""

const INVALID_SHADER := """shader_type spatial;

void fragment() {
	ALBEDO = vec3(1.0)
}
"""

const INVALID_INCLUDE := """float broken(float value) {
	return value * ;
}
"""

var _shader_handler: ShaderHandler
var _material_handler: MaterialHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "shader"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_shader_handler = ShaderHandler.new()
	_material_handler = MaterialHandler.new(_undo_redo)


func suite_teardown() -> void:
	_cleanup_artifact(TEST_SHADER_PATH)
	_cleanup_artifact(TEST_INCLUDE_PATH)
	_cleanup_artifact(TEST_MATERIAL_PATH)


func _cleanup_artifact(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if FileAccess.file_exists(path + ".uid"):
		DirAccess.remove_absolute(path + ".uid")


func _create_valid_shader(path: String = TEST_SHADER_PATH) -> Dictionary:
	_cleanup_artifact(path)
	return _shader_handler.create_shader({
		"resource_path": path, "code": VALID_SHADER, "overwrite": true,
	})


# ============================================================================
# shader_create
# ============================================================================

func test_create_writes_valid_shader() -> void:
	var result := _create_valid_shader()
	assert_has_key(result, "data")
	assert_eq(result.data.path, TEST_SHADER_PATH)
	assert_eq(result.data.kind, "shader")
	assert_eq(result.data.shader_type, "spatial")
	assert_true(FileAccess.file_exists(TEST_SHADER_PATH), "Shader file should exist")
	assert_false(result.data.undoable, "Raw shader writes are not undoable")
	assert_eq(result.data.overwritten, false)


func test_create_returns_uniform_descriptors() -> void:
	var result := _create_valid_shader()
	assert_has_key(result, "data")
	assert_eq(result.data.uniform_count, 2, "Two uniforms declared")
	var names: Array[String] = []
	for uniform in result.data.uniforms:
		names.append(uniform.name)
		assert_true(uniform.has("type"), "Uniform must carry a type")
		assert_true(uniform.has("hint_string"), "Uniform must carry its hint string")
	assert_true(names.has("tint"), "tint uniform should be reported")
	assert_true(names.has("pulse"), "pulse uniform should be reported")


func test_create_rejects_invalid_code_without_writing() -> void:
	_cleanup_artifact(TEST_SHADER_PATH)
	var result := _shader_handler.create_shader({
		"resource_path": TEST_SHADER_PATH, "code": INVALID_SHADER,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	assert_gt(result.error.data.diagnostics.size(), 0, "Parse failure must report diagnostics")
	assert_eq(result.error.data.diagnostics[0].level, "error")
	assert_false(FileAccess.file_exists(TEST_SHADER_PATH), "Invalid code must not be written")


func test_create_rejects_existing_without_overwrite() -> void:
	var first := _create_valid_shader()
	assert_has_key(first, "data")
	var second := _shader_handler.create_shader({
		"resource_path": TEST_SHADER_PATH, "code": VALID_SHADER,
	})
	assert_is_error(second, ErrorCodes.INVALID_PARAMS)


func test_create_overwrite_replaces_content() -> void:
	var first := _create_valid_shader()
	assert_has_key(first, "data")
	var changed := VALID_SHADER.replace("0.5", "0.9")
	var second := _shader_handler.create_shader({
		"resource_path": TEST_SHADER_PATH, "code": changed, "overwrite": true,
	})
	assert_has_key(second, "data")
	assert_eq(second.data.overwritten, true)
	var loaded := ResourceLoader.load(TEST_SHADER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	assert_true(loaded != null)
	assert_true(loaded.get_code().contains("0.9"), "Overwrite should persist new code")


func test_create_include_validates_and_reports_kind() -> void:
	_cleanup_artifact(TEST_INCLUDE_PATH)
	var result := _shader_handler.create_shader({
		"resource_path": TEST_INCLUDE_PATH, "code": VALID_INCLUDE,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "include")
	assert_true(FileAccess.file_exists(TEST_INCLUDE_PATH), "Include file should exist")


func test_create_include_rejects_invalid_code() -> void:
	_cleanup_artifact(TEST_INCLUDE_PATH)
	var result := _shader_handler.create_shader({
		"resource_path": TEST_INCLUDE_PATH, "code": INVALID_INCLUDE,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	assert_gt(result.error.data.errors.size(), 0, "Include parse failure must report errors")
	assert_false(FileAccess.file_exists(TEST_INCLUDE_PATH), "Invalid include must not be written")


func test_create_rejects_bad_extension() -> void:
	var result := _shader_handler.create_shader({
		"resource_path": "res://tests/_mcp_test_shader_suite.txt", "code": VALID_SHADER,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_rejects_missing_directory() -> void:
	var result := _shader_handler.create_shader({
		"resource_path": "res://tests/_mcp_missing_dir/x.gdshader", "code": VALID_SHADER,
	})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_create_rejects_missing_code() -> void:
	var result := _shader_handler.create_shader({"resource_path": TEST_SHADER_PATH})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


# ============================================================================
# shader_get
# ============================================================================

func test_get_returns_code_and_metadata() -> void:
	var created := _create_valid_shader()
	assert_has_key(created, "data")
	var result := _shader_handler.get_shader({"path": TEST_SHADER_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.kind, "shader")
	assert_eq(result.data.resource_class, "Shader")
	assert_eq(result.data.shader_type, "spatial")
	assert_eq(result.data.code, VALID_SHADER)
	assert_eq(result.data.uniform_count, 2)
	assert_true(result.data.render_modes.has("unshaded"), "render_mode should be reported")


func test_get_include_returns_shader_include() -> void:
	_cleanup_artifact(TEST_INCLUDE_PATH)
	var created := _shader_handler.create_shader({
		"resource_path": TEST_INCLUDE_PATH, "code": VALID_INCLUDE,
	})
	assert_has_key(created, "data")
	var result := _shader_handler.get_shader({"path": TEST_INCLUDE_PATH})
	assert_has_key(result, "data")
	assert_eq(result.data.resource_class, "ShaderInclude")
	assert_eq(result.data.code, VALID_INCLUDE)


func test_get_missing_file_errors() -> void:
	_cleanup_artifact(TEST_SHADER_PATH)
	var result := _shader_handler.get_shader({"path": TEST_SHADER_PATH})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


# ============================================================================
# shader_validate
# ============================================================================

func test_validate_accepts_valid_shader() -> void:
	var result := _shader_handler.validate_shader({"code": VALID_SHADER})
	assert_has_key(result, "data")
	assert_true(result.data.valid, "Valid shader should pass validation")
	assert_eq(result.data.errors.size(), 0)
	assert_eq(result.data.uniform_count, 2)


func test_validate_reports_invalid_shader() -> void:
	var result := _shader_handler.validate_shader({"code": INVALID_SHADER})
	assert_has_key(result, "data")
	assert_false(result.data.valid, "Invalid shader must fail validation")
	assert_gt(result.data.errors.size(), 0, "Errors should carry the parse failure")


func test_validate_include_kind() -> void:
	var valid := _shader_handler.validate_shader({"code": VALID_INCLUDE, "kind": "include"})
	assert_has_key(valid, "data")
	assert_true(valid.data.valid, "Valid include should pass validation")
	var invalid := _shader_handler.validate_shader({"code": INVALID_INCLUDE, "kind": "include"})
	assert_has_key(invalid, "data")
	assert_false(invalid.data.valid, "Invalid include must fail validation")


# ============================================================================
# shader_list
# ============================================================================

func test_list_finds_created_files() -> void:
	var shader_result := _create_valid_shader()
	assert_has_key(shader_result, "data")
	_cleanup_artifact(TEST_INCLUDE_PATH)
	var include_result := _shader_handler.create_shader({
		"resource_path": TEST_INCLUDE_PATH, "code": VALID_INCLUDE,
	})
	assert_has_key(include_result, "data")
	var result := _shader_handler.list_shaders({"root": "res://tests"})
	assert_has_key(result, "data")
	var paths: Array[String] = []
	for entry in result.data.shaders:
		paths.append(entry.path)
	assert_true(paths.has(TEST_SHADER_PATH), "List should include the shader")
	assert_true(paths.has(TEST_INCLUDE_PATH), "List should include the include")


# ============================================================================
# shader_patch
# ============================================================================

func test_patch_replaces_and_revalidates() -> void:
	var created := _create_valid_shader()
	assert_has_key(created, "data")
	var result := _shader_handler.patch_shader({
		"path": TEST_SHADER_PATH, "old_text": "= 0.5;", "new_text": "= 0.75;",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.replacements, 1)
	var loaded := ResourceLoader.load(TEST_SHADER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	assert_true(loaded != null)
	assert_true(loaded.get_code().contains("0.75"), "Patched code should be on disk")


func test_patch_rejects_invalid_result_and_preserves_file() -> void:
	var created := _create_valid_shader()
	assert_has_key(created, "data")
	var before := (ResourceLoader.load(TEST_SHADER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Shader).get_code()
	var result := _shader_handler.patch_shader({
		"path": TEST_SHADER_PATH,
		"old_text": "ALBEDO = tint.rgb * pulse;",
		"new_text": "ALBEDO = tint.rgb * pulse",
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	assert_gt(result.error.data.errors.size(), 0, "Invalid patch must report errors")
	var after := (ResourceLoader.load(TEST_SHADER_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as Shader).get_code()
	assert_eq(after, before, "Failed patch must preserve the existing file")


func test_patch_requires_unique_match_without_replace_all() -> void:
	var created := _create_valid_shader()
	assert_has_key(created, "data")
	var ambiguous := _shader_handler.patch_shader({
		"path": TEST_SHADER_PATH, "old_text": "uniform", "new_text": "uniform",
	})
	assert_is_error(ambiguous, ErrorCodes.INVALID_PARAMS)
	var replace_all := _shader_handler.patch_shader({
		"path": TEST_SHADER_PATH, "old_text": "uniform", "new_text": "uniform",
		"replace_all": true,
	})
	assert_has_key(replace_all, "data")
	assert_eq(replace_all.data.replacements, 2)


func test_patch_missing_old_text_errors() -> void:
	var created := _create_valid_shader()
	assert_has_key(created, "data")
	var result := _shader_handler.patch_shader({
		"path": TEST_SHADER_PATH, "old_text": "not_in_file_anywhere", "new_text": "x",
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)


# ============================================================================
# material_create inline shader
# ============================================================================

func test_inline_shader_material_embeds_compiled_shader() -> void:
	_cleanup_artifact(TEST_MATERIAL_PATH)
	var result := _material_handler.create_material({
		"path": TEST_MATERIAL_PATH, "type": "shader", "code": VALID_SHADER,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.inline_shader, true)
	var mat := ResourceLoader.load(TEST_MATERIAL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ShaderMaterial
	assert_true(mat != null, "Inline material should load as ShaderMaterial")
	assert_true(mat.shader is Shader, "Inline shader should be embedded")
	assert_true(mat.shader.get_code().contains("tint"), "Embedded code should match the request")


func test_inline_shader_material_rejects_invalid_code() -> void:
	_cleanup_artifact(TEST_MATERIAL_PATH)
	var result := _material_handler.create_material({
		"path": TEST_MATERIAL_PATH, "type": "shader", "code": INVALID_SHADER,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_false(FileAccess.file_exists(TEST_MATERIAL_PATH), "Invalid inline shader must not be saved")


func test_inline_shader_material_rejects_code_and_path() -> void:
	_cleanup_artifact(TEST_MATERIAL_PATH)
	var result := _material_handler.create_material({
		"path": TEST_MATERIAL_PATH, "type": "shader",
		"code": VALID_SHADER, "shader_path": TEST_SHADER_PATH,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
