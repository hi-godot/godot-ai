@tool
class_name MaterialHandler
extends RefCounted

## Handles Material authoring: creating .tres files, setting BaseMaterial3D
## properties / shader uniforms, assigning to nodes, high-level presets.
##
## File-resource lifecycle mirrors ThemeHandler (create/load/mutate/save).
## Undo pattern mirrors AnimationHandler (single create_action bundles
## every dependency spawn).


const _TYPE_TO_CLASS := {
	"standard": "StandardMaterial3D",
	"orm": "ORMMaterial3D",
	"canvas_item": "CanvasItemMaterial",
	"shader": "ShaderMaterial",
}

const _SUPPORTED_SUFFIXES := [".tres", ".material", ".res"]


var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# material_create
# ============================================================================

func create_material(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var type_str: String = params.get("type", "standard")
	var shader_path: String = params.get("shader_path", "")
	var overwrite: bool = params.get("overwrite", false)

	var err := _validate_material_path(path, "path")
	if err != null:
		return err

	if not _TYPE_TO_CLASS.has(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid material type '%s'. Valid: %s" % [type_str, ", ".join(_TYPE_TO_CLASS.keys())]
		)

	var existed_before := FileAccess.file_exists(path)
	if existed_before and not overwrite:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Material already exists at %s (pass overwrite=true to replace)" % path
		)

	var mat := _instantiate_material(type_str)
	if mat == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate material")

	if type_str == "shader":
		if shader_path.is_empty():
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"ShaderMaterial requires shader_path (res:// path to a .gdshader)"
			)
		if not ResourceLoader.exists(shader_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Shader not found: %s" % shader_path)
		var shader_res := ResourceLoader.load(shader_path)
		if not (shader_res is Shader):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Shader" % shader_path)
		(mat as ShaderMaterial).shader = shader_res

	var dir_path := path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to create directory: %s (error %d)" % [dir_path, mkdir_err]
		)

	var save_err := ResourceSaver.save(mat, path)
	if save_err != OK:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to save material to %s (error %d)" % [path, save_err]
		)

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	return {
		"data": {
			"path": path,
			"type": type_str,
			"class": mat.get_class(),
			"shader_path": shader_path,
			"overwritten": existed_before,
			"undoable": false,
			"reason": "File creation is persistent; delete the file manually to revert",
		}
	}


# ============================================================================
# material_set_param
# ============================================================================

func set_param(params: Dictionary) -> Dictionary:
	var load_result := _load_material_from_path(params.get("path", ""))
	if load_result.has("error"):
		return load_result
	var mat: Material = load_result.material
	var mat_path: String = load_result.path

	var property: String = params.get("property", "")
	if property.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: property")

	if not ("value" in params):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: value")

	var raw_value = params.get("value")

	# Probe the property. We allow any property present in get_property_list,
	# plus `shader` on ShaderMaterial.
	var prop_type: int = TYPE_NIL
	var property_exists := false
	for prop in mat.get_property_list():
		if prop.name == property:
			property_exists = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not property_exists:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			McpPropertyErrors.build_message(mat, property)
		)

	var coerced := MaterialValues.coerce_material_value(property, raw_value, prop_type)
	if not coerced.ok:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerced.error))
	var new_value = coerced.value

	var old_value = mat.get(property)

	_undo_redo.create_action("MCP: Set material %s.%s" % [mat_path.get_file(), property])
	_undo_redo.add_do_method(self, "_apply_param", mat_path, property, new_value, false)
	_undo_redo.add_undo_method(self, "_apply_param", mat_path, property, old_value, false)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": mat_path,
			"property": property,
			"value": MaterialValues.serialize_value(new_value),
			"previous_value": MaterialValues.serialize_value(old_value),
			"undoable": true,
		}
	}


# ============================================================================
# material_set_shader_param
# ============================================================================

func set_shader_param(params: Dictionary) -> Dictionary:
	var load_result := _load_material_from_path(params.get("path", ""))
	if load_result.has("error"):
		return load_result
	var mat: Material = load_result.material
	var mat_path: String = load_result.path

	if not (mat is ShaderMaterial):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Material at %s is %s, not ShaderMaterial" % [mat_path, mat.get_class()]
		)
	var shader_mat := mat as ShaderMaterial
	if shader_mat.shader == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"ShaderMaterial at %s has no shader assigned" % mat_path
		)

	var param_name: String = params.get("param", "")
	if param_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: param")

	if not ("value" in params):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: value")

	# Verify the uniform exists in the shader.
	var uniform_type := _shader_uniform_type(shader_mat.shader, param_name)
	if uniform_type == TYPE_NIL:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Shader uniform '%s' not declared on shader at %s" % [param_name, shader_mat.shader.resource_path]
		)

	var raw_value = params.get("value")
	var coerced := MaterialValues.coerce_material_value(param_name, raw_value, uniform_type)
	if not coerced.ok:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerced.error))
	var new_value = coerced.value

	var old_value = shader_mat.get_shader_parameter(param_name)

	_undo_redo.create_action("MCP: Set shader param %s.%s" % [mat_path.get_file(), param_name])
	_undo_redo.add_do_method(self, "_apply_shader_param", mat_path, param_name, new_value)
	_undo_redo.add_undo_method(self, "_apply_shader_param", mat_path, param_name, old_value)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": mat_path,
			"param": param_name,
			"value": MaterialValues.serialize_value(new_value),
			"previous_value": MaterialValues.serialize_value(old_value),
			"undoable": true,
		}
	}


# ============================================================================
# material_get
# ============================================================================

func get_material(params: Dictionary) -> Dictionary:
	var load_result := _load_material_from_path(params.get("path", ""))
	if load_result.has("error"):
		return load_result
	var mat: Material = load_result.material
	var mat_path: String = load_result.path

	var properties: Array[Dictionary] = []
	for prop in mat.get_property_list():
		var usage: int = prop.get("usage", 0)
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var name: String = prop.name
		if name.begins_with("shader_parameter/"):
			continue  # handled below
		var value = mat.get(name)
		if value == null and prop.type != TYPE_NIL:
			continue
		properties.append({
			"name": name,
			"type": type_string(prop.type),
			"value": MaterialValues.serialize_value(value),
		})

	var shader_params: Array[Dictionary] = []
	if mat is ShaderMaterial:
		var shader_mat := mat as ShaderMaterial
		if shader_mat.shader != null:
			for u in shader_mat.shader.get_shader_uniform_list():
				var u_name: String = u.get("name", "")
				if u_name.is_empty():
					continue
				shader_params.append({
					"name": u_name,
					"type": type_string(u.get("type", TYPE_NIL)),
					"value": MaterialValues.serialize_value(shader_mat.get_shader_parameter(u_name)),
				})

	var reverse_type_map := _reverse_type_map()

	var shader_path_str := ""
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.shader != null:
			shader_path_str = sm.shader.resource_path

	return {
		"data": {
			"path": mat_path,
			"class": mat.get_class(),
			"type": reverse_type_map.get(mat.get_class(), ""),
			"properties": properties,
			"property_count": properties.size(),
			"shader_parameters": shader_params,
			"shader_path": shader_path_str,
		}
	}


# ============================================================================
# material_list
# ============================================================================

func list_materials(params: Dictionary) -> Dictionary:
	var root: String = params.get("root", "res://")
	var type_filter: String = params.get("type", "")

	if not root.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "root must start with res://")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "EditorFileSystem not available")

	var results: Array[Dictionary] = []
	var start_dir := efs.get_filesystem_path(root)
	if start_dir == null:
		start_dir = efs.get_filesystem()
	_scan_materials(start_dir, type_filter, root, results)

	return {"data": {"materials": results, "count": results.size()}}


func _scan_materials(dir: EditorFileSystemDirectory, type_filter: String, root: String, out: Array[Dictionary]) -> void:
	if dir == null:
		return
	for i in dir.get_file_count():
		var file_path := dir.get_file_path(i)
		if not file_path.begins_with(root):
			continue
		var file_type := dir.get_file_type(i)
		var is_material := file_type == "Material" or ClassDB.is_parent_class(file_type, "Material")
		if not is_material:
			# Some material variants serialize as specific classes.
			if not (file_type in _TYPE_TO_CLASS.values()):
				continue

		if not type_filter.is_empty():
			if file_type != type_filter and not ClassDB.is_parent_class(file_type, type_filter):
				continue

		out.append({"path": file_path, "class": file_type})

	for i in dir.get_subdir_count():
		_scan_materials(dir.get_subdir(i), type_filter, root, out)


# ============================================================================
# material_assign
# ============================================================================

func assign_material(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: node_path")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	var slot: String = params.get("slot", "override")
	var resource_path: String = params.get("resource_path", "")
	var create_if_missing: bool = params.get("create_if_missing", false)
	var type_str: String = params.get("type", "standard")

	var slot_result := _resolve_slot_property(node, slot)
	if slot_result.has("error"):
		return slot_result
	var property: String = slot_result.property

	# Load or create the material.
	var mat: Material = null
	var material_created := false
	if not resource_path.is_empty():
		if not ResourceLoader.exists(resource_path):
			if create_if_missing:
				# We'd need to create a new file here — refuse; callers should
				# use material_create first or omit resource_path to get an
				# inline material.
				return McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Resource not found: %s. Create it first with material_create or omit resource_path for an inline material." % resource_path
				)
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % resource_path)
		var loaded := ResourceLoader.load(resource_path)
		if not (loaded is Material):
			var loaded_class := "null"
			if loaded != null:
				loaded_class = loaded.get_class()
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Resource at %s is not a Material (got %s)" % [resource_path, loaded_class]
			)
		mat = loaded
	else:
		if not create_if_missing:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Missing resource_path (pass create_if_missing=true to create a new inline material)"
			)
		if not _TYPE_TO_CLASS.has(type_str):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Invalid material type '%s'" % type_str
			)
		mat = _instantiate_material(type_str)
		material_created = true

	var old_value = node.get(property)

	_undo_redo.create_action("MCP: Assign material to %s.%s" % [node.name, property])
	_undo_redo.add_do_property(node, property, mat)
	_undo_redo.add_undo_property(node, property, old_value)
	if material_created:
		_undo_redo.add_do_reference(mat)
	_undo_redo.commit_action()

	return {
		"data": {
			"node_path": node_path,
			"property": property,
			"slot": slot,
			"resource_path": resource_path,
			"material_class": mat.get_class(),
			"material_created": material_created,
			"undoable": true,
		}
	}


# ============================================================================
# material_apply_to_node
# ============================================================================

func apply_to_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: node_path")

	var type_str: String = params.get("type", "standard")
	if not _TYPE_TO_CLASS.has(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid material type '%s'. Valid: %s" % [type_str, ", ".join(_TYPE_TO_CLASS.keys())]
		)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	var slot: String = params.get("slot", "override")
	var slot_result := _resolve_slot_property(node, slot)
	if slot_result.has("error"):
		return slot_result
	var property: String = slot_result.property

	var mat := _instantiate_material(type_str)

	var props_to_set: Dictionary = params.get("params", {})
	var applied: Array[String] = []
	for prop_name in props_to_set:
		var apply_err := _apply_one_param_on_instance(mat, String(prop_name), props_to_set[prop_name])
		if apply_err != null:
			return apply_err
		applied.append(String(prop_name))

	var save_to: String = params.get("save_to", "")
	var saved := false
	if not save_to.is_empty():
		var save_err_validation := _validate_material_path(save_to, "save_to")
		if save_err_validation != null:
			return save_err_validation
		var dir_path := save_to.get_base_dir()
		var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
		if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)
		var save_err := ResourceSaver.save(mat, save_to)
		if save_err != OK:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to save material to %s (error %d)" % [save_to, save_err])
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.update_file(save_to)
		mat = ResourceLoader.load(save_to)  # Use the saved reference to keep scene ref small.
		saved = true

	var old_value = node.get(property)

	_undo_redo.create_action("MCP: Apply %s material to %s" % [type_str, node.name])
	_undo_redo.add_do_property(node, property, mat)
	_undo_redo.add_undo_property(node, property, old_value)
	_undo_redo.add_do_reference(mat)
	_undo_redo.commit_action()

	return {
		"data": {
			"node_path": node_path,
			"property": property,
			"slot": slot,
			"type": type_str,
			"class": mat.get_class(),
			"applied_params": applied,
			"material_created": true,
			"saved_to": save_to if saved else "",
			"undoable": true,
		}
	}


# ============================================================================
# material_apply_preset
# ============================================================================

func apply_preset(params: Dictionary) -> Dictionary:
	var preset_name: String = params.get("preset", "")
	if preset_name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: preset")

	var overrides: Dictionary = params.get("overrides", {})
	var blueprint = MaterialPresets.build(preset_name, overrides)
	if blueprint == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(MaterialPresets.list())]
		)

	var type_str: String = blueprint.get("type", "standard")
	var preset_params: Dictionary = blueprint.get("params", {})

	var path: String = params.get("path", "")
	var node_path: String = params.get("node_path", "")

	if path.is_empty() and node_path.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Pass at least one of: path (save to disk), node_path (assign to node)"
		)

	# If both path and node_path, save to disk, then assign the saved resource.
	# If only path, save to disk.
	# If only node_path, inline material via apply_to_node.

	if not node_path.is_empty() and path.is_empty():
		# Inline
		return apply_to_node({
			"node_path": node_path,
			"type": type_str,
			"params": preset_params,
			"slot": params.get("slot", "override"),
		})

	# Save-to-disk path.
	var existed_before := FileAccess.file_exists(path)
	if existed_before and not params.get("overwrite", false):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Material already exists at %s (pass overwrite=true to replace)" % path
		)

	var path_err := _validate_material_path(path, "path")
	if path_err != null:
		return path_err

	var mat := _instantiate_material(type_str)
	for prop_name in preset_params:
		var apply_err := _apply_one_param_on_instance(mat, String(prop_name), preset_params[prop_name])
		if apply_err != null:
			return apply_err

	var dir_path := path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var save_err := ResourceSaver.save(mat, path)
	if save_err != OK:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to save material: %s" % path)

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	var assigned := false
	if not node_path.is_empty():
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
		var node := ScenePath.resolve(node_path, scene_root)
		if node == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
		var slot_result := _resolve_slot_property(node, params.get("slot", "override"))
		if slot_result.has("error"):
			return slot_result
		var property: String = slot_result.property
		var saved_mat := ResourceLoader.load(path)
		var old_value = node.get(property)
		_undo_redo.create_action("MCP: Apply preset %s to %s" % [preset_name, node.name])
		_undo_redo.add_do_property(node, property, saved_mat)
		_undo_redo.add_undo_property(node, property, old_value)
		_undo_redo.commit_action()
		assigned = true

	return {
		"data": {
			"preset": preset_name,
			"type": type_str,
			"path": path,
			"node_path": node_path,
			"material_created": true,
			"assigned": assigned,
			"saved_to_disk": true,
			"undoable": assigned,  # assign is undoable; save is not
			"reason": "" if assigned else "File save is not undoable",
		}
	}


# ============================================================================
# Undo-callable: applies a param on the loaded resource and saves.
# ============================================================================

func _apply_param(mat_path: String, property: String, value: Variant, _is_shader: bool) -> void:
	var mat: Material = ResourceLoader.load(mat_path)
	if mat == null:
		return
	mat.set(property, value)
	ResourceSaver.save(mat, mat_path)


func _apply_shader_param(mat_path: String, param_name: String, value: Variant) -> void:
	var mat: Material = ResourceLoader.load(mat_path)
	if mat == null or not (mat is ShaderMaterial):
		return
	(mat as ShaderMaterial).set_shader_parameter(param_name, value)
	ResourceSaver.save(mat, mat_path)


# ============================================================================
# Helpers
# ============================================================================

static func _instantiate_material(type_str: String) -> Material:
	match type_str:
		"standard":
			return StandardMaterial3D.new()
		"orm":
			return ORMMaterial3D.new()
		"canvas_item":
			return CanvasItemMaterial.new()
		"shader":
			return ShaderMaterial.new()
	return null


static func _reverse_type_map() -> Dictionary:
	var out := {}
	for k in _TYPE_TO_CLASS:
		out[_TYPE_TO_CLASS[k]] = k
	return out


static func _validate_material_path(path: String, param_name: String) -> Variant:
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: %s" % param_name)
	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "%s must start with res:// (got %s)" % [param_name, path])
	var has_suffix := false
	for s in _SUPPORTED_SUFFIXES:
		if path.ends_with(s):
			has_suffix = true
			break
	if not has_suffix:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s must end with one of %s (got %s)" % [param_name, ", ".join(_SUPPORTED_SUFFIXES), path]
		)
	return null


func _load_material_from_path(path: String) -> Dictionary:
	var err := _validate_material_path(path, "path")
	if err != null:
		return err
	if not ResourceLoader.exists(path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Material not found: %s" % path)
	var res := ResourceLoader.load(path)
	if res == null or not (res is Material):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Material" % path)
	return {"material": res, "path": path}


## Map a slot name to a Godot property name on the given node.
## Returns {property: "..."} or an error dict.
func _resolve_slot_property(node: Node, slot: String) -> Dictionary:
	if slot == "override":
		if node is MeshInstance3D or node is CSGShape3D:
			return {"property": "material_override"}
		if node is CanvasItem:
			return {"property": "material"}
		if node is GPUParticles3D or node is GPUParticles2D or node is CPUParticles3D or node is CPUParticles2D:
			return {"property": "material_override"} if node is GeometryInstance3D else {"property": "material"}
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Slot 'override' not supported on %s" % node.get_class()
		)
	if slot == "canvas":
		if node is CanvasItem:
			return {"property": "material"}
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Slot 'canvas' requires a CanvasItem (got %s)" % node.get_class()
		)
	if slot == "process":
		if node is GPUParticles3D or node is GPUParticles2D:
			return {"property": "process_material"}
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Slot 'process' requires a GPUParticles2D/3D (got %s)" % node.get_class()
		)
	if slot.begins_with("surface_"):
		if not (node is MeshInstance3D):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Slot '%s' requires a MeshInstance3D (got %s)" % [slot, node.get_class()]
			)
		var idx_str := slot.substr(len("surface_"))
		if not idx_str.is_valid_int():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid surface slot: %s" % slot)
		var idx := int(idx_str)
		var mi := node as MeshInstance3D
		var surf_count := mi.mesh.get_surface_count() if mi.mesh != null else 0
		if idx < 0 or idx >= surf_count:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Surface index %d out of range (mesh has %d surfaces)" % [idx, surf_count]
			)
		return {"property": "surface_material_override/%d" % idx}
	return McpErrorCodes.make(
		McpErrorCodes.INVALID_PARAMS,
		"Unknown slot '%s'. Valid: override, canvas, process, surface_N" % slot
	)


## Apply one property to an in-memory material instance; returns null on
## success or an error dict on failure.
func _apply_one_param_on_instance(mat: Material, property: String, raw_value: Variant) -> Variant:
	var prop_type: int = TYPE_NIL
	var property_exists := false
	for prop in mat.get_property_list():
		if prop.name == property:
			property_exists = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not property_exists:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			McpPropertyErrors.build_message(mat, property)
		)
	var coerced := MaterialValues.coerce_material_value(property, raw_value, prop_type)
	if not coerced.ok:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, String(coerced.error))
	mat.set(property, coerced.value)
	return null


## Inspect a shader to get the Variant type of a uniform. Returns TYPE_NIL if
## the uniform is not declared.
static func _shader_uniform_type(shader: Shader, name: String) -> int:
	if shader == null:
		return TYPE_NIL
	for u in shader.get_shader_uniform_list():
		if u.get("name", "") == name:
			return int(u.get("type", TYPE_NIL))
	return TYPE_NIL
