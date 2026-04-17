@tool
class_name ProjectHandler
extends RefCounted

## Handles project settings and filesystem search commands.

var _connection: Connection


func _init(connection: Connection = null) -> void:
	_connection = connection


func get_project_setting(params: Dictionary) -> Dictionary:
	var key: String = params.get("key", "")
	if key.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: key")

	if not ProjectSettings.has_setting(key):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Setting not found: %s" % key)

	var value = ProjectSettings.get_setting(key)
	return {
		"data": {
			"key": key,
			"value": NodeHandler._serialize_value(value),
			"type": type_string(typeof(value)),
		}
	}


func set_project_setting(params: Dictionary) -> Dictionary:
	var key: String = params.get("key", "")
	if key.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: key")

	if not params.has("value"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: value")

	var value = params.get("value")
	var had_setting := ProjectSettings.has_setting(key)
	var old_value = ProjectSettings.get_setting(key) if had_setting else null
	# JSON has no distinct int type: Godot parses `1920` as float. If the
	# existing setting is TYPE_INT, coerce whole-number floats back to int so
	# we don't silently flip typed-int settings (viewport_width, etc.) to
	# floats on disk. See issue #31.
	if had_setting and typeof(old_value) == TYPE_INT and typeof(value) == TYPE_FLOAT and float(int(value)) == value:
		value = int(value)
	ProjectSettings.set_setting(key, value)
	var err := ProjectSettings.save()
	if err != OK:
		if had_setting:
			ProjectSettings.set_setting(key, old_value)
		else:
			ProjectSettings.clear(key)
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to save project settings (error %d)" % err)

	return {
		"data": {
			"key": key,
			"value": NodeHandler._serialize_value(value),
			"old_value": NodeHandler._serialize_value(old_value),
			"type": type_string(typeof(value)),
			"undoable": false,
			"reason": "ProjectSettings changes are saved to disk",
		}
	}


func run_project(params: Dictionary) -> Dictionary:
	var mode: String = params.get("mode", "main")
	if EditorInterface.is_playing_scene():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Project is already running")

	# play_*_scene internally triggers try_autosave() → _save_scene_with_preview()
	# which renders a preview thumbnail and calls frame processing. If our
	# WebSocket connection's _process() re-enters during that render, the
	# engine crashes (SIGABRT in _save_scene_with_preview). Pause processing
	# around the play call — same pattern as SceneHandler.save_scene.
	if _connection:
		_connection.pause_processing = true
	var validation_error: Variant = null
	match mode:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		"custom":
			var scene_path: String = params.get("scene", "")
			if scene_path.is_empty():
				validation_error = McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: scene (required when mode='custom')")
			else:
				EditorInterface.play_custom_scene(scene_path)
		_:
			validation_error = McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid mode '%s' — use 'main', 'current', or 'custom'" % mode)
	if _connection:
		_connection.pause_processing = false

	if validation_error != null:
		return validation_error

	return {
		"data": {
			"mode": mode,
			"scene": params.get("scene", ""),
			"undoable": false,
			"reason": "Play/stop is a runtime action",
		}
	}


func stop_project(_params: Dictionary) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Project is not running")

	EditorInterface.stop_playing_scene()
	return {
		"data": {
			"stopped": true,
			"undoable": false,
			"reason": "Play/stop is a runtime action",
		}
	}


func search_filesystem(params: Dictionary) -> Dictionary:
	var name_filter: String = params.get("name", "")
	var type_filter: String = params.get("type", "")
	var path_filter: String = params.get("path", "")

	if name_filter.is_empty() and type_filter.is_empty() and path_filter.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "At least one filter (name, type, path) is required")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "EditorFileSystem not available")

	var results: Array[Dictionary] = []
	_scan_directory(efs.get_filesystem(), name_filter, type_filter, path_filter, results)
	return {"data": {"files": results, "count": results.size()}}


func _scan_directory(dir: EditorFileSystemDirectory, name_filter: String, type_filter: String, path_filter: String, out: Array[Dictionary]) -> void:
	for i in dir.get_file_count():
		var file_path := dir.get_file_path(i)
		var file_type := dir.get_file_type(i)

		var matches := true

		if not name_filter.is_empty():
			if file_path.get_file().to_lower().find(name_filter.to_lower()) == -1:
				matches = false

		if matches and not type_filter.is_empty():
			if file_type != type_filter:
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
		_scan_directory(dir.get_subdir(i), name_filter, type_filter, path_filter, out)
