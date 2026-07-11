@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
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

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
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
static func _apply_resource_properties(res: Resource, properties: Dictionary, depth: int = 0) -> Variant:
	if depth > MAX_NESTED_RESOURCE_DEPTH:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Nested resource properties exceed the maximum depth of %d — flatten the {\"__class__\": ...} nesting or create the deep sub-resources in separate calls" % MAX_NESTED_RESOURCE_DEPTH
		)
	var prop_types := {}
	for prop in res.get_property_list():
		prop_types[prop.name] = prop.get("type", TYPE_NIL)
	for key in properties.keys():
		if not prop_types.has(key):
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
						ErrorCodes.INVALID_PARAMS,
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
				var nested_err := _apply_resource_properties(sub_res, remaining, depth + 1)
				if nested_err != null:
					return nested_err
			v = sub_res
		else:
			v = NodeHandler._coerce_value(v, target_type)
			## Mirror set_property's coerce check: wrong-shape dicts (#123) and
			## non-dict inputs that don't land as the target compound Variant
			## (#191) both error here instead of writing zero-filled Variants.
			var coerce_err := NodeHandler._check_coerced(v, target_type, "Property '%s'" % key)
			if coerce_err != null:
				return coerce_err
		res.set(key, v)
	return null


func _assign_created_resource(res: Resource, type_str: String, node_path: String, property: String, applied_count: int) -> Dictionary:
	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
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
			"Property '%s' not found on %s" % [property, node.get_class()]
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
	}, _connection)


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
