@tool
class_name AutoloadHandler
extends RefCounted

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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")
	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res:// (got: %s)" % path)
	if not FileAccess.file_exists(path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "File not found: %s" % path)

	var key := "autoload/%s" % name
	if ProjectSettings.has_setting(key):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Autoload '%s' already exists" % name)

	var value := ("*" if singleton else "") + path
	ProjectSettings.set_setting(key, value)
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.set_as_basic(key, true)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.clear(key)
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")

	var key := "autoload/%s" % name
	if not ProjectSettings.has_setting(key):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Autoload '%s' not found" % name)

	var old_value: String = ProjectSettings.get_setting(key, "")
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.set_setting(key, old_value)
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while removing autoload '%s': %s (error %d)" % [name, error_string(err), err])

	return {
		"data": {
			"name": name,
			"removed": true,
			"undoable": false,
			"reason": "Autoload changes are saved to project.godot",
		}
	}
