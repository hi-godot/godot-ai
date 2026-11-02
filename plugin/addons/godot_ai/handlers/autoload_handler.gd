@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

var _editor_plugin: EditorPlugin


func _init(editor_plugin: EditorPlugin) -> void:
	_editor_plugin = editor_plugin


func list_autoloads(_params: Dictionary) -> Dictionary:
	var autoloads: Array[Dictionary] = []
	for prop in ProjectSettings.get_property_list():
		var key: String = prop.get("name", "")
		if not key.begins_with("autoload/"):
			continue
		var name := key.substr("autoload/".length())
		var raw_value: String = ProjectSettings.get_setting(key, "")
		var is_singleton := raw_value.begins_with("*")
		var path := raw_value.substr(1) if is_singleton else raw_value
		if path.begins_with("uid://"):
			var uid := ResourceUID.text_to_id(path)
			if ResourceUID.has_id(uid):
				path = ResourceUID.get_id_path(uid)
		autoloads.append({
			"name": name,
			"path": path,
			"singleton": is_singleton,
		})
	return {"data": {"autoloads": autoloads, "count": autoloads.size()}}


func add_autoload(params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	var path: String = params.get("path", "")
	var singleton: bool = params.get("singleton", true)

	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")
	if not name.is_valid_unicode_identifier() or ClassDB.class_exists(name):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Invalid autoload name: %s" % name)
	for variant_type in range(TYPE_MAX):
		if type_string(variant_type) == name:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Autoload name conflicts with a built-in type: %s" % name)
	for global_class in ProjectSettings.get_global_class_list():
		if str(global_class.get("class", "")) == name:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Autoload name conflicts with a script class: %s" % name)
	var path_err = McpPathValidator.path_error(path, "path")
	if path_err != null:
		return path_err
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found: %s" % path)

	var key := "autoload/%s" % name
	if ProjectSettings.has_setting(key):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Autoload '%s' already exists" % name)
	var resource := ResourceLoader.load(path)
	if resource is PackedScene and not resource.can_instantiate():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "PackedScene has no nodes to instantiate: %s" % path)
	if not (resource is PackedScene) and not (resource is Script and ClassDB.is_parent_class(resource.get_instance_base_type(), "Node")):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Autoload must be a Node script or scene: %s" % path)

	# Native scene autoload creation claims this cache path; release our validation reference first.
	resource = null
	var value := ("*" if singleton else "") + path
	ProjectSettings.set_setting(key, value)
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.set_as_basic(key, true)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.clear(key)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while adding autoload '%s': %s (error %d)" % [name, error_string(err), err])
	if singleton:
		# Save first so a disk failure cannot leave a registered global or an undo action.
		# Restore the old setting before the native API records its undo state.
		ProjectSettings.clear(key)
		_editor_plugin.add_autoload_singleton(name, path)
		if not ProjectSettings.has_setting(key):
			var rollback_err := ProjectSettings.save()
			if rollback_err != OK:
				return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
					"Godot refused autoload '%s', and reverting project settings failed: %s (error %d)" % [name, error_string(rollback_err), rollback_err])
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Godot refused autoload '%s' at %s" % [name, path])
		ProjectSettings.set_setting(key, value)

	return {
		"data": {
			"name": name,
			"path": path,
			"singleton": singleton,
			"undoable": singleton,
			"reason": "Uses Godot's autoload undo history" if singleton else "Non-singleton autoload changes are saved to project.godot",
		}
	}


func remove_autoload(params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")

	var key := "autoload/%s" % name
	if not ProjectSettings.has_setting(key):
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "Autoload '%s' not found" % name)

	var old_value: String = ProjectSettings.get_setting(key, "")
	var old_order := ProjectSettings.get_order(key)
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.set_setting(key, old_value)
		ProjectSettings.set_order(key, old_order)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while removing autoload '%s': %s (error %d)" % [name, error_string(err), err])
	ProjectSettings.set_setting(key, old_value)
	ProjectSettings.set_order(key, old_order)
	_editor_plugin.remove_autoload_singleton(name)

	return {
		"data": {
			"name": name,
			"removed": true,
			"undoable": true,
		}
	}
