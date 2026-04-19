@tool
class_name ScriptHandler
extends RefCounted

## Handles script creation, reading, attaching, detaching, and symbol inspection.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func create_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")

	if not path.ends_with(".gd"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must end with .gd")

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

	# Trigger reimport so the editor recognises the new file
	EditorInterface.get_resource_filesystem().scan()

	var data := {
		"path": path,
		"size": content.length(),
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	# `.gd.uid` is the sidecar Godot generates on scan; list both so the caller
	# can rm the full set in one go.
	ResourceIO.attach_cleanup_hint(data, existed_before, [path, path + ".uid"])
	return {"data": data}


func read_script(params: Dictionary) -> Dictionary:
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


func patch_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var old_text: String = params.get("old_text", "")
	var new_text: String = params.get("new_text", "")
	var replace_all: bool = params.get("replace_all", false)

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")
	if not "old_text" in params:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: old_text")
	if not "new_text" in params:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: new_text")
	if not path.begins_with("res://"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must start with res://")
	if not path.ends_with(".gd"):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Path must end with .gd (use filesystem_write_text for other text files)")
	if old_text.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "old_text must not be empty")

	var read := FileAccess.open(path, FileAccess.READ)
	if read == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "File not found or unreadable: %s" % path)
	var content := read.get_as_text()
	read.close()

	var match_count := content.count(old_text)
	if match_count == 0:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "old_text not found in %s" % path)
	if match_count > 1 and not replace_all:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"old_text matches %d times; pass replace_all=true or provide a more specific snippet" % match_count,
		)

	var new_content: String
	var replacements: int
	if replace_all:
		new_content = content.replace(old_text, new_text)
		replacements = match_count
	else:
		var idx := content.find(old_text)
		new_content = content.substr(0, idx) + new_text + content.substr(idx + old_text.length())
		replacements = 1

	var write := FileAccess.open(path, FileAccess.WRITE)
	if write == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)
	write.store_string(new_content)
	write.close()

	EditorInterface.get_resource_filesystem().scan()

	return {
		"data": {
			"path": path,
			"replacements": replacements,
			"size": new_content.length(),
			"old_size": content.length(),
			"undoable": false,
			"reason": "File system operations cannot be undone via editor undo",
		}
	}


func attach_script(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var script_path: String = params.get("script_path", "")

	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	if script_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: script_path")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	if not ResourceLoader.exists(script_path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Script not found: %s" % script_path)

	var script: Script = load(script_path)
	if script == null:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to load script: %s" % script_path)

	var old_script: Script = node.get_script()

	_undo_redo.create_action("MCP: Attach script to %s" % node.name)
	_undo_redo.add_do_method(node, "set_script", script)
	_undo_redo.add_undo_method(node, "set_script", old_script)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"script_path": script_path,
			"had_previous_script": old_script != null,
			"undoable": true,
		}
	}


func detach_script(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")

	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)

	var old_script: Script = node.get_script()
	if old_script == null:
		return {"data": {"path": node_path, "had_script": false, "undoable": false, "reason": "No script attached"}}

	_undo_redo.create_action("MCP: Detach script from %s" % node.name)
	_undo_redo.add_do_method(node, "set_script", null)
	_undo_redo.add_undo_method(node, "set_script", old_script)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"removed_script": old_script.resource_path if old_script.resource_path else "(inline)",
			"undoable": true,
		}
	}


func find_symbols(params: Dictionary) -> Dictionary:
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

	var functions: Array[Dictionary] = []
	var signals_list: Array[String] = []
	var exports: Array[Dictionary] = []
	var class_name_str := ""
	var extends_str := ""

	var lines := content.split("\n")
	for i in lines.size():
		var line := lines[i].strip_edges()

		# class_name
		if line.begins_with("class_name "):
			class_name_str = line.substr(11).strip_edges()

		# extends
		if line.begins_with("extends "):
			extends_str = line.substr(8).strip_edges()

		# signal
		if line.begins_with("signal "):
			var sig_text := line.substr(7).strip_edges()
			# Strip any parameters for the name
			var paren_idx := sig_text.find("(")
			if paren_idx >= 0:
				signals_list.append(sig_text.substr(0, paren_idx).strip_edges())
			else:
				signals_list.append(sig_text)

		# func
		if line.begins_with("func "):
			var func_text := line.substr(5).strip_edges()
			var paren_idx := func_text.find("(")
			if paren_idx >= 0:
				functions.append({
					"name": func_text.substr(0, paren_idx).strip_edges(),
					"line": i + 1,
				})

		# @export
		if line.begins_with("@export"):
			# Next non-empty line should have the var declaration
			# But often export and var are on the same logical flow
			# Try to find "var" on the same line or the next line
			var var_line := line
			if var_line.find("var ") == -1 and i + 1 < lines.size():
				var_line = lines[i + 1].strip_edges()
			var var_idx := var_line.find("var ")
			if var_idx >= 0:
				var rest := var_line.substr(var_idx + 4).strip_edges()
				# Extract variable name (up to : or = or end)
				var end_idx := rest.length()
				for ch_idx in rest.length():
					if rest[ch_idx] == ":" or rest[ch_idx] == "=" or rest[ch_idx] == " ":
						end_idx = ch_idx
						break
				exports.append({
					"name": rest.substr(0, end_idx),
					"line": i + 1,
				})

	return {
		"data": {
			"path": path,
			"class_name": class_name_str,
			"extends": extends_str,
			"functions": functions,
			"signals": signals_list,
			"exports": exports,
			"function_count": functions.size(),
			"signal_count": signals_list.size(),
			"export_count": exports.size(),
		}
	}
