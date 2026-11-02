@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const Serializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")
const MAX_TRANSITION_INPUTS := 256
const MAX_BLEND_POINTS := 64
const ROOT_TYPES := {"state_machine": "AnimationNodeStateMachine", "blend_tree": "AnimationNodeBlendTree", "blend_space_1d": "AnimationNodeBlendSpace1D", "blend_space_2d": "AnimationNodeBlendSpace2D"}

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func _name_error(value: Variant) -> Dictionary:
	if not value is String or value.is_empty() or value.contains("/"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Graph names must be nonempty strings without '/': %s" % str(value))
	return {}


func _position(value: Variant) -> Variant:
	if not value is Dictionary or not value.has("x") or not value.has("y"):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "position must be {x, y}")
	for key in ["x", "y"]:
		if not (value[key] is int or value[key] is float) or not is_finite(float(value[key])):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "position.%s must be finite" % key)
	var result := Vector2(value.x, value.y)
	if not result.is_finite():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "position exceeds native Vector2 range")
	return result


func _resource_write_error(resource: Resource) -> Dictionary:
	if resource.get_script() != null or ClassDB.class_get_api_type(resource.get_class()) not in [ClassDB.API_CORE, ClassDB.API_EDITOR]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Graph edits require engine built-in resources without scripts or GDExtension classes")
	return {}


func _resolve(params: Dictionary, write := true) -> Dictionary:
	var check := McpNodeValidator.require_scene_or_error()
	if check.has("error"):
		return check
	var tree_path: String = params.get("tree_path", "")
	var tree := McpScenePath.resolve(tree_path, check.scene_root) as AnimationTree
	if tree == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "AnimationTree not found: %s" % tree_path)
	if write:
		var error := McpNodeValidator.writable_error(tree, check.scene_root)
		if not error.is_empty():
			return error
	var graph: AnimationNode = tree.tree_root
	if graph == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "AnimationTree has no tree_root")
	if write:
		var error := _resource_write_error(graph)
		if not error.is_empty():
			return error
	var graph_path: String = params.get("graph_path", "")
	if not graph_path.is_empty():
		for part in graph_path.split("/", true):
			if (graph is AnimationNodeStateMachine or graph is AnimationNodeBlendTree) and graph.has_node(part):
				graph = graph.get_node(part)
			elif (graph is AnimationNodeBlendSpace1D or graph is AnimationNodeBlendSpace2D) and graph.find_blend_point_by_name(part) >= 0:
				graph = graph.get_blend_point_node(graph.find_blend_point_by_name(part))
			else:
				return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Graph node not found: %s" % graph_path)
			if write:
				var error := _resource_write_error(graph)
				if not error.is_empty():
					return error
	return {"scene_root": check.scene_root, "tree": tree, "graph": graph}


func _parameters(tree: AnimationTree) -> Dictionary:
	var values := {}
	for prop in tree.get_property_list():
		if String(prop.name).begins_with("parameters/") and prop.type != TYPE_OBJECT and prop.usage & PROPERTY_USAGE_STORAGE:
			values[prop.name] = tree.get(prop.name)
	return values


func _restore_parameters(tree: AnimationTree, values: Dictionary) -> void:
	var names := {}
	for prop in tree.get_property_list():
		names[prop.name] = true
	for key in values:
		if names.has(key):
			tree.set(key, values[key])


func _begin(ctx: Dictionary, label: String) -> Array:
	# A shared graph can remove dynamic parameters from more than one tree.
	var before := []
	var trees: Array[Node] = ctx.scene_root.find_children("*", "AnimationTree", true, false)
	if ctx.scene_root is AnimationTree:
		trees.append(ctx.scene_root)
	for tree in trees:
		before.append({"tree": tree, "parameters": _parameters(tree)})
	_undo_redo.create_action("MCP: " + label, UndoRedo.MERGE_DISABLE, ctx.scene_root)
	return before


func _commit(ctx: Dictionary, before: Array) -> Dictionary:
	for item in before:
		_undo_redo.add_undo_method(self, "_restore_parameters", item.tree, item.parameters)
	_undo_redo.commit_action()
	return {"data": {"undoable": true, "graph": _graph_data(ctx.graph)}}


func _editable_property(resource: Resource, prop: Dictionary) -> bool:
	if prop.name == "script" or prop.usage & PROPERTY_USAGE_READ_ONLY:
		return false
	if prop.usage & PROPERTY_USAGE_EDITOR:
		return true
	if resource is AnimationNodeBlendSpace1D or resource is AnimationNodeBlendSpace2D:
		return prop.name in ["min_space", "max_space", "snap", "value_label", "x_label", "y_label", "blend_mode", "sync_mode", "cyclic_length"]
	return false


func _properties(resource: Resource, properties: Variant) -> Variant:
	if not properties is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "properties must be a dictionary")
	for key in properties:
		var found := false
		for prop in resource.get_property_list():
			if prop.name == key and _editable_property(resource, prop):
				found = true
				if prop.type == TYPE_VECTOR2:
					var position: Variant = _position(properties[key])
					if position is Dictionary:
						return position
				if prop.type == TYPE_BOOL and not properties[key] is bool:
					return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a boolean" % key)
				if prop.type in [TYPE_INT, TYPE_FLOAT]:
					var value: Variant = properties[key]
					if not (value is int or value is float) or not is_finite(float(value)) or (prop.type == TYPE_INT and float(value) != floor(float(value))):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be a finite %s" % [key, type_string(prop.type)])
				if prop.type == TYPE_INT and prop.hint == PROPERTY_HINT_ENUM:
					var allowed := []
					var next := 0
					for item in String(prop.hint_string).split(","):
						if item.contains(":"):
							next = int(item.get_slice(":", 1))
						allowed.append(next)
						next += 1
					if float(properties[key]) not in allowed.map(func(value: int) -> float: return float(value)):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid %s enum value: %s" % [key, str(properties[key])])
				if resource is AnimationNodeTransition:
					if key == "input_count" and (float(properties[key]) < 0 or float(properties[key]) > MAX_TRANSITION_INPUTS):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "input_count must be between 0 and %d per graph node" % MAX_TRANSITION_INPUTS)
					if String(key).begins_with("input_") and String(key).ends_with("/name") and (str(properties[key]).contains(".") or str(properties[key]).contains("/")):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Input names must not contain '.' or '/'")
				if resource is AnimationNodeStateMachineTransition:
					if key == "xfade_time" and float(properties[key]) < 0:
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "xfade_time must not be negative")
					if key == "advance_condition" and (str(properties[key]).contains("/") or str(properties[key]).contains(":")):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "advance_condition must not contain '/' or ':'")
				break
		if not found:
			return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS, "Property '%s' is not an editable native property; use graph operations for structure" % key)
		var error: Variant = ResourceHandler._apply_resource_properties(resource, {key: properties[key]})
		if error != null:
			return error
		var stored: Variant = resource.get(key)
		if stored is int and (properties[key] is int or properties[key] is float) and float(stored) != float(properties[key]):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s exceeds the native integer range" % key)
		if stored is Vector2 and not stored.is_finite():
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s exceeds the native finite Vector2 range" % key)
		if stored is float and not is_finite(stored):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s exceeds the native finite range" % key)
	return null


func _new_node(params: Dictionary, root_only: bool) -> Variant:
	var type: String = params.get("node_type", "AnimationNodeAnimation")
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "AnimationRootNode" if root_only else "AnimationNode") or not ClassDB.can_instantiate(type) or type in ["AnimationNode", "AnimationRootNode", "AnimationNodeOutput", "AnimationNodeStartState", "AnimationNodeEndState"]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Unsupported native animation node type: %s" % type)
	if ClassDB.class_get_api_type(type) not in [ClassDB.API_CORE, ClassDB.API_EDITOR]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Graph nodes must be engine built-in classes, not GDExtensions")
	var node: AnimationNode = ClassDB.instantiate(type)
	var error: Variant = _properties(node, params.get("properties", {}))
	return node if error == null else error


func _property_data(resource: Resource) -> Dictionary:
	var data := {}
	for prop in resource.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR or _editable_property(resource, prop)) and prop.type != TYPE_NIL and prop.name != "script":
			data[prop.name] = Serializer.serialize(resource.get(prop.name))
	return data


func _transitions(graph: AnimationNodeStateMachine) -> Array:
	var result := []
	for index in graph.get_transition_count():
		result.append({"from": String(graph.get_transition_from(index)), "to": String(graph.get_transition_to(index)), "resource": graph.get_transition(index)})
	return result


func _add_transition(graph: AnimationNodeStateMachine, from_state: String, to_state: String, transition: AnimationNodeStateMachineTransition) -> void:
	graph.add_transition(from_state, to_state, transition)
	graph.emit_changed()
	graph.tree_changed.emit()


func _remove_transition(graph: AnimationNodeStateMachine, from_state: String, to_state: String) -> void:
	graph.remove_transition(from_state, to_state)
	graph.emit_changed()
	graph.tree_changed.emit()


func _restore_transitions(graph: AnimationNodeStateMachine, transitions: Array) -> void:
	while graph.get_transition_count() > 0:
		graph.remove_transition_by_index(0)
	for item in transitions:
		graph.add_transition(item.from, item.to, item.resource)
	graph.emit_changed()
	graph.tree_changed.emit()


func _restore_connections(graph: AnimationNodeBlendTree, connections: Array) -> void:
	var current: Array = graph.get("node_connections")
	for i in range(0, current.size(), 3):
		graph.disconnect_node(current[i], current[i + 1])
	for i in range(0, connections.size(), 3):
		graph.connect_node(connections[i], connections[i + 1], connections[i + 2])


func _graph_data(graph: AnimationNode) -> Dictionary:
	var data := {"class": graph.get_class(), "resource_path": graph.resource_path, "properties": _property_data(graph)}
	if graph is AnimationNodeStateMachine or graph is AnimationNodeBlendTree:
		data.nodes = []
		for name in graph.get_node_list():
			var node: AnimationNode = graph.get_node(name)
			var inputs := []
			for index in node.get_input_count():
				inputs.append(String(node.get_input_name(index)))
			data.nodes.append({"name": String(name), "class": node.get_class(), "position": Serializer.serialize(graph.get_node_position(name)), "inputs": inputs, "properties": _property_data(node)})
	if graph is AnimationNodeStateMachine:
		data.transitions = []
		for item in _transitions(graph):
			data.transitions.append({"from": item.from, "to": item.to, "properties": _property_data(item.resource)})
	if graph is AnimationNodeBlendTree:
		data.connections = []
		var connections: Array = graph.get("node_connections")
		for i in range(0, connections.size(), 3):
			data.connections.append({"input_node": String(connections[i]), "input_index": connections[i + 1], "output_node": String(connections[i + 2])})
	if graph is AnimationNodeBlendSpace1D or graph is AnimationNodeBlendSpace2D:
		data.points = []
		for index in graph.get_blend_point_count():
			var point: AnimationRootNode = graph.get_blend_point_node(index)
			data.points.append({"index": index, "name": String(graph.get_blend_point_name(index)), "class": point.get_class(), "position": Serializer.serialize(graph.get_blend_point_position(index)), "properties": _property_data(point)})
		if graph is AnimationNodeBlendSpace2D:
			data.auto_triangles = graph.auto_triangles
			data.triangles = _triangles(graph)
	return data


func tree_get(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params, false)
	if ctx.has("error"):
		return ctx
	return {"data": {"graph": _graph_data(ctx.graph), "parameters": Serializer.serialize(_parameters(ctx.tree)), "active": ctx.tree.active}}


func tree_create(params: Dictionary) -> Dictionary:
	var check := McpNodeValidator.require_scene_or_error()
	if check.has("error"):
		return check
	var parent_path: String = params.get("parent_path", "")
	var parent: Node = check.scene_root if parent_path.is_empty() else McpScenePath.resolve(parent_path, check.scene_root)
	if parent == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "Parent not found: %s" % parent_path)
	var error := McpNodeValidator.writable_error(parent, check.scene_root)
	if not error.is_empty():
		return error
	var name: String = params.get("name", "AnimationTree")
	if name.is_empty() or NodePath(name).get_name_count() != 1 or name.validate_node_name() != name or name in [".", ".."] or parent.get_node_or_null(NodePath(name)) != null:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid or existing node name: %s" % name)
	var root_type: String = params.get("root_type", "state_machine")
	if not ROOT_TYPES.has(root_type):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "root_type must be one of: %s" % ", ".join(ROOT_TYPES.keys()))
	var player_path: String = params.get("player_path", "")
	var player := McpScenePath.resolve(player_path, check.scene_root) as AnimationPlayer
	if player == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "AnimationPlayer not found: %s" % player_path)
	var tree := AnimationTree.new()
	tree.name = name
	tree.active = false
	tree.tree_root = ClassDB.instantiate(ROOT_TYPES[root_type])
	_undo_redo.create_action("MCP: Create AnimationTree", UndoRedo.MERGE_DISABLE, check.scene_root)
	_undo_redo.add_do_method(parent, "add_child", tree, true)
	_undo_redo.add_do_method(tree, "set_owner", check.scene_root)
	_undo_redo.add_do_method(self, "_link_player", tree, player)
	_undo_redo.add_undo_method(parent, "remove_child", tree)
	_undo_redo.add_do_reference(tree)
	_undo_redo.commit_action()
	return {"data": {"path": McpScenePath.from_node(tree, check.scene_root), "root_type": root_type, "active": tree.active, "undoable": true}}


func _link_player(tree: AnimationTree, player: AnimationPlayer) -> void:
	tree.anim_player = tree.get_path_to(player)


func _container_error(graph: AnimationNode) -> Dictionary:
	if not graph is AnimationNodeStateMachine and not graph is AnimationNodeBlendTree:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "graph_path must select a state machine or blend tree")
	return {}


func tree_node_add(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	var error := _container_error(ctx.graph)
	if not error.is_empty():
		return error
	var name: Variant = params.get("name", "")
	error = _name_error(name)
	if not error.is_empty():
		return error
	if ctx.graph.has_node(name):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Graph node already exists: %s" % name)
	var position: Variant = _position(params.get("position", {"x": 0, "y": 0}))
	if position is Dictionary:
		return position
	var node: Variant = _new_node(params, ctx.graph is AnimationNodeStateMachine)
	if node is Dictionary:
		return node
	var before := _begin(ctx, "Add animation graph node %s" % name)
	_undo_redo.add_do_method(ctx.graph, "add_node", name, node, position)
	_undo_redo.add_undo_method(ctx.graph, "remove_node", name)
	return _commit(ctx, before)


func tree_node_remove(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	var error := _container_error(ctx.graph)
	if not error.is_empty():
		return error
	var name: String = params.get("name", "")
	if not ctx.graph.has_node(name) or (ctx.graph is AnimationNodeStateMachine and name in ["Start", "End"]) or (ctx.graph is AnimationNodeBlendTree and name == "output"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Graph node missing or reserved: %s" % name)
	var before := _begin(ctx, "Remove animation graph node %s" % name)
	_undo_redo.add_do_method(ctx.graph, "remove_node", name)
	_undo_redo.add_undo_method(ctx.graph, "add_node", name, ctx.graph.get_node(name), ctx.graph.get_node_position(name))
	if ctx.graph is AnimationNodeStateMachine:
		_undo_redo.add_undo_method(self, "_restore_transitions", ctx.graph, _transitions(ctx.graph))
	else:
		_undo_redo.add_undo_method(self, "_restore_connections", ctx.graph, ctx.graph.get("node_connections"))
	return _commit(ctx, before)


func tree_node_set(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	var resource: AnimationNode = ctx.graph
	var updated := resource.duplicate(false) as AnimationNode
	if updated == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not duplicate native AnimationNode for validation")
	var properties: Variant = params.get("properties", {})
	var error: Variant = _properties(updated, properties)
	if error != null:
		return error
	if properties.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide properties")
	if updated.get_input_count() != resource.get_input_count():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Set input topology during tree_node_add; changing it could remove graph connections")
	var before := _begin(ctx, "Set animation graph node properties")
	for key in properties:
		_undo_redo.force_fixed_history()
		_undo_redo.add_do_property(resource, key, updated.get(key))
		_undo_redo.force_fixed_history()
		_undo_redo.add_undo_property(resource, key, resource.get(key))
	return _commit(ctx, before)


func _connection_context(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	if not ctx.graph is AnimationNodeBlendTree:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "graph_path must select a blend tree")
	var name: String = params.get("input_node", "")
	var index: Variant = params.get("input_index", -1)
	if not ctx.graph.has_node(name) or not (index is int or index is float) or not is_finite(float(index)) or float(index) != floor(float(index)) or index < 0 or index >= ctx.graph.get_node(name).get_input_count():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid blend input %s[%s]" % [name, str(index)])
	ctx.input_node = name
	ctx.input_index = int(index)
	ctx.connections = ctx.graph.get("node_connections")
	return ctx


func tree_connect(params: Dictionary) -> Dictionary:
	var ctx := _connection_context(params)
	if ctx.has("error"):
		return ctx
	var output: String = params.get("output_node", "")
	if output == "output" or not ctx.graph.has_node(output) or output == ctx.input_node:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid blend output: %s" % output)
	var downstream := {}
	for i in range(0, ctx.connections.size(), 3):
		if (ctx.connections[i] == ctx.input_node and ctx.connections[i + 1] == ctx.input_index) or ctx.connections[i + 2] == output:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Blend input or output is already connected; disconnect it first")
		downstream[ctx.connections[i + 2]] = ctx.connections[i]
	var cursor: String = ctx.input_node
	var seen := {}
	while downstream.has(cursor) and not seen.has(cursor):
		seen[cursor] = true
		cursor = downstream[cursor]
		if cursor == output:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Blend connection would create a cycle")
	var before := _begin(ctx, "Connect animation blend nodes")
	_undo_redo.add_do_method(ctx.graph, "connect_node", ctx.input_node, ctx.input_index, output)
	_undo_redo.add_undo_method(ctx.graph, "disconnect_node", ctx.input_node, ctx.input_index)
	return _commit(ctx, before)


func tree_disconnect(params: Dictionary) -> Dictionary:
	var ctx := _connection_context(params)
	if ctx.has("error"):
		return ctx
	for i in range(0, ctx.connections.size(), 3):
		if ctx.connections[i] == ctx.input_node and ctx.connections[i + 1] == ctx.input_index:
			var before := _begin(ctx, "Disconnect animation blend nodes")
			_undo_redo.add_do_method(ctx.graph, "disconnect_node", ctx.input_node, ctx.input_index)
			_undo_redo.add_undo_method(ctx.graph, "connect_node", ctx.input_node, ctx.input_index, ctx.connections[i + 2])
			return _commit(ctx, before)
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Blend input is not connected")


func _transition_context(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	if not ctx.graph is AnimationNodeStateMachine:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "graph_path must select a state machine")
	ctx.from = params.get("from_state", "")
	ctx.to = params.get("to_state", "")
	if not ctx.graph.has_node(ctx.from) or not ctx.graph.has_node(ctx.to) or ctx.from == "End" or ctx.to == "Start" or ctx.from == ctx.to:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid transition %s -> %s" % [ctx.from, ctx.to])
	ctx.index = -1
	for i in ctx.graph.get_transition_count():
		if ctx.graph.get_transition_from(i) == ctx.from and ctx.graph.get_transition_to(i) == ctx.to:
			ctx.index = i
	return ctx


func tree_transition_add(params: Dictionary) -> Dictionary:
	var ctx := _transition_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index >= 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Transition already exists")
	var transition := AnimationNodeStateMachineTransition.new()
	var error: Variant = _properties(transition, params.get("properties", {}))
	if error != null:
		return error
	var before := _begin(ctx, "Add animation state transition")
	_undo_redo.add_do_method(self, "_add_transition", ctx.graph, ctx.from, ctx.to, transition)
	_undo_redo.add_undo_method(self, "_remove_transition", ctx.graph, ctx.from, ctx.to)
	return _commit(ctx, before)


func tree_transition_remove(params: Dictionary) -> Dictionary:
	var ctx := _transition_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index < 0:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Transition does not exist")
	var before := _begin(ctx, "Remove animation state transition")
	_undo_redo.add_do_method(self, "_remove_transition", ctx.graph, ctx.from, ctx.to)
	_undo_redo.add_undo_method(self, "_restore_transitions", ctx.graph, _transitions(ctx.graph))
	return _commit(ctx, before)


func tree_transition_set(params: Dictionary) -> Dictionary:
	var ctx := _transition_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index < 0:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Transition does not exist")
	var transition: AnimationNodeStateMachineTransition = ctx.graph.get_transition(ctx.index)
	var resource_error := _resource_write_error(transition)
	if not resource_error.is_empty():
		return resource_error
	var updated := transition.duplicate(false) as AnimationNodeStateMachineTransition
	if updated == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not duplicate transition for validation")
	var properties: Variant = params.get("properties", {})
	var error: Variant = _properties(updated, properties)
	if error != null:
		return error
	if properties.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide properties")
	var before := _begin(ctx, "Set animation state transition")
	for key in properties:
		_undo_redo.force_fixed_history()
		_undo_redo.add_do_property(transition, key, updated.get(key))
		_undo_redo.force_fixed_history()
		_undo_redo.add_undo_property(transition, key, transition.get(key))
	return _commit(ctx, before)


func _blend_space_context(params: Dictionary) -> Dictionary:
	var ctx := _resolve(params)
	if ctx.has("error"):
		return ctx
	if not ctx.graph is AnimationNodeBlendSpace1D and not ctx.graph is AnimationNodeBlendSpace2D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "graph_path must select a 1D or 2D blend space")
	ctx.name = params.get("name", "")
	var error := _name_error(ctx.name)
	if not error.is_empty():
		return error
	if String(ctx.name).contains("."):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Blend point names must not contain '.'")
	ctx.index = ctx.graph.find_blend_point_by_name(ctx.name)
	return ctx


func _point_position(graph: AnimationNode, value: Variant) -> Variant:
	if graph is AnimationNodeBlendSpace2D:
		return _position(value)
	if not (value is int or value is float) or not is_finite(float(value)) or not is_finite(PackedFloat32Array([float(value)])[0]):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "1D blend position must be a finite native float")
	return float(value)


func _triangles(graph: AnimationNodeBlendSpace2D) -> Array:
	var packed: PackedInt32Array = graph.get("triangles")
	var triangles := []
	for index in range(0, packed.size(), 3):
		triangles.append([packed[index], packed[index + 1], packed[index + 2]])
	return triangles


func _restore_triangles(graph: AnimationNodeBlendSpace2D, triangles: Array) -> void:
	if graph.auto_triangles:
		return
	while graph.get_triangle_count() > 0:
		graph.remove_triangle(0)
	for triangle in triangles:
		graph.add_triangle(triangle[0], triangle[1], triangle[2])


func _remove_point(graph: AnimationNode, index: int) -> void:
	graph.remove_blend_point(index)
	if graph is AnimationNodeBlendSpace2D and graph.auto_triangles and graph.get_blend_point_count() > 0:
		# Native removal drops incident triangles but does not queue retriangulation.
		graph.set_blend_point_position(0, graph.get_blend_point_position(0))


func tree_point_add(params: Dictionary) -> Dictionary:
	var ctx := _blend_space_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index >= 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Blend point already exists: %s" % ctx.name)
	var count: int = ctx.graph.get_blend_point_count()
	if count >= MAX_BLEND_POINTS:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Godot blend spaces support at most %d points" % MAX_BLEND_POINTS)
	var at: Variant = params.get("at_index", -1)
	if not (at is int or at is float) or not is_finite(float(at)) or float(at) != floor(float(at)) or at < -1 or at > count:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "at_index must be -1 or an integer between 0 and %d" % count)
	var index := count if at == -1 else int(at)
	var position: Variant = _point_position(ctx.graph, params.get("position"))
	if position is Dictionary:
		return position
	var node: Variant = _new_node(params, true)
	if node is Dictionary:
		return node
	var before := _begin(ctx, "Add animation blend point %s" % ctx.name)
	_undo_redo.add_do_method(ctx.graph, "add_blend_point", node, position, index, ctx.name)
	_undo_redo.add_undo_method(self, "_remove_point", ctx.graph, index)
	return _commit(ctx, before)


func tree_point_remove(params: Dictionary) -> Dictionary:
	var ctx := _blend_space_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index < 0:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Blend point not found: %s" % ctx.name)
	var before := _begin(ctx, "Remove animation blend point %s" % ctx.name)
	_undo_redo.add_do_method(self, "_remove_point", ctx.graph, ctx.index)
	_undo_redo.add_undo_method(ctx.graph, "add_blend_point", ctx.graph.get_blend_point_node(ctx.index), ctx.graph.get_blend_point_position(ctx.index), ctx.index, ctx.name)
	if ctx.graph is AnimationNodeBlendSpace2D:
		_undo_redo.add_undo_method(self, "_restore_triangles", ctx.graph, _triangles(ctx.graph))
	return _commit(ctx, before)


func tree_point_set(params: Dictionary) -> Dictionary:
	var ctx := _blend_space_context(params)
	if ctx.has("error"):
		return ctx
	if ctx.index < 0:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Blend point not found: %s" % ctx.name)
	var position: Variant = _point_position(ctx.graph, params.get("position"))
	if position is Dictionary:
		return position
	var before := _begin(ctx, "Move animation blend point %s" % ctx.name)
	_undo_redo.add_do_method(ctx.graph, "set_blend_point_position", ctx.index, position)
	_undo_redo.add_undo_method(ctx.graph, "set_blend_point_position", ctx.index, ctx.graph.get_blend_point_position(ctx.index))
	return _commit(ctx, before)
