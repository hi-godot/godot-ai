@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles autoload listing, adding, and removing via ProjectSettings.


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
	if not path.begins_with("res://"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Path must start with res:// (got: %s)" % path)
	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found: %s" % path)

	var key := "autoload/%s" % name
	if ProjectSettings.has_setting(key):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Autoload '%s' already exists" % name)

	var value := ("*" if singleton else "") + path
	ProjectSettings.set_setting(key, value)
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.set_as_basic(key, true)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.clear(key)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while adding autoload '%s': %s (error %d)" % [name, error_string(err), err])

	return {
		"data": {
			"name": name,
			"path": path,
			"singleton": singleton,
			"undoable": false,
			"reason": "Autoload changes are saved to project.godot",
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
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.set_setting(key, old_value)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while removing autoload '%s': %s (error %d)" % [name, error_string(err), err])

	return {
		"data": {
			"name": name,
			"removed": true,
			"undoable": false,
			"reason": "Autoload changes are saved to project.godot",
		}
	}
