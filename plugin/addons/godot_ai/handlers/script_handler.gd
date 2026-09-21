@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const DiagnosticsCapture := preload("res://addons/godot_ai/utils/diagnostics_capture.gd")
const ValidationLogger := preload("res://addons/godot_ai/runtime/validation_logger.gd")

## Handles script creation, reading, attaching, detaching, and symbol inspection.
##
## Two script languages cross this surface (#908). GDScript (`.gd`) is the
## full contract: parse-validated on write, hot-reloaded when already loaded,
## outlined by `find_symbols`. C# (`.cs`) is text-only: the plugin writes the
## bytes and outlines the file, but it never compiles .NET — the caller has
## to build the project (editor Build button or `dotnet build`) to learn
## about compiler errors. Loading a `.cs` requires a .NET-enabled editor;
## resource recognition does not prove its managed class was built. Every
## `.cs` write says so
## (`diagnostics_status: "not_checked"`, `validation_hint`, `dotnet_editor`)
## instead of reporting a plain success the caller could mistake for
## validation.

const LANGUAGE_GDSCRIPT := "gdscript"
const LANGUAGE_CSHARP := "csharp"
const CSHARP_VALIDATION_HINT := (
	"C# is written as text only; Godot AI does not compile .NET. Build the "
	+ "project (editor Build button or `dotnet build`) to surface compiler "
	+ "errors, then filesystem_manage(op=\"scan\") before attaching the script."
)
const UNSUPPORTED_EXTENSION_MESSAGE := (
	"Path must end with .gd or .cs (use filesystem_manage op=\"write_text\" for other text files)"
)

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

	var language := script_language(path)
	if language.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, UNSUPPORTED_EXTENSION_MESSAGE)
	var is_csharp := language == LANGUAGE_CSHARP
	var can_settle := not is_csharp or editor_has_dotnet()

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
		"import_settled": existed_before and can_settle,
		"import_settle": "already_known" if existed_before and can_settle else "not_waited",
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
		"language": language,
	}
	if is_csharp:
		_attach_csharp_not_checked(data)
	else:
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
	var declared_class := "" if is_csharp else _extract_class_name(content)
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

	# An overwrite can target a script that is already loaded (attached to a
	# node, preloaded, open in the script editor). Registering the bytes with
	# the editor leaves that live GDScript on the old source (#937), so the very
	# next call would run stale code after a "successful" write. Refresh it
	# BEFORE registering the file: a GUI editor loads the script inside
	# update_file() (see _refresh_loaded_gdscript for the ordering contract).
	if existed_before:
		if is_csharp:
			_mark_csharp_not_reloaded(data)
		else:
			_refresh_loaded_gdscript(data, path, content)

	_register_written_file(path)

	# `.gd.uid` is the sidecar Godot generates on scan; list both so the caller
	# can rm the full set in one go. A `.cs` only gets a sidecar on a .NET
	# editor build, where the C# loader registers it as a resource.
	McpResourceIO.attach_cleanup_hint(data, existed_before, _cleanup_paths(path, is_csharp))

	# scan() is async — ResourceLoader.exists(path) returns false until Godot's
	# filesystem pipeline finishes. If we reply now, an immediate attach_script
	# races and 404s (#261). Defer the response until the resource is visible
	# (or a bounded timeout elapses). For freshly-created files we wait; on
	# overwrite the resource was already known to ResourceLoader, so reply now.
	# A `.cs` on a non-.NET editor never becomes a resource at all — waiting
	# would burn the whole settle window for nothing, so reply synchronously.
	var request_id: String = params.get("_request_id", "")
	if can_settle and not existed_before and _connection != null and not request_id.is_empty():
		McpResourceIO.finish_text_write_deferred(_connection, request_id, path, data)
		return McpDispatcher.DEFERRED_RESPONSE

	# Synchronous fallback: batch_execute (no request_id) and unit-test contexts
	# (no connection) get the immediate reply that the previous behaviour gave.
	return {"data": data}


## Which authoring contract a script path falls under: LANGUAGE_GDSCRIPT,
## LANGUAGE_CSHARP, or "" for anything the script tools refuse.
static func script_language(path: String) -> String:
	if path.ends_with(".gd"):
		return LANGUAGE_GDSCRIPT
	if path.ends_with(".cs"):
		return LANGUAGE_CSHARP
	return ""


## True on a .NET-enabled editor build. `CSharpScript` is registered with
## ClassDB only when the mono module is compiled in, which is exactly when
## ResourceLoader can load a `.cs` (and when Godot writes its `.cs.uid`).
## A string lookup, so it parses on every supported engine.
static func editor_has_dotnet() -> bool:
	return ClassDB.class_exists("CSharpScript")


## The `.cs` counterpart of `_attach_gdscript_diagnostics`: same response
## keys so a caller reads one shape, but `diagnostics_status` says the file
## was NOT validated. An empty `diagnostics` array on its own would read as
## "checked, clean", which is the trap #908 is about.
static func _attach_csharp_not_checked(data: Dictionary) -> void:
	data["diagnostics"] = []
	data["diagnostics_detail"] = "none"
	data["diagnostics_scope"] = "this_file"
	data["diagnostics_status"] = "not_checked"
	data["validation_hint"] = CSHARP_VALIDATION_HINT
	data["dotnet_editor"] = editor_has_dotnet()


## The `.cs` counterpart of `_refresh_loaded_gdscript`: C# never hot-reloads
## from source — the assembly has to be rebuilt — so "the bytes changed" is
## all a write can promise.
static func _mark_csharp_not_reloaded(data: Dictionary) -> void:
	data["reloaded"] = false
	data["reload_reason"] = "csharp_requires_build"


static func _cleanup_paths(path: String, is_csharp: bool) -> Array:
	if is_csharp and not editor_has_dotnet():
		return [path]
	return [path, path + ".uid"]


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


## Register just this file with the editor instead of a full recursive
## scan(). A scan() per write stacks `update_scripts_classes` /
## `update_script_paths_documentation` WorkerThreadPool tasks under concurrent
## script creation ("Task ... already exists" / "!tasks.has(p_task)"), which
## races the global-class registry and can SIGABRT in
## ScriptServer::remove_global_class_by_path (see dsarno/godot#6).
## update_file() is the single-file path the rest of the plugin already uses.
##
## Call it only after `_refresh_loaded_gdscript` has taken its decision (see
## the ordering contract there). Instance (not static) so a test can stand in
## for what a GUI editor does inside update_file() — load or reload the
## script — and lock that ordering from a headless run.
func _register_written_file(path: String) -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)


## Bring an already-loaded GDScript back in step with the bytes just written.
##
## ResourceLoader caches GDScript by path, and registering the write with
## EditorFileSystem does not refresh that cache in a headless editor — so after
## a successful write, a script that a node, a preload(), or the script editor
## already holds keeps executing the previous source (#937). When the path is
## cached and the new source parsed, push the source into the live object and
## reload it in place (keep_state so existing instances survive). Reports
## `reloaded` plus a `reload_reason` when it did not, so a caller can tell
## "the file changed" from "the code changed".
##
## Ordering contract: this runs BEFORE `_register_written_file`. A GUI editor
## (not a headless one — EditorNode's cmdline mode skips the step) runs its
## script-documentation pass synchronously inside update_file(), which
## ResourceLoader.load()s the script, caching a never-loaded one, and
## reload_from_file()s a cached one that is not open in the script editor.
## Deciding after that call reports a false `already_current` for a script
## nobody held (instead of `not_loaded`) and for one this helper should have
## refreshed itself. The question is what was loaded before the write, so it
## is answered first; the editor's own pass then meets the same bytes.
##
## Skipped when validation failed: the diagnostics capture above has already
## reloaded the shared GDScriptCache entry with the broken source, so there is
## no good code to push; `reload_reason: parse_error` tells the caller the
## loaded code did NOT change to something runnable.
static func _refresh_loaded_gdscript(data: Dictionary, path: String, content: String) -> void:
	data["reloaded"] = false
	if _script_has_error_diagnostics(data):
		data["reload_reason"] = "parse_error"
		return
	if not ResourceLoader.has_cached(path):
		data["reload_reason"] = "not_loaded"
		return
	var loaded := ResourceLoader.load(path)
	if not (loaded is GDScript):
		data["reload_reason"] = "not_gdscript"
		return
	var script := loaded as GDScript
	if script.source_code == content:
		data["reloaded"] = true
		data["reload_reason"] = "already_current"
		return
	script.source_code = content
	var err := script.reload(true)
	if err != OK:
		data["reload_reason"] = "reload_failed"
		data["reload_error"] = err
		return
	data["reloaded"] = true


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
	var language := script_language(path)
	if language.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, UNSUPPORTED_EXTENSION_MESSAGE)
	var is_csharp := language == LANGUAGE_CSHARP
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
		"language": language,
	}
	if is_csharp:
		_attach_csharp_not_checked(data)
		_mark_csharp_not_reloaded(data)
	else:
		_attach_gdscript_diagnostics(data, path, new_content)
		# The file is fresh but any already-loaded GDScript for it is not (#937);
		# make "patch succeeded" mean the loaded code changed, not just the bytes.
		# Decide and refresh before registering the file with the editor — a GUI
		# editor loads the script inside update_file() (see _refresh_loaded_gdscript).
		_refresh_loaded_gdscript(data, path, new_content)
	_register_written_file(path)

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

	# A `.cs` is a Script only where the mono module exists. Without it the
	# generic "Script not found" below would send the caller hunting for a
	# path problem that isn't one (#908).
	var is_csharp := script_language(script_path) == LANGUAGE_CSHARP
	if is_csharp and not editor_has_dotnet():
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"script_path: %s is a C# script but this editor build has no .NET support " % script_path
			+ "(CSharpScript is unavailable). Run a .NET-enabled Godot build, or attach a .gd script.",
		)

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var _scene_root: Node = _resolved.scene_root

	if not ResourceLoader.exists(script_path):
		return ErrorCodes.make(
			ErrorCodes.RESOURCE_NOT_FOUND,
			"Script not found: %s" % script_path + _csharp_load_hint(is_csharp),
		)

	var script: Script = load(script_path)
	if script == null:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to load script: %s" % script_path + _csharp_load_hint(is_csharp),
		)

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


## Appended to attach_script's load failures for a `.cs`: on a .NET editor
## the usual reason is that the assembly hasn't been built since the file
## appeared, not that the path is wrong.
static func _csharp_load_hint(is_csharp: bool) -> String:
	if not is_csharp:
		return ""
	return (
		" (check the C# source path and build the project assembly using the "
		+ "editor Build button or `dotnet build`, then filesystem_manage(op=\"scan\"); "
		+ "resource recognition alone does not verify a compiled class)"
	)


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

	if script_language(path) == LANGUAGE_CSHARP:
		return {"data": _csharp_symbols(path, content)}

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
			"language": LANGUAGE_GDSCRIPT,
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


# ----- C# outline ------------------------------------------------------------

## Lines that start with one of these can still match the method pattern
## (`else if (`, `return Foo(`, `new Bar(`), so they're skipped by first word.
const _CSHARP_CONTROL_WORDS: PackedStringArray = [
	"if", "else", "for", "foreach", "while", "do", "switch", "case", "catch",
	"using", "return", "new", "throw", "await", "lock", "yield", "goto",
]

## Same outline shape as the GDScript branch, from a line-based scan (no
## Roslyn here). Mirrors Godot's C# conventions: the first `class` is the
## script class and its first base type is `extends`; `[Signal]` marks a
## delegate whose Godot signal name drops the `EventHandler` suffix;
## `[Export]` marks the next field or property. Attributes may sit on their
## own line or share the member's line, and may stack (`[Export] [Obsolete]`).
static func _csharp_symbols(path: String, content: String) -> Dictionary:
	var functions: Array[Dictionary] = []
	var signals_list: Array[String] = []
	var exports: Array[Dictionary] = []
	var class_name_str := ""
	var extends_str := ""

	var class_re := RegEx.create_from_string(
		"^(?:(?:public|internal|private|protected|static|partial|abstract|sealed)\\s+)*"
		+ "class\\s+([A-Za-z_][A-Za-z0-9_]*)(?:\\s*<[^>]*>)?(?:\\s*:\\s*([A-Za-z_][A-Za-z0-9_.]*))?"
	)
	var method_re := RegEx.create_from_string(
		"^(?:(?:public|private|protected|internal|static|override|virtual|abstract|async|sealed|new|partial|extern|unsafe)\\s+)*"
		+ "[A-Za-z_][A-Za-z0-9_<>\\[\\],.?]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:<[^>]*>)?\\s*\\("
	)
	var delegate_re := RegEx.create_from_string("delegate\\s+\\S+\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	var member_re := RegEx.create_from_string(
		"^(?:(?:public|private|protected|internal|static|readonly|new|virtual|override|required)\\s+)*"
		+ "[A-Za-z_][A-Za-z0-9_<>\\[\\],.?]*\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?:\\{|=|;|$)"
	)

	var pending_signal := false
	var pending_export := false
	var lines := content.split("\n")
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.is_empty() or line.begins_with("//") or line.begins_with("#"):
			continue

		# Peel leading attributes; what's left (if anything) is the member.
		var rest := line
		while rest.begins_with("["):
			var close := rest.find("]")
			if close < 0:
				break
			var attr := rest.substr(1, close - 1).strip_edges()
			if attr == "Signal" or attr.begins_with("Signal("):
				pending_signal = true
			if attr == "Export" or attr.begins_with("Export("):
				pending_export = true
			rest = rest.substr(close + 1).strip_edges()
		if rest.is_empty():
			continue

		if class_name_str.is_empty():
			var cm := class_re.search(rest)
			if cm != null:
				class_name_str = cm.get_string(1)
				extends_str = cm.get_string(2)
				continue

		if pending_signal:
			pending_signal = false
			var dm := delegate_re.search(rest)
			if dm != null:
				var sig := dm.get_string(1)
				if sig.ends_with("EventHandler"):
					sig = sig.substr(0, sig.length() - "EventHandler".length())
				signals_list.append(sig)
			continue

		if pending_export:
			pending_export = false
			var em := member_re.search(rest)
			if em != null:
				exports.append({"name": em.get_string(1), "line": i + 1})
			continue

		if rest.find("delegate ") >= 0:
			continue
		var first_word := rest.get_slice(" ", 0).get_slice("(", 0)
		if first_word in _CSHARP_CONTROL_WORDS:
			continue
		var mm := method_re.search(rest)
		if mm != null:
			functions.append({"name": mm.get_string(1), "line": i + 1})

	return {
		"path": path,
		"language": LANGUAGE_CSHARP,
		"class_name": class_name_str,
		"extends": extends_str,
		"functions": functions,
		"signals": signals_list,
		"exports": exports,
		"function_count": functions.size(),
		"signal_count": signals_list.size(),
		"export_count": exports.size(),
	}
