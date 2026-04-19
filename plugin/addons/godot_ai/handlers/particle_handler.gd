@tool
class_name ParticleHandler
extends RefCounted

## Handles particle emitter authoring (GPU + CPU, 2D + 3D).
##
## All write operations bundle node creation and sub-resource spawns
## (ParticleProcessMaterial, default QuadMesh) in a single create_action
## so Ctrl-Z rolls back the whole effect atomically.


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
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid particle type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_particle(type_str)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate particle node")
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
		draw_material = ParticleValues.build_draw_material({})
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
			"path": ScenePath.from_node(node, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "properties dict is empty")

	var coerced: Dictionary = {}
	var old_values: Dictionary = {}
	for property in properties:
		var prop_name: String = String(property)
		if not (prop_name in _MAIN_KEYS):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Unknown main property '%s'. Valid: %s" % [prop_name, ", ".join(_MAIN_KEYS)]
			)
		var prop_type := _node_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not present on %s" % [prop_name, node.get_class()]
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "properties dict is empty")

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
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not present on ParticleProcessMaterial" % prop_name
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
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
	# CPU particles expose the same vocabulary directly on the node.
	# Map a few GPU-only names to the CPU equivalents where they differ.
	var aliases := {
		"emission_sphere_radius": "emission_sphere_radius",
	}
	var coerced: Dictionary = {}
	var old_values: Dictionary = {}

	for property in properties:
		var prop_name: String = aliases.get(String(property), String(property))
		var prop_type := _node_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not present on %s" % [prop_name, node.get_class()]
			)
		var coerce_result := ParticleValues.coerce(prop_name, properties[property], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
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
	return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node %s is not a particle node" % node.get_class())


func _set_draw_pass_gpu_3d(node: GPUParticles3D, node_path: String, pass_idx: int, mesh_path: String, material_path: String) -> Dictionary:
	if pass_idx < 1 or pass_idx > 4:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "pass must be 1..4 (got %d)" % pass_idx)

	var mesh: Mesh = null
	var mesh_created := false
	var property_name := "draw_pass_%d" % pass_idx
	# draw_pass_N is only a live property when draw_passes >= N. Probe via
	# get_property_list so we don't read a ghost value.
	var existing_mesh: Mesh = null
	if int(node.draw_passes) >= pass_idx:
		existing_mesh = node.get(property_name) as Mesh
	if not mesh_path.is_empty():
		if not ResourceLoader.exists(mesh_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Mesh not found: %s" % mesh_path)
		var loaded := ResourceLoader.load(mesh_path)
		if not (loaded is Mesh):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Mesh" % mesh_path)
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
		if not ResourceLoader.exists(material_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Material not found: %s" % material_path)
		var loaded_mat := ResourceLoader.load(material_path)
		if not (loaded_mat is Material):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Material" % material_path)
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "CPUParticles3D requires mesh or material param")

	var mesh: Mesh = node.mesh
	var old_mesh: Mesh = mesh
	if not mesh_path.is_empty():
		if not ResourceLoader.exists(mesh_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Mesh not found: %s" % mesh_path)
		var loaded := ResourceLoader.load(mesh_path)
		if not (loaded is Mesh):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Mesh" % mesh_path)
		mesh = loaded

	var material: Material = null
	var old_material: Material = node.material_override
	if not material_path.is_empty():
		if not ResourceLoader.exists(material_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Material not found: %s" % material_path)
		var loaded_mat := ResourceLoader.load(material_path)
		if not (loaded_mat is Material):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Material" % material_path)
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "2D particles require texture param")
	if not ResourceLoader.exists(texture_path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Texture not found: %s" % texture_path)
	var tex := ResourceLoader.load(texture_path)
	if not (tex is Texture2D):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Texture2D" % texture_path)

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
		for i in range(1, 5):
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: preset")

	var overrides: Dictionary = params.get("overrides", {})
	var blueprint = ParticlePresets.build(preset_name, overrides)
	if blueprint == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(ParticlePresets.list())]
		)

	var parent_path: String = params.get("parent_path", "")
	var node_name: String = params.get("name", "")
	var type_str: String = params.get("type", "gpu_3d")
	if node_name.is_empty():
		node_name = preset_name.capitalize()
	if not _VALID_TYPES.has(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid particle type '%s'. Valid: %s" % [type_str, ", ".join(_VALID_TYPES.keys())]
		)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = ScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, ScenePath.format_parent_error(parent_path, scene_root))

	var node := _instantiate_particle(type_str)
	node.name = node_name

	var is_gpu := type_str == "gpu_3d" or type_str == "gpu_2d"
	var is_3d := type_str == "gpu_3d" or type_str == "cpu_3d"

	var process_mat: ParticleProcessMaterial = null
	var process_material_created := false
	if is_gpu:
		process_mat = ParticleProcessMaterial.new()
		process_material_created = true

	var draw_mesh: Mesh = null
	var draw_material: StandardMaterial3D = null
	var draw_pass_mesh_created := false
	var draw_material_created := false
	if type_str == "gpu_3d":
		draw_mesh = QuadMesh.new()
		(draw_mesh as QuadMesh).size = Vector2(0.25, 0.25)
		var draw_config: Dictionary = blueprint.get("draw", {})
		draw_material = ParticleValues.build_draw_material(draw_config)
		(draw_mesh as QuadMesh).material = draw_material
		draw_pass_mesh_created = true
		draw_material_created = true

	# Pre-apply preset values to in-memory targets (no undo needed; nodes not in tree yet).
	var main_values: Dictionary = blueprint.get("main", {})
	var process_values: Dictionary = blueprint.get("process", {})
	var applied_main: Array[String] = []
	var applied_process: Array[String] = []

	for prop in main_values:
		var prop_name := String(prop)
		var prop_type := _object_property_type(node, prop_name)
		if prop_type == TYPE_NIL:
			continue  # Silently skip: not all main keys apply to all types.
		var coerce_result := ParticleValues.coerce(prop_name, main_values[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
		node.set(prop_name, coerce_result.value)
		applied_main.append(prop_name)

	# Apply process: GPU targets the ParticleProcessMaterial; CPU targets the node.
	var process_target: Object = process_mat if is_gpu else node
	for prop in process_values:
		var prop_name := String(prop)
		var prop_type := _object_property_type(process_target, prop_name)
		if prop_type == TYPE_NIL:
			continue  # Silently skip: preset property doesn't apply to this variant.
		var coerce_result := ParticleValues.coerce(prop_name, process_values[prop_name], prop_type)
		if not coerce_result.ok:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerce_result.error))
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
			"path": ScenePath.from_node(node, scene_root),
			"parent_path": ScenePath.from_node(parent, scene_root),
			"name": node_name,
			"preset": preset_name,
			"type": type_str,
			"class": _VALID_TYPES[type_str],
			"applied_main": applied_main,
			"applied_process": applied_process,
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
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: node_path")
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	var is_particle := node is GPUParticles3D or node is GPUParticles2D \
		or node is CPUParticles3D or node is CPUParticles2D
	if not is_particle:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
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
