@tool
extends McpTestSuite

## Tests for EnvironmentHandler — create Environment + Sky + SkyMaterial.

var _handler: EnvironmentHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "environment"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = EnvironmentHandler.new(_undo_redo)


func _add_world_env(env_name: String) -> WorldEnvironment:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var we := WorldEnvironment.new()
	we.name = env_name
	scene_root.add_child(we)
	we.set_owner(scene_root)
	return we


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()


# ----- validation -----

func test_create_no_home_errors() -> void:
	var result := _handler.create_environment({"preset": "default"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_both_homes_errors() -> void:
	var result := _handler.create_environment({
		"path": "/Main/World",
		"resource_path": "res://env.tres",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_invalid_preset() -> void:
	var result := _handler.create_environment({
		"path": "/Main/World",
		"preset": "zapruder",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_create_target_not_world_environment() -> void:
	var result := _handler.create_environment({
		"path": "/Main/Camera3D",  # Camera3D, not WorldEnvironment
		"preset": "default",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "WorldEnvironment")


# ----- inline assign happy paths -----

func test_create_default_assigns_environment_with_sky() -> void:
	var we := _add_world_env("TestEnvDefault")
	if we == null:
		skip("No scene root")
		return
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "default",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.preset, "default")
	assert_true(result.data.sky_created)
	assert_true(result.data.undoable)
	# Assert on stored Variant — per CLAUDE.md.
	assert_true(we.environment is Environment)
	assert_true(we.environment.sky is Sky)
	assert_true(we.environment.sky.sky_material is ProceduralSkyMaterial)
	_remove_node(we)


func test_create_sunset_tints_sky_material() -> void:
	var we := _add_world_env("TestEnvSunset")
	if we == null:
		skip("No scene root")
		return
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "sunset",
	})
	assert_has_key(result, "data")
	var mat: ProceduralSkyMaterial = we.environment.sky.sky_material
	# Sunset horizon is orange — check it's *not* the default bluish.
	assert_true(mat.sky_horizon_color is Color)
	assert_true(mat.sky_horizon_color.r > mat.sky_horizon_color.b, "Sunset horizon should be warm (r > b)")
	_remove_node(we)


func test_create_fog_enables_volumetric_fog() -> void:
	var we := _add_world_env("TestEnvFog")
	if we == null:
		skip("No scene root")
		return
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "fog",
	})
	assert_has_key(result, "data")
	assert_true(we.environment.volumetric_fog_enabled)
	assert_true(we.environment.volumetric_fog_density > 0.0)
	_remove_node(we)


func test_create_sky_false_skips_sky_chain() -> void:
	var we := _add_world_env("TestEnvNoSky")
	if we == null:
		skip("No scene root")
		return
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "default",
		"sky": false,
	})
	assert_has_key(result, "data")
	assert_false(result.data.sky_created)
	assert_true(we.environment.sky == null)
	_remove_node(we)


func test_create_properties_override_preset() -> void:
	var we := _add_world_env("TestEnvOverride")
	if we == null:
		skip("No scene root")
		return
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "default",
		"properties": {"ambient_light_energy": 2.5},
	})
	assert_has_key(result, "data")
	assert_eq(we.environment.ambient_light_energy, 2.5)
	_remove_node(we)


func test_create_undo_restores_previous_environment() -> void:
	var we := _add_world_env("TestEnvUndo")
	if we == null:
		skip("No scene root")
		return
	var prev_env = we.environment  # likely null
	var result := _handler.create_environment({
		"path": we.get_path(),
		"preset": "night",
	})
	assert_has_key(result, "data")
	assert_true(we.environment != null)
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_eq(we.environment, prev_env)
	assert_true(editor_redo(_undo_redo), "redo should succeed")
	assert_true(we.environment is Environment)
	_remove_node(we)


# ----- save to disk -----

func test_create_saves_to_disk() -> void:
	var out_path := "res://test_tmp_env.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var result := _handler.create_environment({
		"resource_path": out_path,
		"preset": "clear",
	})
	assert_has_key(result, "data")
	assert_false(result.data.undoable)
	assert_true(FileAccess.file_exists(out_path))
	var loaded := ResourceLoader.load(out_path)
	assert_true(loaded is Environment)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
