@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## Create a fully validated VisualShader resource; scene assignment is separate.
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_NODES := 256
const MAX_CONNECTIONS := 1024
const MODES := {
	"spatial": Shader.MODE_SPATIAL, "canvas_item": Shader.MODE_CANVAS_ITEM,
	"particles": Shader.MODE_PARTICLES, "sky": Shader.MODE_SKY, "fog": Shader.MODE_FOG,
}
const STAGES := {
	"vertex": VisualShader.TYPE_VERTEX, "fragment": VisualShader.TYPE_FRAGMENT,
	"light": VisualShader.TYPE_LIGHT, "start": VisualShader.TYPE_START,
	"process": VisualShader.TYPE_PROCESS, "collide": VisualShader.TYPE_COLLIDE,
	"start_custom": VisualShader.TYPE_START_CUSTOM, "process_custom": VisualShader.TYPE_PROCESS_CUSTOM,
	"sky": VisualShader.TYPE_SKY, "fog": VisualShader.TYPE_FOG,
}
const MODE_STAGES := {
	"spatial": ["vertex", "fragment", "light"],
	"canvas_item": ["vertex", "fragment", "light"],
	"particles": ["start", "process", "collide", "start_custom", "process_custom"],
	"sky": ["sky"], "fog": ["fog"],
}
## Preserve useful aliases from the original #869 implementation.
const ALIASES := {
	"VisualShaderNodeScalarOp": "VisualShaderNodeFloatOp",
	"VisualShaderNodeScalarFunc": "VisualShaderNodeFloatFunc",
	"VisualShaderNodeVectorConstant": "VisualShaderNodeVec3Constant",
	"VisualShaderNodeVectorParameter": "VisualShaderNodeVec3Parameter",
	"VisualShaderNodeTime": "VisualShaderNodeInput",
	"VisualShaderNodeSin": "VisualShaderNodeFloatFunc",
	"VisualShaderNodeCos": "VisualShaderNodeFloatFunc",
	"VisualShaderNodeLength": "VisualShaderNodeVectorLen",
}
const IMPLICIT := {
	"VisualShaderNodeTime": {"input_name": "time"},
	"VisualShaderNodeSin": {"function": "sin"},
	"VisualShaderNodeCos": {"function": "cos"},
}
## Only node-authoring properties, never script/resource ownership or arbitrary code.
const PROPERTIES := [
	"constant", "texture", "operator", "function", "op_type", "input_name",
	"parameter_name", "default_value_enabled", "default_value", "qualifier",
	"source", "texture_type", "texture_filter", "texture_repeat",
	"hint", "hint_range_min", "hint_range_max", "hint_range_step",
]


func create_graph(params: Dictionary) -> Dictionary:
	var raw_path: Variant = params.get("resource_path", null)
	if not raw_path is String or raw_path.is_empty():
		return _invalid("resource_path must be a nonempty res:// .tres path")
	var path: String = raw_path
	var path_error: Variant = McpPathValidator.path_error(path, "resource_path", true)
	if path_error != null:
		return path_error
	if path.get_extension().to_lower() != "tres":
		return _invalid("resource_path must end in .tres: %s" % path)
	var overwrite: Variant = params.get("overwrite", false)
	if not overwrite is bool:
		return _invalid("overwrite must be a boolean")
	if FileAccess.file_exists(path) and not overwrite:
		return _invalid("Resource already exists at %s (pass overwrite=true to replace)" % path)
	var mode: Variant = params.get("shader_type", "spatial")
	if not mode is String or not MODES.has(mode):
		return _invalid("Unknown shader_type: %s" % str(mode))
	var stages: Variant = params.get("stages", null)
	if not stages is Array or stages.is_empty() or stages.size() > MODE_STAGES[mode].size():
		return _invalid("stages must be a nonempty array of applicable, unique shader stages")
	var count_nodes := 0
	var count_connections := 0
	var seen := {}
	for stage in stages:
		if not stage is Dictionary or not stage.get("stage") is String:
			return _invalid("Each stages entry requires a stage name")
		var name: String = stage.stage
		if not name in MODE_STAGES[mode] or seen.has(name):
			return _invalid("Duplicate or incompatible stage '%s' for %s" % [name, mode])
		seen[name] = true
		if not stage.get("nodes") is Array or not stage.get("connections") is Array:
			return _invalid("Stage %s requires nodes and connections arrays" % name)
		count_nodes += stage.nodes.size()
		count_connections += stage.connections.size()
	if count_nodes > MAX_NODES or count_connections > MAX_CONNECTIONS:
		return _invalid("Graph has %d nodes and %d connections; limits are %d and %d" % [count_nodes, count_connections, MAX_NODES, MAX_CONNECTIONS])
	var shader := VisualShader.new()
	shader.set_mode(MODES[mode])
	var maps := {}
	for stage in stages:
		var built := _build_stage(shader, stage)
		if built.has("error"):
			return built
		maps[stage.stage] = built.id_map
	var saved := _save_atomic(shader, path, overwrite)
	if saved.has("error"):
		return saved
	return {"data": {
		"resource_path": path, "shader_type": mode, "id_map": maps,
		"node_count": count_nodes, "connection_count": count_connections,
		"undoable": false, "reason": "Creating or replacing a resource file is not undoable; assign the material separately.",
	}}


func _build_stage(shader: VisualShader, spec: Dictionary) -> Dictionary:
	var stage: int = STAGES[spec.stage]
	var ids := {}
	var used := {0: true, 1: true}
	## Reserve all explicit integers before allocating any string ID.
	for node_spec in spec.nodes:
		if not node_spec is Dictionary:
			return _invalid("Stage %s: every node must be an object" % spec.stage)
		var raw: Variant = _canonical_id(node_spec.get("id"))
		if not _valid_id(raw) or ids.has(raw):
			return _invalid("Stage %s: missing, reserved or duplicate node ID %s" % [spec.stage, str(raw)])
		ids[raw] = -1
		if raw is int:
			used[raw] = true
			ids[raw] = raw
	var next_id := 2
	for raw in ids:
		if raw is String:
			while used.has(next_id):
				next_id += 1
			ids[raw] = next_id
			used[next_id] = true
	var public_ids := []
	for node_spec in spec.nodes:
		var raw: Variant = _canonical_id(node_spec.id)
		var id: int = ids[raw]
		var class_name_value: Variant = node_spec.get("type")
		if not class_name_value is String:
			return _invalid("Node %s requires a VisualShaderNode type" % str(raw))
		var real_type: String = ALIASES.get(class_name_value, class_name_value)
		if not ClassDB.class_exists(real_type) or not ClassDB.is_parent_class(real_type, "VisualShaderNode") or not ClassDB.can_instantiate(real_type):
			return _invalid("Node %s: %s is not an instantiable VisualShaderNode" % [str(raw), real_type])
		if real_type in ["VisualShaderNodeOutput", "VisualShaderNodeCustom", "VisualShaderNodeExpression", "VisualShaderNodeGlobalExpression"]:
			return _invalid("Node %s: %s is not supported in declarative graphs" % [str(raw), real_type])
		var position_value: Variant = node_spec.get("position", {"x": 0, "y": 0})
		var position_result := _typed_value(TYPE_VECTOR2, position_value)
		if not position_result.has("value"):
			return _invalid("Node %s: position requires finite x/y numbers" % str(raw))
		var node: VisualShaderNode = ClassDB.instantiate(real_type)
		shader.add_node(stage, node, position_result.value, id)
		var values: Variant = node_spec.get("params", {})
		if not values is Dictionary:
			return _invalid("Node %s: params must be an object" % str(raw))
		var merged: Dictionary = IMPLICIT.get(class_name_value, {}).duplicate()
		merged.merge(values, true)
		var applied := _apply_properties(node, merged, str(raw))
		if applied.has("error"):
			return applied
		public_ids.append({"id": raw, "node_id": id})
	var inputs := {}
	for edge in spec.connections:
		if not edge is Dictionary or not edge.has_all(["from_node", "from_port", "to_node", "to_port"]):
			return _invalid("Stage %s: connection requires from_node/from_port/to_node/to_port" % spec.stage)
		if edge.has("stage") or edge.has("from_stage") or edge.has("to_stage"):
			return _invalid("Connections belong to their enclosing stage; cross-stage edges are unsupported")
		var source := _endpoint(edge.from_node, ids)
		var target := _endpoint(edge.to_node, ids)
		if source < 2 or target < 0:
			return _invalid("Stage %s: unknown or invalid connection endpoints %s -> %s" % [spec.stage, str(edge.from_node), str(edge.to_node)])
		var from_port_value := _integral_number(edge.from_port)
		var to_port_value := _integral_number(edge.to_port)
		if from_port_value == null or to_port_value == null or from_port_value < 0 or to_port_value < 0:
			return _invalid("Connection ports must be nonnegative integers")
		var from_port: int = from_port_value
		var to_port: int = to_port_value
		var source_node := shader.get_node(stage, source)
		## Preserve the original texture alpha / vector-component expansion fix.
		if from_port > 64 or to_port > 64:
			return _invalid("Connection port exceeds the supported maximum of 64")
		if source_node == null:
			return _invalid("Stage %s: source node %s is unavailable" % [spec.stage, str(edge.from_node)])
		## This hidden Array names base output ports whose vector components are
		## exposed. Expand only existing base ports needed to reach a component.
		var raw_expanded: Variant = source_node.get("expanded_output_ports")
		var expanded: Array = raw_expanded if raw_expanded is Array else Array(raw_expanded)
		for port in range(from_port):
			if not expanded.has(port):
				expanded.append(port)
		expanded.sort()
		source_node.set("expanded_output_ports", expanded)
		var input_key := "%d:%d" % [target, to_port]
		if inputs.has(input_key) or not shader.can_connect_nodes(stage, source, from_port, target, to_port):
			return _invalid("Stage %s: invalid, duplicate-input or cyclic connection %s" % [spec.stage, str(edge)])
		var err := shader.connect_nodes(stage, source, from_port, target, to_port)
		if err != OK:
			return _invalid("Cannot connect %s: %s" % [str(edge), error_string(err)])
		inputs[input_key] = true
	return {"id_map": public_ids}


static func _valid_id(value: Variant) -> bool:
	return (value is int and value >= 2 and value <= 2147483647) or (value is String and not value.is_empty() and value != "output")


static func _canonical_id(value: Variant) -> Variant:
	if value is String:
		return value
	var number := _integral_number(value)
	return number if number != null else value


static func _endpoint(value: Variant, ids: Dictionary) -> int:
	value = _canonical_id(value)
	if (value is String and value == "output") or (value is int and value == 0):
		return 0
	return int(ids.get(value, -1)) if value is int or value is String else -1


func _apply_properties(node: VisualShaderNode, values: Dictionary, id: String) -> Dictionary:
	var properties := {}
	for property in node.get_property_list():
		properties[str(property.name)] = property
	for key in values:
		if not key is String or not key in PROPERTIES or not properties.has(key):
			return _invalid("Node %s (%s): unsupported property %s" % [id, node.get_class(), str(key)])
		var property: Dictionary = properties[key]
		if int(property.usage) & PROPERTY_USAGE_READ_ONLY or not (int(property.usage) & PROPERTY_USAGE_STORAGE):
			return _invalid("Node %s: property %s is not writable" % [id, key])
		var value: Variant = values[key]
		var converted := {}
		if key == "texture":
			if not value is String:
				return _invalid("Node %s: texture requires a resource path" % id)
			var path_error: Variant = McpPathValidator.path_error(value, "texture")
			if path_error != null:
				return path_error
			if not ResourceLoader.exists(value):
				return _invalid("Node %s: texture not found: %s" % [id, value])
			var texture := ResourceLoader.load(value)
			var expected: String = str(property.get("class_name", property.get("hint_string", "")))
			if not (texture is Texture2D or texture is Texture3D) or (not expected.is_empty() and not texture.is_class(expected)):
				return _invalid("Node %s: incompatible texture %s (expected %s)" % [id, value, expected])
			converted = {"value": texture}
		elif int(property.hint) == PROPERTY_HINT_ENUM and int(property.type) == TYPE_INT:
			converted = _enum_value(str(property.hint_string), value)
		else:
			converted = _typed_value(int(property.type), value)
		if not converted.has("value"):
			return _invalid("Node %s: invalid %s value %s" % [id, key, str(value)])
		if key == "parameter_name" and (str(converted.value).is_empty() or not str(converted.value).is_valid_identifier()):
			return _invalid("Node %s: parameter_name must be a shader identifier" % id)
		node.set(key, converted.value)
		if key == "input_name" and node.get_input_real_name().is_empty():
			return _invalid("Node %s: input %s is unavailable in this shader stage" % [id, str(value)])
	return {}


static func _enum_value(hint: String, value: Variant) -> Dictionary:
	var aliases := {"sub": "subtract", "mul": "multiply", "div": "divide", "mod": "remainder", "pow": "power"}
	var normalized := str(aliases.get(value, value)).replace("_", "").replace(" ", "").to_lower()
	var index := 0
	for item in hint.split(","):
		var parts := item.split(":")
		if parts.size() > 1:
			index = int(parts[1])
		var numeric := _integral_number(value)
		if (numeric != null and numeric == index) or (value is String and parts[0].replace("_", "").replace(" ", "").to_lower() == normalized):
			return {"value": index}
		index += 1
	return {}


static func _typed_value(type: int, value: Variant) -> Dictionary:
	match type:
		TYPE_BOOL:
			return {"value": value} if value is bool else {}
		TYPE_INT:
			var integer := _integral_number(value)
			return {"value": integer} if integer != null else {}
		TYPE_FLOAT:
			return {"value": float(value)} if _number(value) else {}
		TYPE_STRING, TYPE_STRING_NAME:
			return {"value": value} if value is String else {}
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR:
			var keys: Array = ["x", "y"]
			if type == TYPE_VECTOR3:
				keys = ["x", "y", "z"]
			elif type == TYPE_VECTOR4:
				keys = ["x", "y", "z", "w"]
			elif type == TYPE_COLOR:
				keys = ["r", "g", "b"]
			if not value is Dictionary or not value.has_all(keys):
				return {}
			for key in keys:
				if not _number(value[key]):
					return {}
			match type:
				TYPE_VECTOR2: return {"value": Vector2(value.x, value.y)}
				TYPE_VECTOR3: return {"value": Vector3(value.x, value.y, value.z)}
				TYPE_VECTOR4: return {"value": Vector4(value.x, value.y, value.z, value.w)}
				TYPE_COLOR:
					if not _number(value.get("a", 1.0)):
						return {}
					return {"value": Color(value.r, value.g, value.b, value.get("a", 1.0))}
	return {}


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## JSON.parse_string represents every number as float. Accept only values that
## round-trip exactly to an integer; direct GDScript callers may still pass int.
static func _integral_number(value: Variant) -> Variant:
	if value is int:
		return value
	if value is float and is_finite(value) and value == floor(value):
		if value >= -2147483648.0 and value <= 2147483647.0:
			return int(value)
	return null


## Stage in the destination directory, then use the OS rename/replace primitive.
## A failed save or rename never removes/truncates the existing destination.
func _save_atomic(shader: VisualShader, path: String, overwrite: bool) -> Dictionary:
	var directory := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(directory):
		return _invalid("Destination directory does not exist: %s" % directory)
	var temporary := directory.path_join(".godot-ai-shader-%d-%d.tres" % [OS.get_process_id(), Time.get_ticks_usec()])
	var prior_uid := ResourceLoader.get_resource_uid(path) if FileAccess.file_exists(path) else ResourceUID.INVALID_ID
	var err := ResourceSaver.save(shader, temporary)
	if err == OK and prior_uid != ResourceUID.INVALID_ID:
		err = ResourceSaver.set_uid(temporary, prior_uid)
	if err == OK and FileAccess.file_exists(path) and not overwrite:
		err = ERR_ALREADY_EXISTS
	if err == OK:
		err = DirAccess.rename_absolute(temporary, path)
	if err != OK:
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(temporary)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Cannot save VisualShader at %s: %s" % [path, error_string(err)])
	shader.take_over_path(path)
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null:
		filesystem.update_file(path)
	return {}


static func _invalid(message: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, message)
