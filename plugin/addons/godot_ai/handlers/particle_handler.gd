@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles particle emitter authoring (GPU + CPU, 2D + 3D).
##
## All write operations bundle node creation and sub-resource spawns
## (ParticleProcessMaterial, default QuadMesh) in a single create_action
## so Ctrl-Z rolls back the whole effect atomically.

const ParticleValues := preload("res://addons/godot_ai/handlers/particle_values.gd")
const ParticlePresets := preload("res://addons/godot_ai/handlers/particle_presets.gd")

const _VALID_TYPES := {
	"gpu_3d": "GPUParticles3D",
	"gpu_2d": "GPUParticles2D",
	"cpu_3d": "CPUParticles3D",
	"cpu_2d": "CPUParticles2D",
}

const _MAIN_KEYS := [
	"amount",
	"lifetime",
	"one_shot",
	"explosiveness",
	"preprocess",
	"speed_scale",
	"randomness",
	"fixed_fps",
	"emitting",
	"local_coords",
	"interp_to_end",
]


var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# particle_create
# ============================================================================

func create_particle(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "Particles")
	var type_str: String = params.get("type", "gpu_3d")

	if not _VALID_TYPES.has(type_str):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid particle type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_particle(type_str)
	if node == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate particle node")
	if not node_name.is_empty():
		node.name = node_name

	var process_mat: ParticleProcessMaterial = null
	var process_material_created := false
	var draw_mesh: Mesh = null
	var draw_material: StandardMaterial3D = null
	var draw_pass_mesh_created := false
	var draw_material_created := false

	if type_str == "gpu_3d" or type_str == "gpu_2d":
		process_mat = ParticleProcessMaterial.new()
		process_material_created = true
	if type_str == "gpu_3d":
		draw_mesh = QuadMesh.new()
		(draw_mesh as QuadMesh).size = Vector2(0.25, 0.25)
		# Without a material, the mesh renders flat white — ignoring
		# ParticleProcessMaterial.color_ramp entirely. Give it the standard
		# billboard + vertex-color-as-albedo setup so color_ramp works.
		draw_material = ParticleValues.build_draw_material({}).material
		(draw_mesh as QuadMesh).material = draw_material
		draw_pass_mesh_created = true
		draw_material_created = true

	_undo_redo.create_action("MCP: Create %s '%s'" % [_VALID_TYPES[type_str], node.name])
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	if process_mat != null:
		_undo_redo.add_do_property(node, "process_material", process_mat)
		_undo_redo.add_do_reference(process_mat)
	if draw_mesh != null:
		_undo_redo.add_do_property(node, "draw_pass_1", draw_mesh)
		_undo_redo.add_do_reference(draw_mesh)
	if draw_material != null:
		_undo_redo.add_do_reference(draw_material)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"name": String(node.name),
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"process_material_created": process_material_created,
			"draw_pass_mesh_created": draw_pass_mesh_created,
			"draw_material_created": draw_material_created,
			"undoable": true,
		}
	}


# ============================================================================
# particle_set_main
# ============================================================================

func set_main(params: Dictionary) -> Dictionary:
	var resolved := _resolve_particle(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "properties dict is empty")

	var coerced: Dictionary = {}
	var old_values: Dictionary = {}
	for property in properties:
		var prop_name: String = String(property)
		if not (prop_name in _MAIN_KEYS):
			return ErrorCodes.make(
				ErrorCodes.INVALID_PARAMS,
				"Unknown main property '%s'. Valid: %s" % [prop_name, ", ".join(_MAIN_KEYS)]
			)
		var prop_type := _node_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			return ErrorCodes.make(
				ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"Property '%s' not present on %s" % [prop_name, node.get_class()]
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[prop_name], prop_type)
		if not coerce_result.ok:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		coerced[prop_name] = coerce_result.value
		old_values[prop_name] = node.get(prop_name)

	_undo_redo.create_action("MCP: Set particle main on %s" % node.name)
	for prop_name in coerced:
		_undo_redo.add_do_property(node, prop_name, coerced[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	_undo_redo.commit_action()

	var applied: Array[String] = []
	var serialized_values: Dictionary = {}
	for prop_name in coerced:
		applied.append(prop_name)
		serialized_values[prop_name] = ParticleValues.serialize(coerced[prop_name])

	return {
		"data": {
			"path": node_path,
			"applied": applied,
			"values": serialized_values,
			"undoable": true,
		}
	}


# ============================================================================
# particle_set_process
# ============================================================================

func set_process(params: Dictionary) -> Dictionary:
	var resolved := _resolve_particle(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "properties dict is empty")

	# GPU: work through process_material; CPU: properties live on node directly.
	if node is GPUParticles3D or node is GPUParticles2D:
		return _set_process_gpu(node, node_path, properties)
	return _set_process_cpu(node, node_path, properties)


func _set_process_gpu(node: Node, node_path: String, properties: Dictionary) -> Dictionary:
	var existing_mat: ParticleProcessMaterial = node.process_material as ParticleProcessMaterial
	var process_material_created := false
	var mat: ParticleProcessMaterial = existing_mat
	if mat == null:
		mat = ParticleProcessMaterial.new()
		process_material_created = true

	var coerced: Dictionary = {}
	for property in properties:
		var prop_name: String = String(property)
		var prop_type := _object_property_type(mat, prop_name)
		if prop_type == TYPE_NIL:
			return ErrorCodes.make(
				ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"Property '%s' not present on ParticleProcessMaterial" % prop_name
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[prop_name], prop_type)
		if not coerce_result.ok:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		coerced[prop_name] = coerce_result.value

	_undo_redo.create_action("MCP: Set particle process on %s" % node.name)
	if process_material_created:
		_undo_redo.add_do_property(node, "process_material", mat)
		_undo_redo.add_undo_property(node, "process_material", null)
		_undo_redo.add_do_reference(mat)
		# Apply new values directly on the (newly created) material. No old values to restore.
		for prop_name in coerced:
			mat.set(prop_name, coerced[prop_name])
	else:
		# Use the reusable apply/restore pattern for existing material.
		var old_values: Dictionary = {}
		for prop_name in coerced:
			old_values[prop_name] = mat.get(prop_name)
		for prop_name in coerced:
			_undo_redo.add_do_property(mat, prop_name, coerced[prop_name])
			_undo_redo.add_undo_property(mat, prop_name, old_values[prop_name])
	_undo_redo.commit_action()

	var applied: Array[String] = []
	var serialized: Dictionary = {}
	for prop_name in coerced:
		applied.append(prop_name)
		serialized[prop_name] = ParticleValues.serialize(mat.get(prop_name))

	return {
		"data": {
			"path": node_path,
			"applied": applied,
			"values": serialized,
			"process_material_created": process_material_created,
			"undoable": true,
		}
	}


func _set_process_cpu(node: Node, node_path: String, properties: Dictionary) -> Dictionary:
	# CPU particles expose the same property vocabulary directly on the node,
	# so property names pass through unchanged.
	var coerced: Dictionary = {}
	var old_values: Dictionary = {}

	for property in properties:
		var prop_name: String = String(property)
		var prop_type := _node_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			return ErrorCodes.make(
				ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"Property '%s' not present on %s" % [prop_name, node.get_class()]
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[property], prop_type)
		if not coerce_result.ok:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		coerced[prop_name] = coerce_result.value
		old_values[prop_name] = node.get(prop_name)

	_undo_redo.create_action("MCP: Set particle process on %s" % node.name)
	for prop_name in coerced:
		_undo_redo.add_do_property(node, prop_name, coerced[prop_name])
		_undo_redo.add_undo_property(node, prop_name, old_values[prop_name])
	_undo_redo.commit_action()

	var applied: Array[String] = []
	var serialized: Dictionary = {}
	for prop_name in coerced:
		applied.append(prop_name)
		serialized[prop_name] = ParticleValues.serialize(coerced[prop_name])

	return {
		"data": {
			"path": node_path,
			"applied": applied,
			"values": serialized,
			"process_material_created": false,
			"undoable": true,
		}
	}


# ============================================================================
# particle_set_draw_pass
# ============================================================================

func set_draw_pass(params: Dictionary) -> Dictionary:
	var resolved := _resolve_particle(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var pass_idx: int = int(params.get("pass", 1))
	var mesh_path: String = params.get("mesh", "")
	var texture_path: String = params.get("texture", "")
	var material_path: String = params.get("material", "")

	if node is GPUParticles3D:
		return _set_draw_pass_gpu_3d(node, node_path, pass_idx, mesh_path, material_path)
	if node is CPUParticles3D:
		return _set_draw_pass_cpu_3d(node, node_path, mesh_path, material_path)
	if node is GPUParticles2D or node is CPUParticles2D:
		return _set_draw_pass_2d(node, node_path, texture_path)
	return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Node %s is not a particle node" % node.get_class())


func _set_draw_pass_gpu_3d(node: GPUParticles3D, node_path: String, pass_idx: int, mesh_path: String, material_path: String) -> Dictionary:
	if pass_idx < 1 or pass_idx > 4:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "pass must be 1..4 (got %d)" % pass_idx)

	var mesh: Mesh = null
	var mesh_created := false
	var property_name := "draw_pass_%d" % pass_idx
	# draw_pass_N is only a live property when draw_passes >= N. Probe via
	# get_property_list so we don't read a ghost value.
	var existing_mesh: Mesh = null
	if int(node.draw_passes) >= pass_idx:
		existing_mesh = node.get(property_name) as Mesh
	if not mesh_path.is_empty():
		var mesh_path_err = McpPathValidator.loadable_error(mesh_path, "mesh_path")
		if mesh_path_err != null:
			return mesh_path_err
		if not ResourceLoader.exists(mesh_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Mesh not found: %s" % mesh_path)
		var loaded := ResourceLoader.load(mesh_path)
		if not (loaded is Mesh):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Mesh" % mesh_path)
		mesh = loaded
	else:
		if existing_mesh == null:
			mesh = QuadMesh.new()
			(mesh as QuadMesh).size = Vector2(0.25, 0.25)
			mesh_created = true
		else:
			mesh = existing_mesh

	var material: Material = null
	if not material_path.is_empty():
		var material_path_err = McpPathValidator.loadable_error(material_path, "material_path")
		if material_path_err != null:
			return material_path_err
		if not ResourceLoader.exists(material_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Material not found: %s" % material_path)
		var loaded_mat := ResourceLoader.load(material_path)
		if not (loaded_mat is Material):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Material" % material_path)
		material = loaded_mat

	var old_draw_passes: int = int(node.draw_passes)
	var new_draw_passes: int = max(old_draw_passes, pass_idx)
	var old_value = existing_mesh  # Null if draw_passes < pass_idx
	var old_material: Material = null
	if material != null:
		old_material = node.material_override

	_undo_redo.create_action("MCP: Set %s.draw_pass_%d" % [node.name, pass_idx])
	# Grow draw_passes first so draw_pass_N property exists before we set it.
	if new_draw_passes != old_draw_passes:
		_undo_redo.add_do_property(node, "draw_passes", new_draw_passes)
		_undo_redo.add_undo_property(node, "draw_passes", old_draw_passes)
	if not mesh_path.is_empty() or mesh_created:
		_undo_redo.add_do_property(node, property_name, mesh)
		_undo_redo.add_undo_property(node, property_name, old_value)
	if mesh_created:
		_undo_redo.add_do_reference(mesh)
	if material != null:
		_undo_redo.add_do_property(node, "material_override", material)
		_undo_redo.add_undo_property(node, "material_override", old_material)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"pass": pass_idx,
			"mesh_path": mesh_path,
			"mesh_class": mesh.get_class() if mesh else "",
			"material_path": material_path,
			"draw_pass_mesh_created": mesh_created,
			"draw_passes_grown": new_draw_passes != old_draw_passes,
			"undoable": true,
		}
	}


func _set_draw_pass_cpu_3d(node: CPUParticles3D, node_path: String, mesh_path: String, material_path: String) -> Dictionary:
	if mesh_path.is_empty() and material_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "CPUParticles3D requires mesh or material param")

	var mesh: Mesh = node.mesh
	var old_mesh: Mesh = mesh
	if not mesh_path.is_empty():
		var mesh_path_err = McpPathValidator.loadable_error(mesh_path, "mesh_path")
		if mesh_path_err != null:
			return mesh_path_err
		if not ResourceLoader.exists(mesh_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Mesh not found: %s" % mesh_path)
		var loaded := ResourceLoader.load(mesh_path)
		if not (loaded is Mesh):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Mesh" % mesh_path)
		mesh = loaded

	var material: Material = null
	var old_material: Material = node.material_override
	if not material_path.is_empty():
		var material_path_err = McpPathValidator.loadable_error(material_path, "material_path")
		if material_path_err != null:
			return material_path_err
		if not ResourceLoader.exists(material_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Material not found: %s" % material_path)
		var loaded_mat := ResourceLoader.load(material_path)
		if not (loaded_mat is Material):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Material" % material_path)
		material = loaded_mat

	_undo_redo.create_action("MCP: Set CPU particle draw on %s" % node.name)
	if not mesh_path.is_empty():
		_undo_redo.add_do_property(node, "mesh", mesh)
		_undo_redo.add_undo_property(node, "mesh", old_mesh)
	if material != null:
		_undo_redo.add_do_property(node, "material_override", material)
		_undo_redo.add_undo_property(node, "material_override", old_material)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"mesh_path": mesh_path,
			"material_path": material_path,
			"draw_pass_mesh_created": false,
			"undoable": true,
		}
	}


func _set_draw_pass_2d(node: Node, node_path: String, texture_path: String) -> Dictionary:
	if texture_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "2D particles require texture param")
	var texture_path_err = McpPathValidator.loadable_error(texture_path, "texture_path")
	if texture_path_err != null:
		return texture_path_err
	if not ResourceLoader.exists(texture_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Texture not found: %s" % texture_path)
	var tex := ResourceLoader.load(texture_path)
	if not (tex is Texture2D):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Texture2D" % texture_path)

	var old_texture: Texture2D = node.get("texture")

	_undo_redo.create_action("MCP: Set 2D particle texture on %s" % node.name)
	_undo_redo.add_do_property(node, "texture", tex)
	_undo_redo.add_undo_property(node, "texture", old_texture)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"texture_path": texture_path,
			"undoable": true,
		}
	}


# ============================================================================
# particle_restart
# ============================================================================

func restart_particle(params: Dictionary) -> Dictionary:
	var resolved := _resolve_particle(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	if node.has_method("restart"):
		node.restart()
	return {
		"data": {
			"path": node_path,
			"undoable": false,
			"reason": "Restart is a runtime operation, not tracked in undo history",
		}
	}


# ============================================================================
# particle_get
# ============================================================================

func get_particle(params: Dictionary) -> Dictionary:
	var resolved := _resolve_particle(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path

	var type_str := ""
	for key in _VALID_TYPES:
		if node.get_class() == _VALID_TYPES[key]:
			type_str = key
			break

	var main_values: Dictionary = {}
	var node_prop_names := _property_names(node)
	for key in _MAIN_KEYS:
		if node_prop_names.has(key):
			main_values[key] = ParticleValues.serialize(node.get(key))

	var process_data: Dictionary = {}
	if node is GPUParticles3D or node is GPUParticles2D:
		var mat: ParticleProcessMaterial = node.process_material as ParticleProcessMaterial
		if mat != null:
			var process_props: Dictionary = {}
			for prop in mat.get_property_list():
				var usage: int = prop.get("usage", 0)
				if not (usage & PROPERTY_USAGE_EDITOR):
					continue
				var v = mat.get(prop.name)
				if v == null:
					continue
				process_props[prop.name] = ParticleValues.serialize(v)
			process_data = {
				"class": "ParticleProcessMaterial",
				"properties": process_props,
			}

	var draw_passes: Array[Dictionary] = []
	if node is GPUParticles3D:
		var active_draw_pass_count: int = min(int(node.draw_passes), 4)
		for i in range(1, active_draw_pass_count + 1):
			var prop_name := "draw_pass_%d" % i
			var m: Mesh = node.get(prop_name) as Mesh
			draw_passes.append({
				"pass": i,
				"mesh_class": m.get_class() if m != null else "",
			})

	var texture_path := ""
	if node is GPUParticles2D or node is CPUParticles2D:
		var t: Texture2D = node.get("texture")
		if t != null:
			texture_path = t.resource_path

	return {
		"data": {
			"path": node_path,
			"type": type_str,
			"class": node.get_class(),
			"main": main_values,
			"process": process_data,
			"draw_passes": draw_passes,
			"texture_path": texture_path,
		}
	}


# ============================================================================
# particle_apply_preset
# ============================================================================

func apply_preset(params: Dictionary) -> Dictionary:
	var preset_name: String = params.get("preset", "")
	if preset_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: preset")

	var overrides: Dictionary = params.get("overrides", {})
	var blueprint = ParticlePresets.build(preset_name, overrides)
	if blueprint == null:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(ParticlePresets.list())]
		)

	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "")
	var type_str: String = params.get("type", "gpu_3d")
	if node_name.is_empty():
		node_name = preset_name.capitalize()
	if not _VALID_TYPES.has(type_str):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid particle type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var _scene_check := McpNodeValidator.require_scene_or_error()
	if _scene_check.has("error"):
		return _scene_check
	var scene_root: Node = _scene_check.scene_root

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_particle(type_str)
	node.name = node_name

	var is_gpu := type_str == "gpu_3d" or type_str == "gpu_2d"
	var is_3d := type_str == "gpu_3d" or type_str == "cpu_3d"

	var process_mat: ParticleProcessMaterial = null
	var process_material_created := false
	if is_gpu:
		process_mat = ParticleProcessMaterial.new()
		process_material_created = true

	# User-supplied override keys per group. Preset-blueprint keys may skip
	# silently on types they don't apply to (presets are cross-type by
	# design); user-requested overrides must apply or error (#770).
	var user_keys: Dictionary = blueprint.get("user_keys", {})
	var user_main: Dictionary = user_keys.get("main", {})
	var user_process: Dictionary = user_keys.get("process", {})
	var user_draw: Dictionary = user_keys.get("draw", {})

	var draw_mesh: Mesh = null
	var draw_material: StandardMaterial3D = null
	var draw_pass_mesh_created := false
	var draw_material_created := false
	var applied_draw: Array[String] = []
	var draw_config: Dictionary = blueprint.get("draw", {})
	if type_str == "gpu_3d":
		var draw_result := ParticleValues.build_draw_material(draw_config)
		if not draw_result.ok:
			node.free()
			var msg := String(draw_result.error)
			if draw_result.get("unknown_key", false):
				msg = _draw_key_unsupported_message(String(draw_result.key), type_str)
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, msg)
		draw_mesh = QuadMesh.new()
		(draw_mesh as QuadMesh).size = Vector2(0.25, 0.25)
		draw_material = draw_result.material
		(draw_mesh as QuadMesh).material = draw_material
		draw_pass_mesh_created = true
		draw_material_created = true
		for applied_key in draw_result.applied:
			applied_draw.append(String(applied_key))
	elif type_str == "gpu_2d":
		# GPUParticles2D has no draw-pass material; the one draw override it
		# supports is draw.texture → the node's texture property.
		for key in user_draw:
			if String(key) != "texture":
				node.free()
				return ErrorCodes.make(
					ErrorCodes.INVALID_PARAMS,
					_draw_key_unsupported_message(String(key), type_str)
				)
		if user_draw.has("texture"):
			var tex_result := _load_draw_texture(draw_config.get("texture"))
			if tex_result.has("error"):
				node.free()
				return tex_result
			node.set("texture", tex_result.texture)
			applied_draw.append("texture")
	else:
		# cpu_3d / cpu_2d: no draw support — reject user draw overrides
		# instead of dropping them.
		for key in user_draw:
			node.free()
			return ErrorCodes.make(
				ErrorCodes.INVALID_PARAMS,
				_draw_key_unsupported_message(String(key), type_str)
			)

	# Pre-apply preset values to in-memory targets (no undo needed; nodes not in tree yet).
	var main_values: Dictionary = blueprint.get("main", {})
	var process_values: Dictionary = blueprint.get("process", {})
	var applied_main: Array[String] = []
	var applied_process: Array[String] = []

	for prop in main_values:
		var prop_name := String(prop)
		var prop_type := _object_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			if user_main.has(prop_name):
				var node_class := node.get_class()
				node.free()
				return ErrorCodes.make(
					ErrorCodes.INVALID_PARAMS,
					"Override main.%s does not apply to type '%s' (no such property on %s)" % [
						prop_name, type_str, node_class
					]
				)
			continue  # Blueprint key: not all main keys apply to all types.
		var coerce_result := ParticleValues.coerce(prop_name, main_values[prop_name], prop_type)
		if not coerce_result.ok:
			node.free()
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		node.set(prop_name, coerce_result.value)
		applied_main.append(prop_name)

	# Apply process: GPU targets the ParticleProcessMaterial; CPU targets the node.
	var process_target: Object = process_mat if is_gpu else node
	for prop in process_values:
		var prop_name := String(prop)
		var prop_type := _object_property_type(process_target, prop_name)
		if prop_type == TYPE_NIL:
			if user_process.has(prop_name):
				var target_class := process_target.get_class()
				node.free()
				return ErrorCodes.make(
					ErrorCodes.INVALID_PARAMS,
					"Override process.%s does not apply to type '%s' (no such property on %s)" % [
						prop_name, type_str, target_class
					]
				)
			continue  # Blueprint key: preset property doesn't apply to this variant.
		var coerce_result := ParticleValues.coerce(prop_name, process_values[prop_name], prop_type)
		if not coerce_result.ok:
			node.free()
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		process_target.set(prop_name, coerce_result.value)
		applied_process.append(prop_name)

	_undo_redo.create_action("MCP: Apply preset %s" % preset_name)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	if process_mat != null:
		_undo_redo.add_do_property(node, "process_material", process_mat)
		_undo_redo.add_do_reference(process_mat)
	if draw_mesh != null:
		_undo_redo.add_do_property(node, "draw_pass_1", draw_mesh)
		_undo_redo.add_do_reference(draw_mesh)
	if draw_material != null:
		_undo_redo.add_do_reference(draw_material)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"name": node_name,
			"preset": preset_name,
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"applied_main": applied_main,
			"applied_process": applied_process,
			"applied_draw": applied_draw,
			"process_material_created": process_material_created,
			"draw_pass_mesh_created": draw_pass_mesh_created,
			"draw_material_created": draw_material_created,
			"is_3d": is_3d,
			"undoable": true,
		}
	}


# ============================================================================
# Helpers
# ============================================================================

## Actionable rejection for a user draw override that can't apply to the
## selected particle type: name the key and where it IS supported.
static func _draw_key_unsupported_message(key: String, type_str: String) -> String:
	if key == "texture":
		return "draw.texture is only supported for gpu_2d (got type '%s')" % type_str
	var probe := StandardMaterial3D.new()
	if _object_property_type(probe, key) != TYPE_NIL:
		return "draw.%s is only supported for gpu_3d (got type '%s')" % [key, type_str]
	return (
		"Unknown draw key '%s' (draw overrides configure the gpu_3d "
		+ "draw-pass StandardMaterial3D; gpu_2d supports only draw.texture)"
	) % key


## Load a Texture2D for the gpu_2d draw.texture override. Returns
## {texture: Texture2D} or an error dict (same validation as set_draw_pass).
static func _load_draw_texture(value: Variant) -> Dictionary:
	if not (value is String) or String(value).is_empty():
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"draw.texture must be a non-empty res:// path string (got %s)" % type_string(typeof(value))
		)
	var texture_path := String(value)
	var texture_path_err = McpPathValidator.loadable_error(texture_path, "draw.texture")
	if texture_path_err != null:
		return texture_path_err
	if not ResourceLoader.exists(texture_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Texture not found: %s" % texture_path)
	var tex := ResourceLoader.load(texture_path)
	if not (tex is Texture2D):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Texture2D" % texture_path)
	return {"texture": tex}


static func _instantiate_particle(type_str: String) -> Node:
	match type_str:
		"gpu_3d":
			return GPUParticles3D.new()
		"gpu_2d":
			return GPUParticles2D.new()
		"cpu_3d":
			return CPUParticles3D.new()
		"cpu_2d":
			return CPUParticles2D.new()
	return null


func _resolve_particle(params: Dictionary) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("node_path", ""), "node_path",
	)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var node_path: String = resolved.path
	var is_particle := node is GPUParticles3D or node is GPUParticles2D \
		or node is CPUParticles3D or node is CPUParticles2D
	if not is_particle:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Node %s is not a particle node (got %s)" % [node_path, node.get_class()]
		)
	return {"node": node, "path": node_path}


static func _node_property_type(node: Object, name: String) -> int:
	return _object_property_type(node, name)


static func _object_property_type(obj: Object, name: String) -> int:
	if obj == null:
		return TYPE_NIL
	for prop in obj.get_property_list():
		if prop.name == name:
			return int(prop.get("type", TYPE_NIL))
	return TYPE_NIL


static func _property_names(obj: Object) -> Dictionary:
	var out: Dictionary = {}
	if obj == null:
		return out
	for prop in obj.get_property_list():
		out[prop.name] = true
	return out
