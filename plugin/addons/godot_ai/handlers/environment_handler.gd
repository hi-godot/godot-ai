@tool
class_name EnvironmentHandler
extends RefCounted

## Creates an Environment (+ optional Sky + ProceduralSkyMaterial) chain and
## either assigns it to a WorldEnvironment node or saves it to a .tres file.
## Bundles sub-resource creation + assignment in a single undo action.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


const _PRESETS := {
	"default": {"sky": true, "fog": false},
	"clear": {"sky": true, "fog": false},
	"sunset": {"sky": true, "fog": false},
	"night": {"sky": true, "fog": false},
	"fog": {"sky": true, "fog": true},
}


func create_environment(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var resource_path: String = params.get("resource_path", "")
	var overwrite: bool = params.get("overwrite", false)
	var preset: String = params.get("preset", "default")
	var properties: Dictionary = params.get("properties", {})
	var sky_param = params.get("sky", null)  # nullable — falls back to preset default

	# environment_create targets the whole WorldEnvironment node (no separate
	# `property` param) — pass require_property=false.
	var home_err := ResourceIO.validate_home(params, false)
	if home_err != null:
		return home_err

	if not _PRESETS.has(preset):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid preset '%s'. Valid: %s" % [preset, ", ".join(_PRESETS.keys())]
		)

	var preset_config: Dictionary = _PRESETS[preset]
	var want_sky: bool = sky_param if sky_param != null else preset_config.sky

	var env := Environment.new()
	var sky: Sky = null
	var sky_material: ProceduralSkyMaterial = null
	if want_sky:
		sky_material = ProceduralSkyMaterial.new()
		sky = Sky.new()
		sky.sky_material = sky_material
		env.background_mode = Environment.BG_SKY
		env.sky = sky
	else:
		env.background_mode = Environment.BG_CLEAR_COLOR

	_apply_preset(env, sky_material, preset)
	if preset_config.fog:
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.03

	if not properties.is_empty():
		var apply_err := ResourceHandler._apply_resource_properties(env, properties)
		if apply_err != null:
			return apply_err

	if not resource_path.is_empty():
		return _save_environment(env, sky, sky_material, resource_path, overwrite, preset)
	return _assign_environment(env, sky, sky_material, node_path, preset)


static func _apply_preset(env: Environment, sky_material: ProceduralSkyMaterial, preset: String) -> void:
	match preset:
		"default", "clear":
			if sky_material != null:
				sky_material.sky_top_color = Color(0.38, 0.45, 0.55)
				sky_material.sky_horizon_color = Color(0.65, 0.67, 0.7)
				sky_material.ground_horizon_color = Color(0.65, 0.67, 0.7)
				sky_material.ground_bottom_color = Color(0.2, 0.17, 0.13)
				sky_material.sun_angle_max = 30.0
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy = 1.0
		"sunset":
			if sky_material != null:
				sky_material.sky_top_color = Color(0.25, 0.3, 0.55)
				sky_material.sky_horizon_color = Color(1.0, 0.55, 0.3)
				sky_material.ground_horizon_color = Color(0.85, 0.4, 0.25)
				sky_material.ground_bottom_color = Color(0.2, 0.12, 0.1)
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_color = Color(1.0, 0.75, 0.55)
			env.ambient_light_energy = 0.8
		"night":
			if sky_material != null:
				sky_material.sky_top_color = Color(0.02, 0.02, 0.07)
				sky_material.sky_horizon_color = Color(0.05, 0.07, 0.15)
				sky_material.ground_horizon_color = Color(0.04, 0.05, 0.1)
				sky_material.ground_bottom_color = Color(0.0, 0.0, 0.02)
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.2, 0.22, 0.35)
			env.ambient_light_energy = 0.4
		"fog":
			if sky_material != null:
				sky_material.sky_top_color = Color(0.65, 0.65, 0.7)
				sky_material.sky_horizon_color = Color(0.8, 0.8, 0.82)
				sky_material.ground_horizon_color = Color(0.7, 0.7, 0.72)
				sky_material.ground_bottom_color = Color(0.3, 0.3, 0.32)
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy = 0.7


func _assign_environment(env: Environment, sky: Sky, sky_material: ProceduralSkyMaterial, node_path: String, preset: String) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	if not (node is WorldEnvironment):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Node at %s is %s — must be WorldEnvironment" % [node_path, node.get_class()]
		)

	var old_env = (node as WorldEnvironment).environment

	_undo_redo.create_action("MCP: Create Environment (%s) for %s" % [preset, node.name])
	_undo_redo.add_do_property(node, "environment", env)
	_undo_redo.add_undo_property(node, "environment", old_env)
	_undo_redo.add_do_reference(env)
	if sky != null:
		_undo_redo.add_do_reference(sky)
	if sky_material != null:
		_undo_redo.add_do_reference(sky_material)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"preset": preset,
			"sky_created": sky != null,
			"sky_material_class": sky_material.get_class() if sky_material != null else "",
			"undoable": true,
		}
	}


func _save_environment(env: Environment, _sky: Sky, _sky_material: ProceduralSkyMaterial, resource_path: String, overwrite: bool, preset: String) -> Dictionary:
	return ResourceIO.save_to_disk(env, resource_path, overwrite, "Environment", {
		"preset": preset,
	})
