@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ResourceInspector := preload("res://addons/godot_ai/utils/resource_inspector.gd")
const ClassIntrospection := preload("res://addons/godot_ai/utils/class_introspection.gd")

## Handles resource search, inspection, and assignment to nodes.

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


func search_resources(params: Dictionary) -> Dictionary:
	var type_filter: String = params.get("type", "")
	var path_filter: String = params.get("path", "")

	if type_filter.is_empty() and path_filter.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "At least one filter (type, path) is required")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

	var results: Array[Dictionary] = []
	_scan_resources(efs.get_filesystem(), type_filter, path_filter, results)
	return {"data": {"resources": results, "count": results.size()}}


func _scan_resources(dir: EditorFileSystemDirectory, type_filter: String, path_filter: String, out: Array[Dictionary]) -> void:
	for i in dir.get_file_count():
		var file_path := dir.get_file_path(i)
		var file_type := dir.get_file_type(i)

		var matches := true

		if not type_filter.is_empty():
			# Check if the file type matches or is a subclass of the requested type
			if file_type != type_filter and not ClassDB.is_parent_class(file_type, type_filter):
				matches = false

		if matches and not path_filter.is_empty():
			if file_path.to_lower().find(path_filter.to_lower()) == -1:
				matches = false

		if matches:
			out.append({
				"path": file_path,
				"type": file_type,
			})

	for i in dir.get_subdir_count():
		_scan_resources(dir.get_subdir(i), type_filter, path_filter, out)


func load_resource(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")

	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var path_err = McpPathValidator.loadable_error(path, "path")
	if path_err != null:
		return path_err

	if not ResourceLoader.exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % path)

	var res: Resource = load(path)
	if res == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load resource: %s" % path)

	var properties: Array[Dictionary] = []
	for prop in res.get_property_list():
		var usage: int = prop.get("usage", 0)
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var value = res.get(prop.name)
		if value == null and prop.type != TYPE_NIL:
			continue
		properties.append({
			"name": prop.name,
			"type": type_string(prop.type),
			"value": NodeHandler._serialize_value(value),
		})

	return {
		"data": {
			"path": path,
			"type": res.get_class(),
			"properties": properties,
			"property_count": properties.size(),
		}
	}


func assign_resource(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")

	if node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	if property.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: property")

	if resource_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: resource_path")

	var rpath_err = McpPathValidator.loadable_error(resource_path, "resource_path")
	if rpath_err != null:
		return rpath_err

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path", "", true)
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var _scene_root: Node = _resolved.scene_root

	# Verify property exists
	var found := false
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			break
	if not found:
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS, McpPropertyErrors.build_message(node, property))

	if not ResourceLoader.exists(resource_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource not found: %s" % resource_path)

	var res: Resource = load(resource_path)
	if res == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load resource: %s" % resource_path)

	var old_value = node.get(property)

	_undo_redo.create_action("MCP: Assign %s to %s.%s" % [resource_path.get_file(), node.name, property])
	_undo_redo.add_do_property(node, property, res)
	_undo_redo.add_undo_property(node, property, old_value)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"property": property,
			"resource_path": resource_path,
			"resource_type": res.get_class(),
			"undoable": true,
		}
	}


## Instantiate a built-in Resource subclass, optionally apply `properties`,
## and either assign it to a node slot (undoable) or save it to a .tres file
## (not undoable — mirrors material_create). Exactly one home is required;
## a resource with no home would be GC'd after the handler returns.
func create_resource(params: Dictionary) -> Dictionary:
	var type_str: String = params.get("type", "")
	if type_str.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: type")

	var properties: Dictionary = params.get("properties", {})
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")
	var overwrite: bool = params.get("overwrite", false)

	var home_err := McpResourceIO.validate_home(params)
	if home_err != null:
		return home_err
	var has_file_target := not resource_path.is_empty()

	var made := _instantiate_resource(type_str)
	if made is Dictionary:
		return made
	var res: Resource = made

	if not properties.is_empty():
		var apply_err := _apply_resource_properties(res, properties)
		if apply_err != null:
			return apply_err

	if has_file_target:
		return _save_created_resource(res, type_str, resource_path, overwrite, properties.size())
	return _assign_created_resource(res, type_str, node_path, property, properties.size())


func create_sprite_frames(params: Dictionary) -> Dictionary:
	var builder := preload("res://addons/godot_ai/utils/resource_builders.gd")
	var path: String = params.get("resource_path", "")
	var overwrite: bool = params.get("overwrite", false)
	var error: Variant = builder.output_error(path, overwrite)
	if error != null:
		return error
	var built := builder.sprite_frames(params.get("animations", []))
	if built.has("error"):
		return built
	return McpResourceIO.save_to_disk(built.resource, path, overwrite, "SpriteFrames", {
		"animation_count": built.animation_count, "frame_count": built.frame_count,
	}, _connection, true, true)


## Persist a patch to an existing native resource while retaining its cached identity.
## Staging owns its containers but retains nested Resource references. Nested
## resources are replaced only when explicitly supplied as property values.
func set_resource_properties(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")
	var path_error: Variant = McpPathValidator.path_error(path, "path", true)
	if path_error != null:
		return path_error
	path = path.simplify_path()
	if path.contains("::") or path.get_extension() not in ["tres", "res"] or FileAccess.file_exists(path + ".import"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "set_properties requires an existing, non-imported res:// .tres or .res file: %s" % path)
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Resource file not found: %s" % path)
	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide at least one property in properties")
	for key in properties:
		if key in ["script", "resource_path"]:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "set_properties cannot change %s" % key)
	var input_error: Variant = _edit_constructor_error(properties)
	if input_error != null:
		return input_error
	var original := ResourceLoader.load(path)
	if original == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load resource: %s" % path)
	var original_resources := {}
	var graph_error: Variant = _edit_graph_error(original, original_resources)
	if graph_error != null:
		return graph_error
	var stage := original.duplicate_deep(Resource.DEEP_DUPLICATE_NONE)
	if stage == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource cannot be duplicated for validation: %s" % path)
	var staged_resources := {}
	graph_error = _edit_graph_error(stage, staged_resources)
	if graph_error != null:
		return graph_error
	for id in staged_resources:
		if id != stage.get_instance_id() and not original_resources.has(id):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "This resource forces nested duplication; set_properties cannot preserve its omitted nested resource identities")
	var apply_error: Variant = _apply_resource_properties(stage, properties, 0, true)
	if apply_error != null:
		return apply_error
	graph_error = _edit_graph_error(stage, {})
	if graph_error != null:
		return graph_error
	return McpResourceIO.save_to_disk(stage, path, true, "Resource", {
		"path": path,
		"properties_applied": properties.size(),
		"live_refreshed": true,
		"reason": "Resource file edits are persistent and are not part of scene undo",
	}, _connection, true, true)


static func _edit_constructor_error(value: Variant, depth: int = 0) -> Variant:
	if depth > MAX_NESTED_RESOURCE_DEPTH:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Resource edit input exceeds the supported nesting depth")
	if value is Dictionary:
		if value.has("__class__"):
			var type_name := str(value["__class__"])
			if ClassDB.class_exists(type_name) and ClassDB.is_parent_class(type_name, "Resource"):
				var class_error: Variant = _edit_class_error(type_name)
				if class_error != null:
					return class_error
				if value.has("script") or value.has("resource_path"):
					return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Resource edit constructors cannot set script or resource_path")
			else:
				for entry in ProjectSettings.get_global_class_list():
					if entry.get("class", "") == type_name:
						return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "set_properties only supports engine built-in resources without custom scripts")
		for item in value.values():
			var error: Variant = _edit_constructor_error(item, depth + 1)
			if error != null:
				return error
	elif value is Array:
		for item in value:
			var error: Variant = _edit_constructor_error(item, depth + 1)
			if error != null:
				return error
	return null


static func _edit_class_error(type_name: String) -> Variant:
	if ClassDB.class_get_api_type(type_name) not in [ClassDB.API_CORE, ClassDB.API_EDITOR]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "set_properties only supports engine built-in resources; GDExtension resources are not supported")
	return null


## Repeated Resource references are visited once; active recursion is refused. Container recursion is bounded,
## so cyclic metadata is refused before duplicate_deep can recurse into it.
static func _edit_graph_error(value: Variant, resources: Dictionary, depth: int = 0) -> Variant:
	if depth > MAX_NESTED_RESOURCE_DEPTH or resources.size() > 1024:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Resource edit graph is too deep, cyclic through containers, or exceeds 1024 resources")
	if value is Resource:
		if resources.has(value.get_instance_id()):
			if not resources[value.get_instance_id()]:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "set_properties does not support cyclic resource graphs")
			return null
		if value is Script or value.get_script() != null:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "set_properties only supports engine built-in resources without custom scripts, including nested resources")
		var class_error: Variant = _edit_class_error(value.get_class())
		if class_error != null:
			return class_error
		resources[value.get_instance_id()] = false
		for property in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE:
				var error: Variant = _edit_graph_error(value.get(property.name), resources, depth + 1)
				if error != null:
					return error
		resources[value.get_instance_id()] = true
	elif value is Array:
		for item in value:
			var error: Variant = _edit_graph_error(item, resources, depth + 1)
			if error != null:
				return error
	elif value is Dictionary:
		for key in value:
			for item in [key, value[key]]:
				var error: Variant = _edit_graph_error(item, resources, depth + 1)
				if error != null:
					return error
	return null


## Validate that `type_str` names a concrete Resource subclass that we can
## instantiate. Returns an error dict on failure, or null on success.
static func _validate_resource_class(type_str: String) -> Variant:
	if not ClassDB.class_exists(type_str):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown resource type: %s" % type_str)
	if ClassDB.is_parent_class(type_str, "Node"):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s is a Node type, not a Resource — use node_create instead" % type_str
		)
	if not ClassDB.is_parent_class(type_str, "Resource"):
		var parent := ClassDB.get_parent_class(type_str)
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s is not a Resource type (extends %s)" % [type_str, parent]
		)
	if not ClassDB.can_instantiate(type_str):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s is abstract and cannot be instantiated — use a concrete subclass (e.g. BoxMesh, BoxShape3D, StyleBoxFlat)" % type_str
		)
	return null


## Build the "Unknown resource type" error with a steer toward op="scan". A type
## that reaches here is neither an engine built-in (ClassDB) nor a registered
## project class (the global script-class registry). In an agent-driven workflow
## the most common cause is a `class_name` script just made via script_create
## that isn't registered yet — the global class table only rebuilds on a
## filesystem scan (normally an editor-focus event). Point the caller at the one
## cheap call that fixes that, so it doesn't fall back to a full plugin reload.
## See #614 for the headless scan op.
static func _unknown_resource_type_error(type_str: String) -> Dictionary:
	return ErrorCodes.make(
		ErrorCodes.VALUE_OUT_OF_RANGE,
		(
			"Unknown resource type: %s — not an engine built-in or a registered project class. "
			+ "If you just created it with script_create, the global class table is stale until a "
			+ "scan: call filesystem_manage(op=\"scan\"), then retry. Otherwise check the spelling."
		) % type_str
	)


## Resolve a resource type name to a fresh instance. Handles engine built-ins
## (ClassDB) and project `class_name` Resources (the global script-class
## registry). Returns a Resource on success, or an error dict on failure.
static func _instantiate_resource(type_str: String) -> Variant:
	if ClassDB.class_exists(type_str):
		var class_err: Variant = _validate_resource_class(type_str)
		if class_err != null:
			return class_err
		var built_in := ClassDB.instantiate(type_str)
		if built_in == null or not (built_in is Resource):
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s as a Resource" % type_str)
		return built_in
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == type_str:
			var script_path: String = entry.get("path", "")
			var scr: Variant = load(script_path)
			# Reject non-Resource script classes BEFORE constructing them:
			# scr.new() runs _init(), and an @tool class_name extending a
			# non-RefCounted type (e.g. Node) would otherwise build — and leak —
			# an orphan instance this path never frees. get_instance_base_type()
			# resolves to the native base, so multi-level custom Resource
			# hierarchies (B extends A extends Resource) still pass.
			var base_or_err: Variant = _script_base_type_or_error(scr, type_str, script_path)
			if base_or_err is Dictionary:
				return base_or_err
			var base_type: StringName = base_or_err
			if not ClassDB.is_parent_class(base_type, "Resource"):
				return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s is not a Resource type (extends %s)" % [type_str, base_type])
			if not scr.can_instantiate():
				return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s cannot be instantiated in the editor (abstract, or a non-@tool script — add @tool to instantiate it here)" % type_str)
			# Reject scripts whose _init() requires arguments BEFORE scr.new():
			# scr.new() passes no args, so a required-arg _init raises and aborts
			# this handler mid-call, null-cascading into a generic "malformed
			# result" error instead of a clean rejection. get_script_method_list()
			# reports the effective (incl. inherited) _init; required args =
			# args - default_args. Statically detectable only — a _init that runs
			# but throws still falls through to scr.new() and the dispatcher catch.
			for method in scr.get_script_method_list():
				if method.get("name", "") == "_init":
					var required_args: int = (method.get("args", []) as Array).size() - (method.get("default_args", []) as Array).size()
					if required_args > 0:
						return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s cannot be instantiated: its _init() requires arguments" % type_str)
					break
			var made: Variant = scr.new()
			if made == null or not (made is Resource):
				return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s as a Resource" % type_str)
			return made
	return _unknown_resource_type_error(type_str)


## Maximum nesting depth for the {"__class__": ...} sub-resource shortcut.
## Caller-supplied dicts recurse through _apply_resource_properties; without a
## cap a deeply nested payload overflows the GDScript call stack and crashes
## the editor (#536). 32 is far beyond any legitimate sub-resource chain.
const MAX_NESTED_RESOURCE_DEPTH := 32


## Apply a dict of property values to a freshly-instantiated Resource,
## reusing NodeHandler's coercion so Vector3/Color/etc. dicts land typed.
## Returns null on success or an error dict on failure.
## `depth` is internal recursion bookkeeping for the nested {"__class__": ...}
## shortcut — external callers use the default of 0.
static func _apply_resource_properties(res: Resource, properties: Dictionary, depth: int = 0, verify_setters: bool = false) -> Variant:
	if depth > MAX_NESTED_RESOURCE_DEPTH:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Nested resource properties exceed the maximum depth of %d — flatten the {\"__class__\": ...} nesting or create the deep sub-resources in separate calls" % MAX_NESTED_RESOURCE_DEPTH
		)
	var pending := properties.keys()
	while not pending.is_empty():
		# Counts and modes can expose dependent fields regardless of JSON key order.
		var prop_types := {}
		for prop in res.get_property_list():
			prop_types[prop.name] = prop.get("type", TYPE_NIL)
		var key: Variant = pending[0]
		for candidate in pending:
			if prop_types.has(candidate):
				key = candidate
				break
		if not prop_types.has(key):
			return _missing_resource_property(res, key)
		pending.erase(key)
		var target_type: int = prop_types[key]
		if target_type == TYPE_NIL:
			target_type = typeof(res.get(key))
		var v = properties[key]
		if target_type == TYPE_OBJECT and v is String:
			if v == "":
				v = null
			else:
				var vpath_err = McpPathValidator.loadable_error(v, "property '%s'" % key)
				if vpath_err != null:
					return vpath_err
				var loaded := ResourceLoader.load(v)
				if loaded == null:
					return ErrorCodes.make(
						ErrorCodes.RESOURCE_NOT_FOUND,
						"Resource not found at path '%s' for property '%s'" % [v, key]
					)
				v = loaded
		elif target_type == TYPE_OBJECT and v is Dictionary and v.has("__class__"):
			# Nested shortcut: the same {"__class__": "X", ...} form that
			# node_handler.set_property accepts, now also supported here so
			# resource_create/environment_create callers can populate
			# sub-resource slots (ShaderMaterial.shader, etc.) in one shot.
			var sub_type: String = v.get("__class__", "")
			# Resolve via the shared helper so the nested shortcut accepts both
			# engine built-ins (ClassDB) and project `class_name` Resources,
			# exactly like the top-level resource_create path.
			var sub_made := _instantiate_resource(sub_type)
			if sub_made is Dictionary:
				# Preserve the property-slot context the inline path used to add.
				sub_made["error"]["message"] = "%s (for property '%s')" % [sub_made["error"]["message"], key]
				return sub_made
			var sub_res: Resource = sub_made
			var remaining: Dictionary = (v as Dictionary).duplicate()
			remaining.erase("__class__")
			if not remaining.is_empty():
				var nested_err := _apply_resource_properties(sub_res, remaining, depth + 1, verify_setters)
				if nested_err != null:
					return nested_err
			v = sub_res
		else:
			var slot_value: Variant = res.get(key)
			if target_type == TYPE_ARRAY and slot_value is Array and (slot_value as Array).is_typed():
				## Typed Array[T] slot (#612): mirror set_property's dispatch —
				## the generic passthrough would hand an untyped Array to the
				## typed setter, which drops it silently while we report success.
				var typed_out: Variant = NodeHandler._coerce_typed_array(
					v, slot_value, "Property '%s'" % key, null, null, "", depth + 1,
				)
				if typed_out is Dictionary:
					return typed_out
				v = typed_out
			elif (
				target_type == TYPE_DICTIONARY
				and slot_value is Dictionary
				and (slot_value as Dictionary).is_typed()
			):
				## Typed Dictionary[K, V] slot (#612 stage 3): success is a
				## typed duplicate of the slot; the error envelope is untyped.
				var typed_dict_out: Dictionary = NodeHandler._coerce_typed_dictionary(
					v, slot_value, "Property '%s'" % key, depth + 1,
				)
				if not typed_dict_out.is_typed():
					return typed_dict_out
				v = typed_dict_out
			else:
				v = NodeHandler._coerce_value(v, target_type)
				## Mirror set_property's coerce check: wrong-shape dicts (#123) and
				## non-dict inputs that don't land as the target compound Variant
				## (#191) both error here instead of writing zero-filled Variants.
				var coerce_err := NodeHandler._check_coerced(v, target_type, "Property '%s'" % key)
				if coerce_err != null:
					return coerce_err
		var constructors: Array[Dictionary] = []
		if v is Array or v is Dictionary:
			constructors = _nested_constructor_paths(v, str(key))
		res.set(key, v)
		var readback: Variant = res.get(key) if verify_setters else v
		var matches: bool = is_equal_approx(readback, v) if readback is float and v is float else readback == v
		if verify_setters and not matches:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Property '%s' rejected or normalized the requested value; original resource was not changed" % key)
		if not constructors.is_empty():
			var readback_err: Variant = _nested_constructor_readback_error(constructors, res.get(key))
			if readback_err != null:
				return readback_err
	var final_properties := {}
	for prop in res.get_property_list():
		final_properties[prop.name] = true
	for key in properties:
		if not final_properties.has(key):
			return _missing_resource_property(res, key)
	return null


static func _missing_resource_property(res: Resource, key: Variant) -> Dictionary:
	var valid: Array[String] = []
	for prop in res.get_property_list():
		if prop.get("usage", 0) & PROPERTY_USAGE_EDITOR:
			valid.append(prop.name)
	valid.sort()
	# Name the script's class_name (e.g. MyTestResource) rather than the
	# native base (Resource) so the hint names the type the agent created,
	# and point at the real MCP verb — resource_manage(op="get_info") now
	# answers for project class_name Resources too.
	var type_label := res.get_class()
	var res_script: Variant = res.get_script()
	if res_script is Script and not String(res_script.get_global_name()).is_empty():
		type_label = String(res_script.get_global_name())
	var err := ErrorCodes.make(
		ErrorCodes.PROPERTY_NOT_ON_CLASS,
		"Property '%s' not found on %s. Call resource_manage(op=\"get_info\", params={\"type\": \"%s\"}) to list available properties." % [key, type_label, type_label]
	)
	err["error"]["data"] = {"valid_properties": valid}
	return err


## Capture paths and independent data before a setter can mutate containers. The
## iterative walk does not add recursive calls for arbitrary dictionary data.
static func _nested_constructor_paths(value: Variant, path: String) -> Array[Dictionary]:
	var constructors: Array[Dictionary] = []
	var pending: Array[Dictionary] = [{"value": value, "keys": [], "path": path}]
	while not pending.is_empty():
		var item: Dictionary = pending.pop_back()
		var supplied: Variant = item.value
		if supplied is Dictionary:
			if supplied.has("__class__"):
				constructors.append({
					"keys": item.keys, "path": item.path, "value": supplied.duplicate(true),
				})
			for key in supplied:
				pending.append({
					"value": supplied[key], "keys": item.keys + [key],
					"path": "%s.%s" % [item.path, key],
				})
		elif supplied is Array:
			for i in range(supplied.size() - 1, -1, -1):
				pending.append({
					"value": supplied[i], "keys": item.keys + [i],
					"path": "%s[%d]" % [item.path, i],
				})
	return constructors


## Untyped native setters can silently replace constructor dictionaries with
## null. Refuse that loss before saving or assigning the new resource. A
## dictionary that retains the supplied constructor as ordinary data stays a dictionary.
static func _nested_constructor_readback_error(constructors: Array[Dictionary], stored: Variant) -> Variant:
	for constructor in constructors:
		var actual: Variant = stored
		for key in constructor.keys:
			if actual is Resource:
				break
			if actual is Dictionary:
				actual = actual.get(key)
			elif actual is Array and key is int and key >= 0 and key < actual.size():
				actual = actual[key]
			else:
				actual = null
				break
		if not _constructor_content_retained(constructor.value, actual):
			return ErrorCodes.make(
				ErrorCodes.WRONG_TYPE,
				"Nested resource constructor at '%s' was not retained. This untyped collection does not support inline resources; use a typed Resource property or construct the resource with Godot's API." % constructor.path,
			)
	return null


static func _constructor_content_retained(supplied: Dictionary, stored: Variant) -> bool:
	var pending: Array[Dictionary] = [{"supplied": supplied, "stored": stored}]
	while not pending.is_empty():
		var item: Dictionary = pending.pop_back()
		var expected: Variant = item.supplied
		var actual: Variant = item.stored
		if expected is Dictionary:
			if actual is Resource and expected.has("__class__"):
				continue
			if not (actual is Dictionary):
				return false
			for key in expected:
				if not actual.has(key):
					return false
				pending.append({"supplied": expected[key], "stored": actual[key]})
		elif expected is Array:
			if not (actual is Array) or actual.size() < expected.size():
				return false
			for i in expected.size():
				pending.append({"supplied": expected[i], "stored": actual[i]})
		else:
			var both_numeric := typeof(expected) in [TYPE_INT, TYPE_FLOAT] and typeof(actual) in [TYPE_INT, TYPE_FLOAT]
			if typeof(expected) != typeof(actual) and not both_numeric:
				return false
			if expected != actual:
				return false
	return true


func _assign_created_resource(res: Resource, type_str: String, node_path: String, property: String, applied_count: int) -> Dictionary:
	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path", "", true)
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var _scene_root: Node = _resolved.scene_root

	var found := false
	var prop_type: int = TYPE_NIL
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not found:
		return ErrorCodes.make(
			ErrorCodes.PROPERTY_NOT_ON_CLASS,
			McpPropertyErrors.build_message(node, property)
		)
	if prop_type != TYPE_NIL and prop_type != TYPE_OBJECT:
		return ErrorCodes.make(
			ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Property '%s' on %s is not an Object slot (type %s)" % [property, node.get_class(), type_string(prop_type)]
		)

	var old_value = node.get(property)

	_undo_redo.create_action("MCP: Create %s for %s.%s" % [type_str, node.name, property])
	_undo_redo.add_do_property(node, property, res)
	_undo_redo.add_undo_property(node, property, old_value)
	_undo_redo.add_do_reference(res)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"property": property,
			"type": type_str,
			"resource_class": res.get_class(),
			"properties_applied": applied_count,
			"undoable": true,
		}
	}


func _save_created_resource(res: Resource, type_str: String, resource_path: String, overwrite: bool, applied_count: int) -> Dictionary:
	return McpResourceIO.save_to_disk(res, resource_path, overwrite, "Resource", {
		"type": type_str,
		"resource_class": res.get_class(),
		"properties_applied": applied_count,
	}, _connection, true)


## Introspect a Resource class — return its editor-visible properties, parent,
## whether it's abstract, and (for abstract bases) the list of concrete
## subclasses that resource_create can instantiate. Read-only.
func get_resource_info(params: Dictionary) -> Dictionary:
	var type_str: String = params.get("type", "")
	if type_str.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: type")

	if not ClassDB.class_exists(type_str):
		# Project class_name Resources aren't in ClassDB; resolve them through the
		# global script-class registry so get_info answers for the same custom
		# types resource_create can make. Read-only — never instantiates.
		var custom_info: Variant = _custom_resource_info(type_str)
		if custom_info != null:
			return custom_info
		return _unknown_resource_type_error(type_str)
	if ClassDB.is_parent_class(type_str, "Node"):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s is a Node type, not a Resource — use node_* tools for node introspection" % type_str
		)
	if not ClassDB.is_parent_class(type_str, "Resource") and type_str != "Resource":
		var parent := ClassDB.get_parent_class(type_str)
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"%s is not a Resource type (extends %s)" % [type_str, parent]
		)

	var can_instantiate: bool = ClassDB.can_instantiate(type_str)
	var class_info := ClassIntrospection.build(type_str, {
		"sections": ["properties"],
		"include_inherited": true,
		"include_inheritors": not can_instantiate,
		"limit": 0,
	})
	var data: Dictionary = {
		"type": type_str,
		"parent_class": class_info.parent_class,
		"can_instantiate": can_instantiate,
		"is_abstract": not can_instantiate,
		"properties": class_info.properties,
		"property_count": class_info.property_count,
	}

	# For abstract bases (Shape3D, Material, Texture, StyleBox, ...) surface
	# the concrete Resource subclasses an agent could try next.
	if not can_instantiate:
		data["concrete_subclasses"] = class_info.concrete_inheritors

	return {"data": data}


## Resolve a loaded global-class script to its native base type, or an error if
## the script failed to load (not a Script) or to compile (empty base type).
## Shared by the create and get_info custom-Resource paths so both report a
## compile failure rather than a misleading "is not a Resource type (extends )".
static func _script_base_type_or_error(scr: Variant, type_str: String, script_path: String) -> Variant:
	if not (scr is Script):
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load script class %s from %s" % [type_str, script_path])
	var base_type: StringName = scr.get_instance_base_type()
	if String(base_type).is_empty():
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "%s failed to compile or parse (script %s)" % [type_str, script_path])
	return base_type


## get_info for a project `class_name` Resource (not in ClassDB). Returns an info
## dict, an error dict (for a class_name whose native base is not a Resource), or
## null if `type_str` is not a registered global class. Read-only: resolves
## properties from the script + its native base WITHOUT instantiating (no _init()).
static func _custom_resource_info(type_str: String) -> Variant:
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class", "") != type_str:
			continue
		var script_path: String = entry.get("path", "")
		var scr: Variant = load(script_path)
		var base_or_err: Variant = _script_base_type_or_error(scr, type_str, script_path)
		if base_or_err is Dictionary:
			return base_or_err
		var base_type: StringName = base_or_err
		if not ClassDB.is_parent_class(base_type, "Resource"):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s is not a Resource type (extends %s)" % [type_str, base_type])
		var can_instantiate: bool = scr.can_instantiate()
		# Inherited (native) properties come from the engine base via ClassDB...
		var class_info := ClassIntrospection.build(String(base_type), {
			"sections": ["properties"],
			"include_inherited": true,
			"limit": 0,
		})
		var props: Array = []
		for native_prop in class_info.properties:
			props.append(native_prop)
		# ...and the script's own (and inherited script) exported properties come
		# from the Script itself, so we never construct the resource. A real
		# default isn't available without instantiating, so script props carry an
		# explicit null — keeping one uniform key set across the array (native
		# props carry their real default).
		for raw_prop in scr.get_script_property_list():
			var prop: Dictionary = raw_prop
			var usage := int(prop.get("usage", 0))
			if not (usage & PROPERTY_USAGE_EDITOR):
				continue
			props.append({
				"name": str(prop.get("name", "")),
				"type": type_string(int(prop.get("type", TYPE_NIL))),
				"class_name": str(prop.get("class_name", "")),
				"hint": int(prop.get("hint", PROPERTY_HINT_NONE)),
				"hint_string": str(prop.get("hint_string", "")),
				"usage": usage,
				"default": null,
			})
		props.sort_custom(func(a, b): return a.name < b.name)
		# parent_class is the immediate script parent when there is one (so a
		# multi-level chain B -> A -> Resource reports A), else the native base.
		var parent_name := String(base_type)
		var base_script: Variant = scr.get_base_script()
		if base_script is Script and not String(base_script.get_global_name()).is_empty():
			parent_name = String(base_script.get_global_name())
		return {"data": {
			"type": type_str,
			"parent_class": parent_name,
			"can_instantiate": can_instantiate,
			# is_abstract reflects real abstractness (the @abstract annotation),
			# NOT editor-instantiability — a non-@tool concrete Resource has
			# can_instantiate()==false in-editor but is not abstract.
			"is_abstract": scr.is_abstract(),
			"properties": props,
			"property_count": props.size(),
		}}
	return null


func inspect_resource(params: Dictionary) -> Dictionary:
	for name in ["node_path", "property"]:
		if not params.has(name):
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "inspect_resource requires %s" % name)
		if params[name] is not String:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a String" % name)
		if params[name].is_empty():
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "inspect_resource requires %s" % name)
	var depth: Variant = params.get("depth", 2)
	if typeof(depth) not in [TYPE_INT, TYPE_FLOAT]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "depth must be an integer from 0 through 3")
	if not is_finite(float(depth)) or float(depth) != floor(float(depth)) or depth < 0 or depth > 3:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "depth must be an integer from 0 through 3; received %s" % str(depth))
	var resolved := McpNodeValidator.resolve_or_error(params.node_path, "node_path")
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var native_resource_property := false
	for property in ClassDB.class_get_property_list(node.get_class()):
		if str(property.name) == params.property and int(property.type) == TYPE_OBJECT and int(property.hint) == PROPERTY_HINT_RESOURCE_TYPE:
			native_resource_property = true
			break
	if not native_resource_property:
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS, "Property '%s' on %s is not a native Resource property; script and dynamic getters are not inspected" % [params.property, node.get_class()])
	var resource: Variant = ClassDB.class_get_property(node, params.property)
	if resource is not Resource:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Property '%s' on '%s' does not contain a Resource; assign one before inspecting" % [params.property, params.node_path])
	if not ResourceInspector.supported(resource):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource '%s' is scripted or outside the supported native shape, mesh, material, physics material, stylebox, gradient and curve families" % resource.get_class())
	return ResourceInspector.new().inspect(resource, int(depth))
