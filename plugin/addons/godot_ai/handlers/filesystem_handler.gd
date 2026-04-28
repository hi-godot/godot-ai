@tool
extends RefCounted

## Handles file read/write operations and reimport within the Godot project.


func read_file(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	if not FileAccess.file_exists(path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to open file: %s" % path)

	var content := file.get_as_text()
	file.close()

	return {
		"data": {
			"path": path,
			"content": content,
			"size": content.length(),
			"line_count": content.count("\n") + (1 if not content.is_empty() else 0),
		}
	}


func write_file(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var existed_before := FileAccess.file_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)

	file.store_string(content)
	file.close()

	# Trigger reimport so the editor recognises the new/changed file
	EditorInterface.get_resource_filesystem().scan()

	var data := {
		"path": path,
		"size": content.length(),
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	McpResourceIO.attach_cleanup_hint(data, existed_before, [path])
	return {"data": data}


func reimport(params: Dictionary) -> Dictionary:
	var paths: Array = params.get("paths", [])

	if paths.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: paths (non-empty array)")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "EditorFileSystem not available")

	var reimported: Array[String] = []
	var not_found: Array[String] = []

	for path_variant in paths:
		var path: String = str(path_variant)
		if not path.begins_with("res://"):
			not_found.append("%s (must start with res://)" % path)
			continue
		if not FileAccess.file_exists(path):
			not_found.append("%s (file does not exist)" % path)
			continue
		efs.update_file(path)
		reimported.append(path)

	return {
		"data": {
			"reimported": reimported,
			"not_found": not_found,
			"reimported_count": reimported.size(),
			"not_found_count": not_found.size(),
			"undoable": false,
			"reason": "Reimport is a file system operation",
		}
	}
