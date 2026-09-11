@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## Create, read, and edit VisualShader resources. Scene assignment is separate.
##
## `create_graph` builds a fully validated graph from a declarative spec;
## `get_graph` reports an existing graph (stages, nodes, params, connections,
## varyings); `edit_graph` applies a validated operation list to an existing
## resource; `node_catalog` lists the instantiable VisualShaderNode classes
## with the properties this handler accepts. Every write validates the whole
## result in memory first and saves through a same-directory temporary, so a
## failure never truncates the destination.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MaterialValues := preload("res://addons/godot_ai/handlers/material_values.gd")

const MAX_NODES := 256
const MAX_CONNECTIONS := 1024
const MAX_OPERATIONS := 512
const MAX_CATALOG_LIMIT := 500
const MODES := {
	"spatial": Shader.MODE_SPATIAL, "canvas_item": Shader.MODE_CANVAS_ITEM,
	"particles": Shader.MODE_PARTICLES, "sky": Shader.MODE_SKY, "fog": Shader.MODE_FOG,
}
const MODE_NAMES := {
	Shader.MODE_SPATIAL: "spatial", Shader.MODE_CANVAS_ITEM: "canvas_item",
	Shader.MODE_PARTICLES: "particles", Shader.MODE_SKY: "sky", Shader.MODE_FOG: "fog",
}
const STAGES := {
	"vertex": VisualShader.TYPE_VERTEX, "fragment": VisualShader.TYPE_FRAGMENT,
	"light": VisualShader.TYPE_LIGHT, "start": VisualShader.TYPE_START,
	"process": VisualShader.TYPE_PROCESS, "collide": VisualShader.TYPE_COLLIDE,
	"start_custom": VisualShader.TYPE_START_CUSTOM, "process_custom": VisualShader.TYPE_PROCESS_CUSTOM,
	"sky": VisualShader.TYPE_SKY, "fog": VisualShader.TYPE_FOG,
}
const STAGE_NAMES := {
	VisualShader.TYPE_VERTEX: "vertex", VisualShader.TYPE_FRAGMENT: "fragment",
	VisualShader.TYPE_LIGHT: "light", VisualShader.TYPE_START: "start",
	VisualShader.TYPE_PROCESS: "process", VisualShader.TYPE_COLLIDE: "collide",
	VisualShader.TYPE_START_CUSTOM: "start_custom",
	VisualShader.TYPE_PROCESS_CUSTOM: "process_custom",
	VisualShader.TYPE_SKY: "sky", VisualShader.TYPE_FOG: "fog",
}
const MODE_STAGES := {
	"spatial": ["vertex", "fragment", "light"],
	"canvas_item": ["vertex", "fragment", "light"],
	"particles": ["start", "process", "collide", "start_custom", "process_custom"],
	"sky": ["sky"], "fog": ["fog"],
}
## Varyings are a spatial/canvas_item feature; particles/sky/fog have no
## vertex-to-fragment or fragment-to-light stage pair to carry them.
const VARYING_MODES := {
	"spatial": true, "canvas_item": true,
}
const VARYING_MODE_VALUES := {
	"vertex_to_frag_light": VisualShader.VARYING_MODE_VERTEX_TO_FRAG_LIGHT,
	"frag_to_light": VisualShader.VARYING_MODE_FRAG_TO_LIGHT,
}
const VARYING_TYPE_VALUES := {
	"float": VisualShader.VARYING_TYPE_FLOAT,
	"int": VisualShader.VARYING_TYPE_INT,
	"uint": VisualShader.VARYING_TYPE_UINT,
	"vector2": VisualShader.VARYING_TYPE_VECTOR_2D,
	"vector3": VisualShader.VARYING_TYPE_VECTOR_3D,
	"vector4": VisualShader.VARYING_TYPE_VECTOR_4D,
	"boolean": VisualShader.VARYING_TYPE_BOOLEAN,
	"transform": VisualShader.VARYING_TYPE_TRANSFORM,
}
const VARYING_MODE_NAMES := {
	VisualShader.VARYING_MODE_VERTEX_TO_FRAG_LIGHT: "vertex_to_frag_light",
	VisualShader.VARYING_MODE_FRAG_TO_LIGHT: "frag_to_light",
}
const VARYING_TYPE_NAMES := {
	VisualShader.VARYING_TYPE_FLOAT: "float",
	VisualShader.VARYING_TYPE_INT: "int",
	VisualShader.VARYING_TYPE_UINT: "uint",
	VisualShader.VARYING_TYPE_VECTOR_2D: "vector2",
	VisualShader.VARYING_TYPE_VECTOR_3D: "vector3",
	VisualShader.VARYING_TYPE_VECTOR_4D: "vector4",
	VisualShader.VARYING_TYPE_BOOLEAN: "boolean",
	VisualShader.VARYING_TYPE_TRANSFORM: "transform",
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
const UNSUPPORTED_NODES := [
	"VisualShaderNodeOutput", "VisualShaderNodeCustom",
	"VisualShaderNodeExpression", "VisualShaderNodeGlobalExpression",
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
	var varyings := _parse_varyings(params.get("varyings", []), mode)
	if varyings.has("error"):
		return varyings
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
	for varying in varyings.specs:
		shader.add_varying(varying.name, varying.mode, varying.type)
	var saved := _save_atomic(shader, path, overwrite)
	if saved.has("error"):
		return saved
	return {"data": {
		"resource_path": path, "shader_type": mode, "id_map": maps,
		"node_count": count_nodes, "connection_count": count_connections,
		"varyings": varyings.specs.map(func(spec): return spec.name),
		"undoable": false, "reason": "Creating or replacing a resource file is not undoable; assign the material separately.",
	}}


func get_graph(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var path_error: Variant = McpPathValidator.path_error(path, "path")
	if path_error != null:
		return path_error
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "VisualShader not found: %s" % path)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not (loaded is VisualShader):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a VisualShader" % path)
	var shader := loaded as VisualShader
	var mode := str(MODE_NAMES.get(shader.get_mode(), ""))
	var stages: Array[Dictionary] = []
	var node_count := 0
	var connection_count := 0
	for stage_name in MODE_STAGES.get(mode, []):
		var stage: int = STAGES[stage_name]
		var nodes: Array[Dictionary] = []
		for node_id in shader.get_node_list(stage):
			if node_id == 0:
				continue
			var node := shader.get_node(stage, node_id)
			if node == null:
				continue
			var position := shader.get_node_position(stage, node_id)
			nodes.append({
				"id": node_id,
				"type": node.get_class(),
				"position": {"x": position.x, "y": position.y},
				"params": _serialize_node_params(node),
			})
		var connections: Array[Dictionary] = []
		for connection in shader.get_node_connections(stage):
			connections.append({
				"from_node": int(connection.get("from_node", -1)),
				"from_port": int(connection.get("from_port", -1)),
				"to_node": int(connection.get("to_node", -1)),
				"to_port": int(connection.get("to_port", -1)),
			})
		node_count += nodes.size()
		connection_count += connections.size()
		if nodes.is_empty() and connections.is_empty():
			continue
		stages.append({
			"stage": stage_name, "nodes": nodes, "connections": connections,
		})
	return {"data": {
		"path": path, "shader_type": mode, "stages": stages,
		"node_count": node_count, "connection_count": connection_count,
		"varyings": _read_varyings(shader, path),
	}}


func node_catalog(params: Dictionary) -> Dictionary:
	var filter: String = str(params.get("filter", "")).to_lower()
	var offset: int = max(0, int(params.get("offset", 0)))
	var limit: int = clampi(int(params.get("limit", 100)), 1, MAX_CATALOG_LIMIT)
	var matches: Array[String] = []
	for class_name_value in ClassDB.get_class_list():
		var class_name_string := str(class_name_value)
		if not filter.is_empty() and not class_name_string.to_lower().contains(filter):
			continue
		if class_name_string in UNSUPPORTED_NODES:
			continue
		if not ClassDB.can_instantiate(class_name_string):
			continue
		if not ClassDB.is_parent_class(class_name_string, "VisualShaderNode"):
			continue
		matches.append(class_name_string)
	matches.sort()
	var total := matches.size()
	var page: Array[Dictionary] = []
	var end := mini(total, offset + limit)
	for i in range(offset, end):
		var class_name_string: String = matches[i]
		var node: VisualShaderNode = ClassDB.instantiate(class_name_string)
		var supported: Array[String] = []
		if node != null:
			var present := {}
			for property in node.get_property_list():
				present[str(property.name)] = property
			for property_name in PROPERTIES:
				if not present.has(property_name):
					continue
				var property: Dictionary = present[property_name]
				if int(property.usage) & PROPERTY_USAGE_READ_ONLY or not (int(property.usage) & PROPERTY_USAGE_STORAGE):
					continue
				supported.append(property_name)
		page.append({"type": class_name_string, "params": supported})
	return {"data": {
		"nodes": page, "count": page.size(), "total": total,
		"offset": offset, "limit": limit, "aliases": ALIASES,
	}}


func edit_graph(params: Dictionary) -> Dictionary:
	var path: String = params.get("resource_path", "")
	var path_error: Variant = McpPathValidator.path_error(path, "resource_path", true)
	if path_error != null:
		return path_error
	if path.get_extension().to_lower() != "tres":
		return _invalid("resource_path must end in .tres: %s" % path)
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "VisualShader not found: %s" % path)
	var operations: Variant = params.get("operations", null)
	if not operations is Array or operations.is_empty():
		return _invalid("operations must be a nonempty array")
	if operations.size() > MAX_OPERATIONS:
		return _invalid("operations exceeds the %d-entry limit" % MAX_OPERATIONS)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if not (loaded is VisualShader):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a VisualShader" % path)
	var shader := loaded as VisualShader
	var mode := str(MODE_NAMES.get(shader.get_mode(), ""))

	## Alias table for IDs introduced by this call: string ids are resolved to
	## their allocated integer so later operations can reference them.
	var aliases := {}
	var added: Array[Dictionary] = []
	var inputs := _collect_inputs(shader, mode)
	for i in operations.size():
		var operation: Variant = operations[i]
		if not operation is Dictionary or not operation.get("op") is String:
			return _invalid("operations[%d] requires an op name" % i)
		var applied := _apply_edit(shader, mode, operation, aliases, inputs)
		if applied.has("error"):
			return ErrorCodes.prefix_message(applied, "operations[%d] (%s)" % [i, operation.op])
		if applied.has("added"):
			added.append(applied.added)

	var total_nodes := 0
	var total_connections := 0
	for stage_name in MODE_STAGES.get(mode, []):
		var stage: int = STAGES[stage_name]
		for node_id in shader.get_node_list(stage):
			if node_id != 0:
				total_nodes += 1
		total_connections += shader.get_node_connections(stage).size()
	if total_nodes > MAX_NODES or total_connections > MAX_CONNECTIONS:
		return _invalid("Resulting graph has %d nodes and %d connections; limits are %d and %d" % [total_nodes, total_connections, MAX_NODES, MAX_CONNECTIONS])

	var saved := _save_atomic(shader, path, true)
	if saved.has("error"):
		return saved
	return {"data": {
		"resource_path": path,
		"operations_applied": operations.size(),
		"added": added,
		"node_count": total_nodes,
		"connection_count": total_connections,
		"varyings": _read_varyings(shader, path),
		"undoable": false,
		"reason": "Editing a resource file is not undoable; assign the material separately.",
	}}


## Apply one edit operation to `shader` in place. Returns {} on success (plus
## `added` for add_node) or an error dict. `aliases` maps this call's string
## ids to allocated integers; `inputs` tracks occupied (node, port) inputs.
func _apply_edit(
	shader: VisualShader, mode: String, operation: Dictionary,
	aliases: Dictionary, inputs: Dictionary,
) -> Dictionary:
	match operation.op:
		"add_node":
			return _edit_add_node(shader, mode, operation, aliases)
		"remove_node":
			var stage := _edit_stage(operation)
			if stage.has("error"):
				return stage
			var node_id := _edit_node_id(shader, stage.value, operation.get("id"), aliases)
			if node_id.has("error"):
				return node_id
			if node_id.value < 2:
				return _invalid("cannot remove the built-in output node")
			shader.remove_node(stage.value, node_id.value)
			return {}
		"replace_node":
			var stage := _edit_stage(operation)
			if stage.has("error"):
				return stage
			var node_id := _edit_node_id(shader, stage.value, operation.get("id"), aliases)
			if node_id.has("error"):
				return node_id
			if node_id.value < 2:
				return _invalid("cannot replace the built-in output node")
			var class_name_value: Variant = operation.get("type")
			if not class_name_value is String:
				return _invalid("replace_node requires a type")
			var real_type := _resolve_type(class_name_value)
			if real_type.is_empty():
				return _invalid("%s is not a supported VisualShaderNode" % str(class_name_value))
			shader.replace_node(stage.value, node_id.value, real_type)
			var values: Variant = operation.get("params", {})
			if not values is Dictionary:
				return _invalid("params must be an object")
			return _apply_properties(shader.get_node(stage.value, node_id.value), values, str(operation.id))
		"set_node_params":
			var stage := _edit_stage(operation)
			if stage.has("error"):
				return stage
			var node_id := _edit_node_id(shader, stage.value, operation.get("id"), aliases)
			if node_id.has("error"):
				return node_id
			var node := shader.get_node(stage.value, node_id.value)
			if node == null:
				return _invalid("node %s is unavailable" % str(operation.id))
			var values: Variant = operation.get("params", {})
			if not values is Dictionary or values.is_empty():
				return _invalid("set_node_params requires a nonempty params object")
			return _apply_properties(node, values, str(operation.id))
		"set_node_position":
			var stage := _edit_stage(operation)
			if stage.has("error"):
				return stage
			var node_id := _edit_node_id(shader, stage.value, operation.get("id"), aliases)
			if node_id.has("error"):
				return node_id
			var position := _typed_value(TYPE_VECTOR2, operation.get("position", null))
			if not position.has("value"):
				return _invalid("position requires finite x/y numbers")
			shader.set_node_position(stage.value, node_id.value, position.value)
			return {}
		"connect", "disconnect":
			return _edit_connection(shader, operation, aliases, inputs)
		"add_varying":
			if not VARYING_MODES.has(mode):
				return _invalid("varyings are only supported for spatial/canvas_item shaders")
			var parsed := _parse_varying(operation, "")
			if parsed.has("error"):
				return parsed
			if shader.has_varying(parsed.name):
				return _invalid("varying '%s' already exists" % parsed.name)
			shader.add_varying(parsed.name, parsed.mode, parsed.type)
			return {}
		"remove_varying":
			var varying_name: Variant = operation.get("name")
			if not varying_name is String or not (varying_name as String).is_valid_identifier():
				return _invalid("remove_varying requires an identifier name")
			if not shader.has_varying(varying_name):
				return _invalid("varying '%s' does not exist" % varying_name)
			shader.remove_varying(varying_name)
			return {}
	return _invalid("unknown edit op '%s'" % operation.op)


func _edit_add_node(
	shader: VisualShader, mode: String, operation: Dictionary, aliases: Dictionary,
) -> Dictionary:
	var stage_result := _edit_stage(operation)
	if stage_result.has("error"):
		return stage_result
	var stage: int = stage_result.value
	var class_name_value: Variant = operation.get("type")
	if not class_name_value is String:
		return _invalid("add_node requires a type")
	var real_type := _resolve_type(class_name_value)
	if real_type.is_empty():
		return _invalid("%s is not a supported VisualShaderNode" % str(class_name_value))
	var raw_id: Variant = operation.get("id", null)
	var node_id := 0
	var public_id: Variant = null
	if raw_id == null:
		node_id = shader.get_valid_node_id(stage)
		public_id = node_id
	else:
		var canonical := _canonical_id(raw_id)
		if not _valid_id(canonical):
			return _invalid("missing, reserved or invalid node ID %s" % str(canonical))
		if canonical is int:
			if shader.get_node(stage, canonical) != null or canonical < 2:
				return _invalid("node ID %s is already used" % str(canonical))
			node_id = canonical
			public_id = canonical
		else:
			node_id = shader.get_valid_node_id(stage)
			aliases[canonical] = node_id
			public_id = canonical
	var position := _typed_value(TYPE_VECTOR2, operation.get("position", {"x": 0, "y": 0}))
	if not position.has("value"):
		return _invalid("position requires finite x/y numbers")
	var node: VisualShaderNode = ClassDB.instantiate(real_type)
	shader.add_node(stage, node, position.value, node_id)
	var values: Variant = operation.get("params", {})
	if not values is Dictionary:
		return _invalid("params must be an object")
	var merged: Dictionary = IMPLICIT.get(class_name_value, {}).duplicate()
	merged.merge(values, true)
	var applied := _apply_properties(node, merged, str(public_id))
	if applied.has("error"):
		return applied
	return {"added": {
		"id": public_id, "node_id": node_id, "stage": STAGE_NAMES[stage],
	}}


func _edit_connection(
	shader: VisualShader, operation: Dictionary, aliases: Dictionary, inputs: Dictionary,
) -> Dictionary:
	var stage_result := _edit_stage(operation)
	if stage_result.has("error"):
		return stage_result
	var stage: int = stage_result.value
	var source := _edit_endpoint(shader, stage, operation.get("from_node"), aliases)
	if source.has("error"):
		return source
	var target := _edit_endpoint(shader, stage, operation.get("to_node"), aliases)
	if target.has("error"):
		return target
	var from_port := _integral_number(operation.get("from_port"))
	var to_port := _integral_number(operation.get("to_port"))
	if from_port == null or to_port == null or from_port < 0 or to_port < 0 or from_port > 64 or to_port > 64:
		return _invalid("connection ports must be integers from 0 through 64")
	if operation.op == "disconnect":
		shader.disconnect_nodes(stage, source.value, from_port, target.value, to_port)
		inputs.erase("%s:%d:%d:%d" % [stage, target.value, to_port, source.value])
		return {}
	return _connect_nodes(shader, stage, source.value, from_port, target.value, to_port, inputs)


func _edit_stage(operation: Dictionary) -> Dictionary:
	var stage_name: Variant = operation.get("stage")
	if not stage_name is String or not STAGES.has(stage_name):
		return _invalid("stage must be one of: %s" % ", ".join(STAGES.keys()))
	return {"value": STAGES[stage_name]}


func _edit_node_id(shader: VisualShader, stage: int, raw: Variant, aliases: Dictionary) -> Dictionary:
	var canonical := _canonical_id(raw)
	if canonical is String:
		if canonical == "output":
			return {"value": 0}
		if not aliases.has(canonical):
			return _invalid("unknown node ID %s" % canonical)
		return {"value": int(aliases[canonical])}
	var number := _integral_number(canonical)
	if number == null:
		return _invalid("node id must be an integer or a string used by add_node in this call")
	if number == 0:
		return {"value": 0}
	if shader.get_node(stage, number) == null:
		return _invalid("node ID %d does not exist in this stage" % number)
	return {"value": number}


func _edit_endpoint(shader: VisualShader, stage: int, raw: Variant, aliases: Dictionary) -> Dictionary:
	var canonical := _canonical_id(raw)
	if (canonical is String and canonical == "output") or (canonical is int and canonical == 0):
		return {"value": 0}
	if canonical is String:
		if not aliases.has(canonical):
			return _invalid("unknown node ID %s" % canonical)
		return {"value": int(aliases[canonical])}
	var number := _integral_number(canonical)
	if number == null:
		return _invalid("connection endpoints must be node IDs")
	if shader.get_node(stage, number) == null:
		return _invalid("node ID %d does not exist in this stage" % number)
	return {"value": number}


## Snapshot of occupied input ports per stage, keyed stage:target:port:source
## so a disconnect can release the exact edge and connect can reject duplicates.
func _collect_inputs(shader: VisualShader, mode: String) -> Dictionary:
	var inputs := {}
	for stage_name in MODE_STAGES.get(mode, []):
		var stage: int = STAGES[stage_name]
		for connection in shader.get_node_connections(stage):
			var target := int(connection.get("to_node", -1))
			var to_port := int(connection.get("to_port", -1))
			var source := int(connection.get("from_node", -1))
			inputs["%s:%d:%d" % [stage, target, to_port]] = true
			inputs["%s:%d:%d:%d" % [stage, target, to_port, source]] = true
	return inputs


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
		if real_type in UNSUPPORTED_NODES:
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
		var connected := _connect_nodes(shader, stage, source, from_port_value, target, to_port_value, inputs)
		if connected.has("error"):
			return _invalid("Stage %s: %s" % [spec.stage, connected.error.message])
	return {"id_map": public_ids}


## Validate and create one connection. `inputs` maps `stage:target:port` to
## true; the caller owns the dict so duplicate-input detection spans a whole
## graph build or edit call.
func _connect_nodes(
	shader: VisualShader, stage: int, source: int, from_port: int,
	target: int, to_port: int, inputs: Dictionary,
) -> Dictionary:
	var source_node := shader.get_node(stage, source)
	if from_port > 64 or to_port > 64:
		return _invalid("Connection port exceeds the supported maximum of 64")
	if source_node == null:
		return _invalid("source node %d is unavailable" % source)
	## This hidden Array names base output ports whose vector components are
	## exposed. Expand only existing base ports needed to reach a component.
	var raw_expanded: Variant = source_node.get("expanded_output_ports")
	var expanded: Array = raw_expanded if raw_expanded is Array else Array(raw_expanded)
	for port in range(from_port):
		if not expanded.has(port):
			expanded.append(port)
	expanded.sort()
	source_node.set("expanded_output_ports", expanded)
	var input_key := "%d:%d" % [stage, target, to_port]
	if inputs.has(input_key) or not shader.can_connect_nodes(stage, source, from_port, target, to_port):
		return _invalid("invalid, duplicate-input or cyclic connection")
	var err := shader.connect_nodes(stage, source, from_port, target, to_port)
	if err != OK:
		return _invalid("cannot connect: %s" % error_string(err))
	inputs[input_key] = true
	return {}


## Parse a top-level `varyings` array for create_graph. Returns
## {specs: [{name, mode, type}]} or an error dict.
func _parse_varyings(raw: Variant, mode: String) -> Dictionary:
	if not raw is Array:
		return _invalid("varyings must be an array")
	if raw.is_empty():
		return {"specs": []}
	if not VARYING_MODES.has(mode):
		return _invalid("varyings are only supported for spatial/canvas_item shaders")
	var specs: Array[Dictionary] = []
	var seen := {}
	for entry in raw:
		if not entry is Dictionary:
			return _invalid("each varying must be an object")
		var parsed := _parse_varying(entry, "")
		if parsed.has("error"):
			return parsed
		if seen.has(parsed.name):
			return _invalid("duplicate varying '%s'" % parsed.name)
		seen[parsed.name] = true
		specs.append({"name": parsed.name, "mode": parsed.mode, "type": parsed.type})
	return {"specs": specs}


## Parse one {name, mode, type} varying spec. `label` is unused today but keeps
## call sites explicit about which entry failed.
func _parse_varying(entry: Dictionary, _label: String) -> Dictionary:
	var varying_name: Variant = entry.get("name")
	if not varying_name is String or not (varying_name as String).is_valid_identifier():
		return _invalid("varying name must be a shader identifier")
	var mode := _enum_lookup(VARYING_MODE_VALUES, entry.get("mode"), "varying_mode_")
	if mode == null:
		return _invalid("varying mode must be one of: %s" % ", ".join(VARYING_MODE_VALUES.keys()))
	var varying_type := _enum_lookup(VARYING_TYPE_VALUES, entry.get("type"), "varying_type_")
	if varying_type == null:
		return _invalid("varying type must be one of: %s" % ", ".join(VARYING_TYPE_VALUES.keys()))
	return {"name": varying_name, "mode": mode, "type": varying_type}


## Resolve a friendly or engine enum name / raw integer against `table`.
static func _enum_lookup(table: Dictionary, value: Variant, prefix: String) -> Variant:
	if value is int:
		return value if table.values().has(value) else null
	if not value is String:
		return null
	var normalized: String = value.to_lower().replace(prefix, "").replace("_", "")
	for key in table:
		if key.replace("_", "") == normalized:
			return table[key]
	return null


## Report a VisualShader's varyings. The engine exposes varying names through
## dynamic `varyings/<name>` properties but no mode/type getters, so the
## serialized resource text carries the `"<mode>,<type>"` values; fall back to
## names only when a value cannot be read.
func _read_varyings(shader: VisualShader, path: String) -> Array[Dictionary]:
	var names: Array[String] = []
	for property in shader.get_property_list():
		var property_name := str(property.name)
		if property_name.begins_with("varyings/"):
			names.append(property_name.substr("varyings/".length()))
	names.sort()
	var text := ""
	if not names.is_empty():
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			text = file.get_as_text()
			file.close()
	var out: Array[Dictionary] = []
	for varying_name in names:
		var entry := {"name": varying_name}
		var raw: Variant = shader.get("varyings/" + varying_name)
		if raw is String:
			var parts: PackedStringArray = (raw as String).split(",")
			if parts.size() == 2:
				entry["mode"] = VARYING_MODE_NAMES.get(int(parts[0]), "")
				entry["type"] = VARYING_TYPE_NAMES.get(int(parts[1]), "")
		if not entry.has("mode"):
			var from_text := _varying_from_text(text, varying_name)
			if not from_text.is_empty():
				var parts: PackedStringArray = from_text.split(",")
				if parts.size() == 2:
					entry["mode"] = VARYING_MODE_NAMES.get(int(parts[0]), "")
					entry["type"] = VARYING_TYPE_NAMES.get(int(parts[1]), "")
		out.append(entry)
	return out


static func _varying_from_text(text: String, varying_name: String) -> String:
	var needle := "varyings/%s" % varying_name
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if not line.begins_with(needle):
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var value := line.substr(eq + 1).strip_edges()
		return value.trim_prefix("\"").trim_suffix("\"")
	return ""


func _serialize_node_params(node: VisualShaderNode) -> Dictionary:
	var present := {}
	for property in node.get_property_list():
		present[str(property.name)] = property
	var params := {}
	for property_name in PROPERTIES:
		if not present.has(property_name):
			continue
		var property: Dictionary = present[property_name]
		if not (int(property.usage) & PROPERTY_USAGE_STORAGE):
			continue
		params[property_name] = MaterialValues.serialize_value(node.get(property_name))
	return params


static func _resolve_type(value: String) -> String:
	var real_type: String = ALIASES.get(value, value)
	if not ClassDB.class_exists(real_type) or not ClassDB.is_parent_class(real_type, "VisualShaderNode") or not ClassDB.can_instantiate(real_type):
		return ""
	if real_type in UNSUPPORTED_NODES:
		return ""
	return real_type


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
	if node == null:
		return _invalid("node %s is unavailable" % id)
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
