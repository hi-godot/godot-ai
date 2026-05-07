@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles script creation, reading, attaching, detaching, and symbol inspection.

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection

# Bounded settle window for `ResourceLoader.exists(path)` after `scan()` so
# that an agent calling create_script -> attach_script back-to-back doesn't
# race the editor's import pipeline (#261). Polled once per frame, with an
# elapsed-time cap below the dispatcher's create_script deferred timeout. If
# import is still not visible at the cap, we still return committed=true
# instead of letting the already-written file surface as DEFERRED_TIMEOUT.
const _IMPORT_SETTLE_MAX_FRAMES := 300
const _IMPORT_SETTLE_MAX_MSEC := 3500


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


func create_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	var path_err := McpPathValidator.validate_resource_path(path)
	if not path_err.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, path_err)

	if not path.ends_with(".gd"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Path must end with .gd")

	# Ensure parent directory exists
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to create directory: %s" % dir_path)

	var existed_before := FileAccess.file_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)

	file.store_string(content)
	file.close()

	# Trigger reimport so the editor recognises the new file
	EditorInterface.get_resource_filesystem().scan()

	var data := {
		"path": path,
		"size": content.length(),
		"committed": true,
		"import_settled": existed_before,
		"import_settle": "already_known" if existed_before else "not_waited",
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	# `.gd.uid` is the sidecar Godot generates on scan; list both so the caller
	# can rm the full set in one go.
	McpResourceIO.attach_cleanup_hint(data, existed_before, [path, path + ".uid"])

	# scan() is async — ResourceLoader.exists(path) returns false until Godot's
	# filesystem pipeline finishes. If we reply now, an immediate attach_script
	# races and 404s (#261). Defer the response until the resource is visible
	# (or a bounded timeout elapses). For freshly-created files we wait; on
	# overwrite the resource was already known to ResourceLoader, so reply now.
	var request_id: String = params.get("_request_id", "")
	if not existed_before and _connection != null and not request_id.is_empty():
		_finish_create_script_deferred(request_id, path, data)
		return McpDispatcher.DEFERRED_RESPONSE

	# Synchronous fallback: batch_execute (no request_id) and unit-test contexts
	# (no connection) get the immediate reply that the previous behaviour gave.
	return {"data": data}


func _finish_create_script_deferred(request_id: String, path: String, data: Dictionary) -> void:
	var tree := _connection.get_tree()
	var deadline_ms := Time.get_ticks_msec() + _IMPORT_SETTLE_MAX_MSEC
	# Let _dispatch() return DEFERRED_RESPONSE and register the request before
	# this coroutine can send a committed result. ResourceLoader.exists(path)
	# may already be true on fast imports; without this handoff the connection
	# treats the response as late/unregistered and drops it, then the dispatcher
	# times out a file that was already written (#324). The deadline starts
	# before this await so a slow handoff frame is counted against the bounded
	# settle window.
	await tree.process_frame
	var frames := 0
	while (
		frames < _IMPORT_SETTLE_MAX_FRAMES
		and Time.get_ticks_msec() < deadline_ms
		and not ResourceLoader.exists(path)
	):
		await tree.process_frame
		frames += 1
	# If the plugin tears down (_exit_tree frees _connection) during the await,
	# is_instance_valid() goes false and we drop the response silently — the
	# server's request timeout will surface the failure to the caller.
	if not is_instance_valid(_connection):
		return
	var payload := data.duplicate()
	var settled := ResourceLoader.exists(path)
	payload["import_settled"] = settled
	payload["import_settle"] = "settled" if settled else "timeout"
	payload["import_pending"] = not settled
	_connection.send_deferred_response(request_id, {"data": payload})


func read_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")

	var path_err := McpPathValidator.validate_resource_path(path)
	if not path_err.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, path_err)

	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file: %s" % path)

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

	var path_err := McpPathValidator.validate_resource_path(path)
	if not path_err.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, path_err)
	if not "old_text" in params:
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: old_text")
	if not "new_text" in params:
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: new_text")
	if not path.ends_with(".gd"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Path must end with .gd (use filesystem_write_text for other text files)")
	if old_text.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "old_text must not be empty")

	var read := FileAccess.open(path, FileAccess.READ)
	if read == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found or unreadable: %s" % path)
	var content := read.get_as_text()
	read.close()

	var match_count := content.count(old_text)
	if match_count == 0:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "old_text not found in %s" % path)
	if match_count > 1 and not replace_all:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
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
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file for writing: %s" % path)
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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	if script_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: script_path")

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var scene_root: Node = _resolved.scene_root

	if not ResourceLoader.exists(script_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Script not found: %s" % script_path)

	var script: Script = load(script_path)
	if script == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load script: %s" % script_path)

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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var scene_root: Node = _resolved.scene_root

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

	var path_err := McpPathValidator.validate_resource_path(path)
	if not path_err.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, path_err)

	if not FileAccess.file_exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to open file: %s" % path)

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
