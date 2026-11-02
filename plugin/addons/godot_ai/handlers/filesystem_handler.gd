@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")

## Handles file read/write operations and reimport within the Godot project.

## Kept under the dispatcher's "scan_filesystem" deferred timeout (30s) so we
## always send a real reply before a DEFERRED_TIMEOUT is synthesised.
const _SCAN_SETTLE_MAX_MSEC := 28000

## Sidecar the editor writes next to every imported resource. `reimport` reads
## it to tell imported assets from files that merely have a filesystem entry
## (see `_is_imported_resource`).
const IMPORT_SIDECAR_SUFFIX := ".import"

class ScanCompletion extends RefCounted:
	var completed := false
	var accepted := false
	var last_root_id := 0
	var root_changes := 0
	var required_root_changes := 1


## Godot clears is_scanning() before full-scan script registration finishes.
## Its progress dialog can pump nested frames, so polling that flag can release
## callers into reentrant updates of the live registration map (Godot #119505).
## Keep this shared across handler instances and request timeouts: only a
## deferred native completion signal permits another scan to start.
static var _active_scan: ScanCompletion = null

var _connection: McpConnection


func _init(connection: McpConnection = null) -> void:
	_connection = connection


func read_file(params: Dictionary) -> Dictionary:
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


func write_file(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = params.get("content", "")

	var path_err = McpPathValidator.path_error(path, "path", true)
	if path_err != null:
		return path_err

	var existed_before := FileAccess.file_exists(path)

	# Shared write path (#714): parent mkdir + write/flush + explicit error
	# check live on McpResourceIO so this can't drift from create_script.
	var write_failure: Variant = McpResourceIO.write_text_to_disk(path, content)
	if write_failure != null:
		return write_failure

	# Single-file register, not a full scan() — a scan() per write stacks
	# filesystem WorkerThreadPool tasks under concurrent writes and can SIGABRT
	# in the global-class update (see dsarno/godot#6 and create_script in
	# script_handler.gd). update_file() is what reimport()/material/theme use.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	var data := {
		"path": path,
		"size": content.length(),
		"undoable": false,
		"reason": "File system operations cannot be undone via editor undo",
	}
	var is_gdscript := path.ends_with(".gd")
	## A .gd written through the filesystem tool used to skip the parse
	## diagnostics create_script attaches (#714) — the agent's broken
	## script reported plain success and the parse error surfaced only in
	## later editor logs. Same shared check, same response fields. A bare
	## ScriptHandler works here: the diagnostics path touches no instance
	## state (it stays an instance method only for test stubbing).
	if is_gdscript:
		ScriptHandler.new(null)._attach_gdscript_diagnostics(data, path, content)
		data["committed"] = true
		data["import_settled"] = existed_before
		data["import_settle"] = "already_known" if existed_before else "not_waited"
	McpResourceIO.attach_cleanup_hint(data, existed_before, [path])

	## Fresh `.gd` writes take create_script's import-settle deferral (#714,
	## #261): reply only once ResourceLoader can see the new resource (or the
	## bounded window elapses), so write_file -> script_attach back-to-back
	## can't 404 on the not-yet-imported script. This CHANGES write_file's
	## response timing for that case — the reply lands up to
	## McpResourceIO.IMPORT_SETTLE_MAX_MSEC later instead of immediately.
	## Scoped to .gd: ResourceLoader never learns plain text files, so an
	## unconditional wait would burn the full window on every fresh .txt.
	## Overwrites, batch_execute (no request_id) and unit-test contexts (no
	## connection) keep the synchronous reply.
	var request_id: String = params.get("_request_id", "")
	if is_gdscript and not existed_before and _connection != null and not request_id.is_empty():
		McpResourceIO.finish_text_write_deferred(_connection, request_id, path, data)
		return McpDispatcher.DEFERRED_RESPONSE

	return {"data": data}


func import_get(params: Dictionary) -> Dictionary:
	var ctx := _read_import_config(params.get("path", ""))
	if ctx.has("error"):
		return ctx
	return {"data": _import_description(ctx)}


func import_set(params: Dictionary) -> Dictionary:
	var result := _set_import_config(params)
	if result.has("error"):
		var outcome: Dictionary = result.error.get("data", {})
		if not outcome.has("settings_committed"):
			outcome["settings_committed"] = false
			outcome["import_attempted"] = false
		result.error["data"] = outcome
	return result


func _set_import_config(params: Dictionary) -> Dictionary:
	for key in params:
		if key not in ["path", "options", "reimport", "expected_revision", "_request_id"]:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unsupported import_set parameter: %s" % str(key))
	var busy := _import_busy_error()
	if not busy.is_empty():
		return busy
	var ctx := _read_import_config(params.get("path", ""), true)
	if ctx.has("error"):
		return ctx
	var options: Variant = params.get("options", {})
	if not options is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "options must be a dictionary")
	if options.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide at least one import option")
	var reimport_now: Variant = params.get("reimport", true)
	var expected: Variant = params.get("expected_revision", "")
	if not reimport_now is bool or not expected is String:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "reimport must be a boolean and expected_revision must be a string")
	if not expected.is_empty() and expected != ctx.revision:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Import settings revision changed; call import_get before editing again")
	if _import_validity(ctx.path) == null:
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "Asset is not indexed by EditorFileSystem; run scan before editing import settings", true)
	for key in options:
		if not key is String:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Import option names must be strings")
		if key == "_subresources":
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Subresource import options are read-only; no public native schema is available")
		if not ctx.config.has_section_key("params", key):
			return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS, "Unknown stored import option: %s" % key)
		var old: Variant = ctx.config.get_value("params", key)
		var converted: Variant = _import_option_value(options[key], typeof(old))
		if converted == null:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Option '%s' requires stored scalar type %s; complex/nil options are read-only" % [key, type_string(typeof(old))])
		ctx.config.set_value("params", key, converted)
	var stage: String = ctx.sidecar.get_base_dir().path_join(".godot_ai_import_%s.tmp" % Time.get_ticks_usec())
	if FileAccess.file_exists(stage):
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Import staging path already exists: %s" % stage)
	var write_error: Variant = McpResourceIO.write_text_to_disk(stage, ctx.config.encode_to_text())
	if write_error != null:
		DirAccess.remove_absolute(stage)
		return write_error
	# An external editor can change the sidecar while this request is staging.
	busy = _import_busy_error()
	if not busy.is_empty() or FileAccess.get_sha256(ctx.sidecar) != ctx.revision:
		DirAccess.remove_absolute(stage)
		return busy if not busy.is_empty() else ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Import settings changed during staging; original was not replaced")
	var replacement := McpResourceIO._replace_staged_file(stage, ctx.sidecar, OS.get_name() == "Windows")
	if replacement.has("error"):
		return replacement
	var valid: Variant = _import_validity(ctx.path)
	var imported := {"error_count": 0, "diagnostics": []}
	if reimport_now:
		imported = _reimport_paths(EditorInterface.get_resource_filesystem(), PackedStringArray([ctx.path]))
		valid = imported.validity.get(ctx.path)
	var data := {
		"path": ctx.path, "settings_committed": true, "import_attempted": reimport_now,
		"import_valid": valid, "import_pending": not reimport_now or valid != true or imported.error_count > 0,
		"import_succeeded": valid == true and imported.error_count == 0 if reimport_now else null,
		"import_diagnostics": imported.diagnostics, "import_error_count": imported.error_count,
		"diagnostics_scope": "editor_during_reimport",
		"revision": FileAccess.get_sha256(ctx.sidecar),
		"schema_source": "stored_import_config", "undoable": false,
		"reason": "Import settings and generated files are persistent; restore the prior options and reimport to revert",
	}
	data.merge(replacement)
	if reimport_now and (valid != true or imported.error_count > 0):
		var failure := ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Import settings were committed, but native reimport reported errors or an invalid asset. Inspect import_get and editor errors before retrying.")
		failure.error["data"] = data
		return failure
	return {"data": data}


func _read_import_config(path: Variant, for_write := false) -> Dictionary:
	if not path is String:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "path must be a string")
	var path_error: Variant = McpPathValidator.path_error(path, "path", for_write)
	if path_error != null:
		return path_error
	var sidecar: String = path + IMPORT_SIDECAR_SUFFIX
	path_error = McpPathValidator.path_error(sidecar, "import sidecar", for_write)
	if path_error != null:
		return path_error
	if not FileAccess.file_exists(path) or not FileAccess.file_exists(sidecar):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Asset has no import settings: %s. Run scan for a new asset." % path)
	var file := FileAccess.open(sidecar, FileAccess.READ)
	if file == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not read import settings: %s" % sidecar)
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	var revision := hash.finish().hex_encode()
	var config := ConfigFile.new()
	var parse_error := config.parse(bytes.get_string_from_utf8())
	if parse_error != OK:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Invalid import settings at %s: %s" % [sidecar, error_string(parse_error)])
	if not config.has_section_key("remap", "importer") or not config.has_section("params"):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Import settings at %s require a [remap] importer and [params] section" % sidecar)
	return {"path": path, "sidecar": sidecar, "config": config, "revision": revision}


func _import_description(ctx: Dictionary) -> Dictionary:
	var options := {}
	var types := {}
	var writable: Array[String] = []
	for key in ctx.config.get_section_keys("params"):
		var value: Variant = ctx.config.get_value("params", key)
		options[key] = preload("res://addons/godot_ai/utils/variant_serializer.gd").serialize(value)
		types[key] = type_string(typeof(value))
		if key != "_subresources" and typeof(value) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME]:
			writable.append(key)
	return {
		"path": ctx.path, "importer": ctx.config.get_value("remap", "importer"),
		"options": options, "option_types": types, "writable_options": writable,
		"revision": ctx.revision, "import_valid": _import_validity(ctx.path),
		"schema_source": "stored_import_config",
		"validation_limits": "Stored keys and scalar types only; native importer enum/range schemas are not exposed. Importer switching and subresource writes are unsupported.",
	}


static func _import_option_value(value: Variant, expected_type: int) -> Variant:
	match expected_type:
		TYPE_BOOL:
			return value if value is bool else null
		TYPE_INT:
			if value is int:
				return value
			if value is float and is_finite(value) and value == floor(value) and value >= -9223372036854775808.0 and value < 9223372036854775808.0:
				return int(value)
		TYPE_FLOAT:
			if (value is int or value is float) and is_finite(float(value)):
				return float(value)
		TYPE_STRING:
			return value if value is String else null
		TYPE_STRING_NAME:
			return StringName(value) if value is String else null
	return null


static func _import_busy_error() -> Dictionary:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem is unavailable", false)
	if efs.is_importing() or efs.is_scanning() or _has_pending_scan():
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "Wait for the current import or scan before changing import settings", true)
	return {}


static func _import_validity(path: String) -> Variant:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return null
	var directory := efs.get_filesystem_path(path.get_base_dir())
	if directory == null:
		return null
	var index := directory.find_file_index(path.get_file())
	return directory.get_file_import_is_valid(index) if index >= 0 else null


func _reimport_paths(efs: EditorFileSystem, paths: PackedStringArray) -> Dictionary:
	# Native reimport is synchronous but pumps frames for its progress dialog.
	# A paired pause preserves an existing outer pause instead of clearing it.
	if _connection != null:
		_connection.pause()
	# Some native importers return OK despite load/save errors (WAV in 4.7).
	# Validity alone can therefore describe the previous generated output.
	var buffer := McpEditorLogBuffer.new()
	var logger := preload("res://addons/godot_ai/runtime/validation_logger.gd").new(buffer)
	OS.add_logger(logger)
	efs.reimport_files(paths)
	OS.remove_logger(logger)
	if _connection != null:
		_connection.resume()
	var statuses := {}
	for path in paths:
		statuses[path] = _import_validity(path)
	var diagnostics: Array[Dictionary] = []
	for entry in buffer.get_recent(20):
		diagnostics.append({"level": entry.level, "text": entry.text.left(2048), "path": entry.path, "line": entry.line})
	return {"validity": statuses, "diagnostics": diagnostics, "error_count": buffer.error_appended_total()}


func reimport(params: Dictionary) -> Dictionary:
	var busy := _import_busy_error()
	if not busy.is_empty():
		return busy
	var paths: Array = params.get("paths", [])

	if paths.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: paths (non-empty array)")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

	var reimported: Array[String] = []
	var skipped_non_imported: Array[String] = []
	var not_found: Array[String] = []
	var imported_paths := PackedStringArray()

	for path_variant in paths:
		var path: String = str(path_variant)
		var path_err := McpPathValidator.validate_resource_path(path)
		if not path_err.is_empty():
			not_found.append("%s (%s)" % [path, path_err])
			continue
		if not FileAccess.file_exists(path):
			not_found.append("%s (file does not exist)" % path)
			continue
		if _is_imported_resource(path):
			reimported.append(path)
			imported_paths.append(path)
		else:
			## Non-imported resources still need their editor entry refreshed, but
			## `update_file()` is not an import and must not be reported as one.
			efs.update_file(path)
			skipped_non_imported.append(path)

	## `update_file()` is conditional: for an unchanged imported asset it can
	## return without running an importer, while the old response still claimed
	## success. `reimport_files()` is the editor API for an explicit forced
	## reimport, including unchanged sources and changed post-import scripts.
	## Batch once so the editor can settle the requested imports together.
	var imported := {"validity": {}, "diagnostics": [], "error_count": 0}
	var failed_imports: Array[String] = []
	var unconfirmed_imports: Array[String] = []
	if not imported_paths.is_empty():
		imported = _reimport_paths(efs, imported_paths)
		for path in imported_paths:
			if imported.validity[path] != true:
				reimported.erase(path)
				failed_imports.append(path)
			elif imported.error_count > 0:
				reimported.erase(path)
				unconfirmed_imports.append(path)

	var data := {
		"reimported": reimported,
		"failed_imports": failed_imports,
		"import_status": imported.validity,
		"unconfirmed_imports": unconfirmed_imports,
		"import_diagnostics": imported.diagnostics, "import_error_count": imported.error_count,
		"diagnostics_scope": "editor_during_reimport",
		"skipped_non_imported": skipped_non_imported,
		"not_found": not_found,
		"reimported_count": reimported.size(),
		"skipped_non_imported_count": skipped_non_imported.size(),
		"not_found_count": not_found.size(),
		"undoable": false,
		"reason": "Reimport is a file system operation",
	}
	## Only when it applies: a hint on every call would cost tokens on the
	## all-assets path this op is actually for.
	if not skipped_non_imported.is_empty():
		data["skipped_non_imported_hint"] = (
			"%d path(s) are not imported resources. Their editor filesystem entry was "
			+ "refreshed, but no import ran — a success here is not evidence that a "
			+ "script parsed or that diagnostics were produced. Use script_patch/"
			+ "script_create for GDScript diagnostics, or filesystem_manage(op=\"scan\") "
			+ "for an asset the editor has not imported yet."
		) % skipped_non_imported.size()
	return {"data": data}


## #778/#1147: `update_file()` registers a path with the resource pipeline; it
## only runs an *import* when Godot detects a changed imported resource.
## Scripts, scenes and hand-written
## `.tres` are not imported resources, so listing them under `reimported` reads
## as proof that a parse or import ran when nothing did.
##
## The `.import` sidecar is the editor's own record that a path goes through
## the import pipeline, so it decides the split. An extension allow-list was
## rejected: importers come and go with plugins, so the list would drift out of
## agreement with the editor it claims to describe.
##
## Known edge: an asset the editor has never imported (just written, no scan
## yet) has no sidecar and reports as non-imported. That is accurate at the
## moment of the call — `update_file()` did not import it either — and the
## hint names `scan` as the way through.
##
## Non-imported paths still receive `update_file()` because refreshing an
## externally-edited `.tscn`/`.tres` is a real use of this op. Imported paths
## go through `reimport_files()` so every entry under `reimported` corresponds
## to an explicit forced-import request rather than a conditional refresh.
static func _is_imported_resource(path: String) -> bool:
	if path.ends_with(IMPORT_SIDECAR_SUFFIX):
		return false  ## The sidecar itself is not an imported resource.
	return FileAccess.file_exists(path + IMPORT_SIDECAR_SUFFIX)


## A full scan makes newly authored resources visible to tools that reference
## them immediately afterward (#83). Completion must include native script
## registration and scan actions, not just the worker's filesystem discovery.
func scan_filesystem(params: Dictionary) -> Dictionary:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

	var request_id: String = params.get("_request_id", "")
	# Async path: a scan can't be awaited on the calling frame without freezing
	# the editor, so hand control back to the dispatcher (DEFERRED_RESPONSE) and
	# push the real reply from a static coroutine once the scan settles — by
	# which point new class_names are registered.
	if _connection != null and not request_id.is_empty():
		_finish_scan_deferred(_connection, request_id, efs)
		return McpDispatcher.DEFERRED_RESPONSE

	# Synchronous callers cannot await, but must share the same native lifecycle
	# barrier as deferred callers rather than allowing another scan to overlap.
	var already := _has_pending_scan() or efs.is_scanning()
	_get_or_start_scan(efs)
	return {
		"data": {
			"scan_completed": false,
			"scan_settle": "not_waited",
			"was_already_scanning": already,
			"global_class_count": ProjectSettings.get_global_class_list().size(),
			# Present in both paths for a consistent response shape; the sync
			# path doesn't await, so it can't measure a delta.
			"global_classes_registered_delta": 0,
			"undoable": false,
			"reason": "Filesystem scan is an editor operation",
		}
	}


static func _has_pending_scan() -> bool:
	return _active_scan != null and not _active_scan.accepted


static func _get_or_start_scan(efs: EditorFileSystem) -> ScanCompletion:
	if _has_pending_scan():
		return _active_scan

	var completion := ScanCompletion.new()
	completion.last_root_id = efs.get_filesystem().get_instance_id()
	_active_scan = completion
	# Connect before scan(): non-threaded scans may finish inside that call.
	# Observe the native boundary synchronously: an older deferred signal can
	# arrive during a newer scan. Keep listening when another scan is active.
	# A caller timeout must not permit plugin reload while native work is pending.
	var work := ScriptWork.begin("scan_filesystem")
	efs.sources_changed.connect(_on_scan_completed.bind(completion, work, efs))
	if efs.is_scanning():
		completion.required_root_changes = 2
	else:
		efs.scan()
		# scan() returns void and may decline a finished worker awaiting native
		# postprocessing. Two subsequent roots prove a post-request full scan:
		# native permits only one full-scan worker/root awaiting installation.
		if not completion.accepted and not efs.is_scanning() and efs.get_filesystem().get_instance_id() == completion.last_root_id:
			completion.required_root_changes = 2
	return completion


static func _on_scan_completed(_exist: bool, completion: ScanCompletion, work: int, efs: EditorFileSystem) -> void:
	var root_id := efs.get_filesystem().get_instance_id()
	if root_id != completion.last_root_id:
		completion.last_root_id = root_id
		completion.root_changes += 1
	if efs.is_scanning():
		return
	# Full scans replace the native root only when their main-thread processing
	# starts. An older signal cannot satisfy this even if our worker finished.
	if completion.root_changes < completion.required_root_changes:
		efs.scan()
		return
	completion.accepted = true
	efs.sources_changed.disconnect(_on_scan_completed.bind(completion, work, efs))
	# The accepted scan is complete even if a later listener starts another.
	# Leave this signal callback before releasing waiters or native-work ownership.
	_finish_scan_completion.call_deferred(completion, work)


static func _finish_scan_completion(completion: ScanCompletion, work: int) -> void:
	completion.completed = true
	ScriptWork.finish(work)


## `static` is load-bearing for the same reason as ScriptHandler's deferred
## finish: the coroutine must outlive the handler RefCounted, which can be freed
## mid-await (e.g. an editor_reload_plugin fired during the scan). Parameterise
## everything; reference no instance state.
static func _finish_scan_deferred(
	connection: McpConnection,
	request_id: String,
	efs: EditorFileSystem,
) -> void:
	var work := ScriptWork.begin("scan_filesystem")
	await _settle_scan(connection, request_id, efs)
	ScriptWork.finish(work)


static func _settle_scan(
	connection: McpConnection, request_id: String, efs: EditorFileSystem,
) -> void:
	if not is_instance_valid(connection):
		return
	var tree := connection.get_tree()
	if tree == null:
		return
	var classes_before := ProjectSettings.get_global_class_list().size()
	var was_already_scanning := _has_pending_scan() or efs.is_scanning()
	var deadline_ms := Time.get_ticks_msec() + _SCAN_SETTLE_MAX_MSEC
	var completion := _get_or_start_scan(efs)
	# Hand back a frame so _dispatch() registers this request as deferred before
	# the coroutine can push a reply (mirrors McpResourceIO.finish_text_write_deferred).
	await tree.process_frame
	while not completion.completed and Time.get_ticks_msec() < deadline_ms:
		if not is_instance_valid(connection):
			return
		await tree.process_frame
	if not is_instance_valid(connection):
		return
	var completed := completion.completed
	var classes_after := ProjectSettings.get_global_class_list().size()
	connection.send_deferred_response(request_id, {
		"data": {
			"scan_completed": completed,
			"scan_settle": "settled" if completed else "timeout",
			"was_already_scanning": was_already_scanning,
			"global_class_count": classes_after,
			"global_classes_registered_delta": classes_after - classes_before,
			"undoable": false,
			"reason": "Filesystem scan is an editor operation",
		}
	})


## Resource-group mutations use read-only deferred discovery before disk effects.
const Mutation := preload("res://addons/godot_ai/handlers/filesystem_mutation.gd")


func move_file(params: Dictionary) -> Dictionary:
	return Mutation.start(_connection, params, "move")


func rename_file(params: Dictionary) -> Dictionary:
	return Mutation.start(_connection, params, "rename")


func remove_file(params: Dictionary) -> Dictionary:
	return Mutation.start(_connection, params, "remove")
