@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const DiagnosticsCapture := preload("res://addons/godot_ai/utils/diagnostics_capture.gd")
const ValidationLogger := preload("res://addons/godot_ai/runtime/validation_logger.gd")

## Handles script creation, reading, attaching, detaching, and symbol inspection.

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection

# The bounded import-settle window and the deferred completion coroutine
# live on McpResourceIO since #714 — write_file's fresh-`.gd` path shares
# them, so create_script and write_file can't drift apart again (#261).

func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


func create_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err

	if not path.ends_with(".gd"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Path must end with .gd")

	var existed_before := FileAccess.file_exists(path)

	# Shared write path (#714): parent mkdir + write/flush + explicit error
	# check live on McpResourceIO so write_file can't drift from this again.
	var write_failure: Variant = McpResourceIO.write_text_to_disk(path, content)
	if write_failure != null:
		return write_failure

	var data := {
		"path": path,
		"size": content.length(),
		"committed": true,
		"import_settled": existed_before,
		"import_settle": "already_known" if existed_before else "not_waited",
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	_attach_gdscript_diagnostics(data, path, content)

	# A freshly-declared `class_name` is NOT in the global class table until a
	# filesystem scan runs — update_file() below registers the file with the
	# resource pipeline but not the class registry (see the scan() comment).
	# Surface that precisely (only when the class isn't already registered) so a
	# headless caller knows to follow up with filesystem_manage(op="scan")
	# instead of hitting a confusing "Unknown type" / "Unknown resource type" on
	# the very next call. We don't scan here — a scan() per create is the exact
	# SIGABRT race documented below; the explicit op is single-flight.
	# Skip the hint when the script failed to parse: a scan won't register a
	# class from a broken script, so pointing at op="scan" would steer the caller
	# away from the real fix (the parse error already attached above).
	var declared_class := _extract_class_name(content)
	if (
		not declared_class.is_empty()
		and not _script_has_error_diagnostics(data)
		and not _class_name_registered(declared_class)
	):
		data["class_name"] = declared_class
		data["class_registration"] = "scan_required"
		data["class_registration_hint"] = (
			"New class_name '%s' isn't in the global class table yet. " % declared_class
			+ "Call filesystem_manage(op=\"scan\") if it won't resolve on the next "
			+ "call (e.g. resource_manage op=\"create\", or used as a type in another "
			+ "script). The editor also registers it on its next filesystem scan or "
			+ "when its window regains focus."
		)

	# Register just this file with the editor instead of a full recursive
	# scan(). A scan() per write stacks `update_scripts_classes` /
	# `update_script_paths_documentation` WorkerThreadPool tasks under concurrent
	# script creation ("Task ... already exists" / "!tasks.has(p_task)"), which
	# races the global-class registry and can SIGABRT in
	# ScriptServer::remove_global_class_by_path (see dsarno/godot#6).
	# update_file() is the single-file path the rest of the plugin already uses.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

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
		McpResourceIO.finish_text_write_deferred(_connection, request_id, path, data)
		return McpDispatcher.DEFERRED_RESPONSE

	# Synchronous fallback: batch_execute (no request_id) and unit-test contexts
	# (no connection) get the immediate reply that the previous behaviour gave.
	return {"data": data}


## Extract the `class_name` a script declares, or "" if none. A cheap line scan
## (no full parse) for create_script's "scan_required" hint. Stops at the first
## space/tab or comma so all three valid forms yield just the name:
## `class_name Foo`, `class_name Foo extends Bar`, and the icon form
## `class_name Foo, "res://icon.svg"`.
static func _extract_class_name(content: String) -> String:
	for raw_line in content.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("class_name "):
			var rest := line.substr(11).strip_edges()
			var cut := rest.length()
			for i in rest.length():
				var ch := rest[i]
				if ch == " " or ch == "\t" or ch == ",":
					cut = i
					break
			return rest.substr(0, cut)
	return ""


## True if create_script's diagnostics captured a parse error for this script.
## Used to suppress the "scan_required" hint when the class can't register
## anyway — see create_script.
static func _script_has_error_diagnostics(data: Dictionary) -> bool:
	for diag in data.get("diagnostics", []):
		if diag is Dictionary and diag.get("level", "") == "error":
			return true
	return false


## True if `cn` is already usable as a type — an engine built-in (ClassDB) or an
## already-registered project global class. A brand-new class_name returns false
## until a filesystem scan registers it.
static func _class_name_registered(cn: String) -> bool:
	if ClassDB.class_exists(cn):
		return true
	for entry in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == cn:
			return true
	return false


func read_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")

	var path_err = McpPathValidator.path_error(path, "path")
	if path_err != null:
		return path_err

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


## Instance (not static) despite using no instance state: tests stub
## `_capture_gdscript_load_diagnostics` via subclass override, and static
## calls bind lexically — see test_script.gd. filesystem_handler shares
## this by instantiating a bare ScriptHandler (#714).
func _attach_gdscript_diagnostics(data: Dictionary, path: String, content: String) -> void:
	var validation := _validate_gdscript_source(content)
	var diagnostics: Array = []
	var diagnostics_detail := "none"
	var diagnostics_status := "checked"

	if not validation.get("ok", true):
		var capture := _capture_gdscript_load_diagnostics(path)
		diagnostics = capture.get("diagnostics", [])
		diagnostics_detail = capture.get("diagnostics_detail", "none")
		diagnostics_status = capture.get("diagnostics_status", "checked")
	if not validation.get("ok", true) and diagnostics.is_empty():
		diagnostics.append(_fallback_gdscript_diagnostic(path, validation.get("error_code", FAILED), content))
		diagnostics_detail = "fallback"
	data["diagnostics"] = diagnostics
	data["diagnostics_detail"] = diagnostics_detail
	data["diagnostics_scope"] = "this_file"
	data["diagnostics_status"] = diagnostics_status


static func _validate_gdscript_source(content: String) -> Dictionary:
	var script := GDScript.new()
	script.source_code = content
	## Keep validation off the live cached resource: assigning resource_path to
	## this ephemeral Script can collide with loaded instances. reload() still
	## performs normal GDScript analysis, including static initializer work, so
	## this check is intentionally scoped to `.gd` writes where the editor would
	## compile the file on scan anyway.
	var err := script.reload()
	return {
		"ok": err == OK,
		"error_code": err,
	}


func _capture_gdscript_load_diagnostics(path: String) -> Dictionary:
	var buffer := McpEditorLogBuffer.new()
	var logger := ValidationLogger.new(buffer)
	var capture := DiagnosticsCapture.capture_this_file(buffer, path, func() -> Dictionary:
		OS.add_logger(logger)
		# ResourceLoader.load() reports parse failure instead of throwing, and
		# a failed GDScript parse does not execute user code; remove immediately
		# after the synchronous load to keep the private capture window tiny.
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		OS.remove_logger(logger)
		return {}
	)
	return capture


static func _fallback_gdscript_diagnostic(path: String, error_code: int, content: String) -> Dictionary:
	var line := _fallback_gdscript_error_line(content)
	return {
		"source": "editor",
		"level": "error",
		"text": "GDScript reload failed with error code %d." % error_code,
		"path": path,
		"line": line,
		"function": "GDScript::reload",
		"details": {
			"code": "gdscript_reload_failed",
			"error_code": error_code,
			"fallback_line": true,
			"source": {
				"path": path,
				"line": line,
			},
		},
	}


static func _fallback_gdscript_error_line(content: String) -> int:
	var lines := content.split("\n")
	for i in range(lines.size() - 1, -1, -1):
		if not str(lines[i]).strip_edges().is_empty():
			return i + 1
	return 1


func patch_script(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var old_text: String = params.get("old_text", "")
	var new_text: String = params.get("new_text", "")
	var replace_all: bool = params.get("replace_all", false)

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err
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

	# Shared write path (#714). No import-settle deferral here: the file
	# already exists, so ResourceLoader knows it and there is no scan to wait
	# for — same rationale as create_script's overwrite arm.
	var write_failure: Variant = McpResourceIO.write_text_to_disk(path, new_content)
	if write_failure != null:
		return write_failure

	var data := {
		"path": path,
		"replacements": replacements,
		"size": new_content.length(),
		"old_size": content.length(),
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	_attach_gdscript_diagnostics(data, path, new_content)

	# Single-file register, not a full scan() — see create_script (dsarno/godot#6).
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	return {"data": data}


func attach_script(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var script_path: String = params.get("script_path", "")

	if node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	if script_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: script_path")

	var spath_err = McpPathValidator.loadable_error(script_path, "script_path")
	if spath_err != null:
		return spath_err

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var _scene_root: Node = _resolved.scene_root

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
	var _scene_root: Node = _resolved.scene_root

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

	var path_err = McpPathValidator.path_error(path, "path")
	if path_err != null:
		return path_err

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

		# class_name — same cut logic as _extract_class_name so the
		# `extends Bar` / icon-form tails don't leak into the symbol name.
		if line.begins_with("class_name "):
			var cn_rest := line.substr(11).strip_edges()
			var cn_cut := cn_rest.length()
			for ci in cn_rest.length():
				var cn_ch := cn_rest[ci]
				if cn_ch == " " or cn_ch == "\t" or cn_ch == ",":
					cn_cut = ci
					break
			class_name_str = cn_rest.substr(0, cn_cut)

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

		# func (including `static func` — strip the leading `static ` first)
		var func_line := line.substr(7).strip_edges() if line.begins_with("static func ") else line
		if func_line.begins_with("func "):
			var func_text := func_line.substr(5).strip_edges()
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
