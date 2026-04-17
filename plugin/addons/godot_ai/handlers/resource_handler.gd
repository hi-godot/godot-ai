@tool
class_name ResourceHandler
extends RefCounted

## Handles resource search, inspection, and assignment to nodes.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func search_resources(params: Dictionary) -> Dictionary:
	var type_filter: String = params.get("type", "")
	var path_filter: String = params.get("path", "")

	if type_filter.is_empty() and path_filter.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "At least one filter (type, path) is required")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "EditorFileSystem not available")

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	if not ResourceLoader.exists(path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % path)

	var res: Resource = load(path)
	if res == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to load resource: %s" % path)

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if property.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: property")

	if resource_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: resource_path")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	# Verify property exists
	var found := false
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			break
	if not found:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Property '%s' not found on %s" % [property, node.get_class()])

	if not ResourceLoader.exists(resource_path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % resource_path)

	var res: Resource = load(resource_path)
	if res == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to load resource: %s" % resource_path)

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: type")

	var properties: Dictionary = params.get("properties", {})
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")
	var overwrite: bool = params.get("overwrite", false)

	var has_node_target := not node_path.is_empty()
	var has_file_target := not resource_path.is_empty()

	if has_node_target and has_file_target:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Provide either path+property (assign inline) or resource_path (save .tres), not both"
		)
	if not has_node_target and not has_file_target:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Must provide either path+property (assign inline) or resource_path (save .tres) — a dangling resource would be GC'd"
		)
	if has_node_target and property.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Missing required param: property (required when path is given)"
		)

	var class_err := _validate_resource_class(type_str)
	if class_err != null:
		return class_err

	var instance := ClassDB.instantiate(type_str)
	if instance == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % type_str)
	if not (instance is Resource):
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Instantiated %s but result is not a Resource (got %s)" % [type_str, instance.get_class()]
		)
	var res: Resource = instance

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown resource type: %s" % type_str)
	if ClassDB.is_parent_class(type_str, "Node"):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s is a Node type, not a Resource — use node_create instead" % type_str
		)
	if not ClassDB.is_parent_class(type_str, "Resource"):
		var parent := ClassDB.get_parent_class(type_str)
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s is not a Resource type (extends %s)" % [type_str, parent]
		)
	if not ClassDB.can_instantiate(type_str):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s is abstract and cannot be instantiated — use a concrete subclass (e.g. BoxMesh, BoxShape3D, StyleBoxFlat)" % type_str
		)
	return null


## Apply a dict of property values to a freshly-instantiated Resource,
## reusing NodeHandler's coercion so Vector3/Color/etc. dicts land typed.
## Returns null on success or an error dict on failure.
static func _apply_resource_properties(res: Resource, properties: Dictionary) -> Variant:
	var prop_types := {}
	for prop in res.get_property_list():
		prop_types[prop.name] = prop.get("type", TYPE_NIL)
	for key in properties.keys():
		if not prop_types.has(key):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not found on %s" % [key, res.get_class()]
			)
		var target_type: int = prop_types[key]
		if target_type == TYPE_NIL:
			target_type = typeof(res.get(key))
		var v = properties[key]
		if target_type == TYPE_OBJECT and v is String:
			if v == "":
				v = null
			else:
				var loaded := ResourceLoader.load(v)
				if loaded == null:
					return McpErrorCodes.make(
						McpErrorCodes.INVALID_PARAMS,
						"Resource not found at path '%s' for property '%s'" % [v, key]
					)
				v = loaded
		elif target_type == TYPE_OBJECT and v is Dictionary and v.has("__class__"):
			# Nested shortcut: the same {"__class__": "X", ...} form that
			# node_handler.set_property accepts, now also supported here so
			# resource_create/environment_create callers can populate
			# sub-resource slots (ShaderMaterial.shader, etc.) in one shot.
			var sub_type: String = v.get("__class__", "")
			var class_err := _validate_resource_class(sub_type)
			if class_err != null:
				return class_err
			var sub_instance := ClassDB.instantiate(sub_type)
			if sub_instance == null or not (sub_instance is Resource):
				return McpErrorCodes.make(
					McpErrorCodes.INTERNAL_ERROR,
					"Failed to instantiate %s as a Resource for property '%s'" % [sub_type, key]
				)
			var sub_res: Resource = sub_instance
			var remaining: Dictionary = (v as Dictionary).duplicate()
			remaining.erase("__class__")
			if not remaining.is_empty():
				var nested_err := _apply_resource_properties(sub_res, remaining)
				if nested_err != null:
					return nested_err
			v = sub_res
		else:
			v = NodeHandler._coerce_value(v, target_type)
		res.set(key, v)
	return null


func _assign_created_resource(res: Resource, type_str: String, node_path: String, property: String, applied_count: int) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	var found := false
	var prop_type: int = TYPE_NIL
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not found:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Property '%s' not found on %s" % [property, node.get_class()]
		)
	if prop_type != TYPE_NIL and prop_type != TYPE_OBJECT:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
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
	if not resource_path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "resource_path must start with res://")

	var existed_before := FileAccess.file_exists(resource_path)
	if existed_before and not overwrite:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Resource already exists at %s (pass overwrite=true to replace)" % resource_path
		)

	var dir_path := resource_path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to create directory %s: %s" % [dir_path, error_string(mkdir_err)]
		)

	var save_err := ResourceSaver.save(res, resource_path)
	if save_err != OK:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to save resource to %s: %s" % [resource_path, error_string(save_err)]
		)

	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(resource_path)

	return {
		"data": {
			"resource_path": resource_path,
			"type": type_str,
			"resource_class": res.get_class(),
			"properties_applied": applied_count,
			"overwritten": existed_before,
			"undoable": false,
			"reason": "File creation is persistent; delete the file manually to revert",
		}
	}
