@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles project settings and filesystem search commands.

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const RUN_READY_WAIT_SEC := 3.0

var _connection: McpConnection
var _debugger_plugin
var _editor_log_buffer


func _init(connection: McpConnection = null, debugger_plugin = null, editor_log_buffer = null) -> void:
	_connection = connection
	_debugger_plugin = debugger_plugin
	_editor_log_buffer = editor_log_buffer


func get_project_setting(params: Dictionary) -> Dictionary:
	var key: String = params.get("key", "")
	if key.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: key")

	if not ProjectSettings.has_setting(key):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Setting not found: %s" % key)

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
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: key")

	if not params.has("value"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: value")

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
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to save project settings (error %d)" % err)

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
	var autosave: bool = params.get("autosave", true)
	# Idempotent: a project that's already running satisfies the caller's intent.
	# Returning INVALID_PARAMS here punished agents that legitimately called run
	# to ensure the project is playing (87+ installs/day hit the matching
	# stop-not-running case in telemetry). Surface state via was_already_running
	# so a caller wanting a *different* scene can detect and stop+restart.
	if EditorInterface.is_playing_scene():
		return _run_project_current_liveness_response(
			_run_project_base_data(
				mode,
				str(params.get("scene", "")),
				autosave,
				true,
				"Project was already running; no action taken"
			)
		)

	var validation_error: Variant = null
	if mode == "custom":
		var custom_scene: String = params.get("scene", "")
		if custom_scene.is_empty():
			validation_error = ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: scene (required when mode='custom')")
	elif mode != "main" and mode != "current":
		validation_error = ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid mode '%s' — use 'main', 'current', or 'custom'" % mode)
	if validation_error != null:
		return validation_error

	# play_*_scene internally triggers try_autosave() → _save_scene_with_preview()
	# which renders a preview thumbnail and calls frame processing. If our
	# WebSocket connection's _process() re-enters during that render, the
	# engine crashes (SIGABRT in _save_scene_with_preview). Pause processing
	# around the play call — same pattern as SceneHandler.save_scene.
	if _connection:
		_connection.pause_processing = true

	# try_autosave() reads run/auto_save/save_before_running every call, so
	# toggling it off around the play call suppresses the save without
	# touching the user's persisted preference. Issue #81.
	var autosave_key := "run/auto_save/save_before_running"
	var editor_settings: EditorSettings = null
	if not autosave:
		editor_settings = EditorInterface.get_editor_settings()
	var prior_autosave: bool = true
	var restore_setting := false
	if editor_settings != null and editor_settings.has_setting(autosave_key):
		prior_autosave = bool(editor_settings.get_setting(autosave_key))
		editor_settings.set_setting(autosave_key, false)
		restore_setting = true

	if _debugger_plugin != null:
		_debugger_plugin.begin_game_run(_editor_log_cursor(), _game_helper_autoload_expected())

	match mode:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		"custom":
			var scene_path: String = params.get("scene", "")
			EditorInterface.play_custom_scene(scene_path)

	if restore_setting:
		editor_settings.set_setting(autosave_key, prior_autosave)

	if _connection:
		_connection.pause_processing = false

	var base_data := _run_project_base_data(
		mode,
		str(params.get("scene", "")),
		autosave,
		false,
		"Play/stop is a runtime action"
	)
	var request_id: String = params.get("_request_id", "")
	if _connection != null and _debugger_plugin != null and not request_id.is_empty():
		_finish_run_project_deferred(request_id, base_data, _connection, _debugger_plugin)
		return McpDispatcher.DEFERRED_RESPONSE

	return _run_project_current_liveness_response(base_data)


func _editor_log_cursor() -> int:
	return _editor_log_buffer.appended_total() if _editor_log_buffer != null else 0


func _game_helper_autoload_expected() -> bool:
	return ProjectSettings.has_setting("autoload/_mcp_game_helper")


static func _run_project_base_data(
	mode: String,
	scene: String,
	autosave: bool,
	was_already_running: bool,
	reason: String
) -> Dictionary:
	return {
		"mode": mode,
		"scene": scene,
		"autosave": autosave,
		"was_already_running": was_already_running,
		"undoable": false,
		"reason": reason,
	}


func _run_project_current_liveness_response(base_data: Dictionary) -> Dictionary:
	if _debugger_plugin == null:
		return {"data": base_data}
	var status: Dictionary = _debugger_plugin.get_game_status(-1, RUN_READY_WAIT_SEC)
	## One-shot read — force a Debugger-tab scan so boot errors that landed
	## after the last gated scan are in this response (#641).
	var errors_info: Dictionary = _debugger_plugin.recent_editor_errors_since(int(status.get("editor_log_cursor", 0)), true)
	return _run_project_response(base_data, _run_project_liveness_decision(status, errors_info))


## `static` is load-bearing (#712, same rationale as the script/filesystem
## handlers and editor_handler._do_reload_plugin): this coroutine awaits
## across frames, and a plugin reload frees this RefCounted handler
## mid-await — resuming an instance coroutine on a freed object errors.
## `connection` and `debugger_plugin` are parameterized explicitly and
## re-validated after every await; the response is dropped silently when
## either died (the server's command timeout surfaces the failure).
static func _finish_run_project_deferred(
	request_id: String, base_data: Dictionary, connection, debugger_plugin
) -> void:
	var tree: SceneTree = connection.get_tree()
	while true:
		await tree.process_frame
		if not is_instance_valid(connection) or not is_instance_valid(debugger_plugin):
			return
		var pre_status: Dictionary = debugger_plugin.get_game_status(-1, RUN_READY_WAIT_SEC)
		if (
			not EditorInterface.is_playing_scene()
			and int(pre_status.get("elapsed_msec", 0)) > 100
			and str(pre_status.get("status", "stopped")) == "launching"
		):
			debugger_plugin.end_game_run()
		var status: Dictionary = debugger_plugin.get_game_status(-1, RUN_READY_WAIT_SEC)
		var errors_info: Dictionary = debugger_plugin.recent_editor_errors_since(int(status.get("editor_log_cursor", 0)))
		var decision := _run_project_liveness_decision(status, errors_info)
		if not bool(decision.get("resolve", false)):
			continue
		## #641: the loop above polls with gated (cheap) scans; boot parse
		## errors can land in the Errors tab in the same frames the run goes
		## live. Re-gather once with a forced scan before replying so the
		## response reports them instead of leaving them to a later
		## logs_read. Rebuilding the decision with strictly-more errors can
		## only keep it resolved (errors never un-resolve a decision).
		errors_info = debugger_plugin.recent_editor_errors_since(int(status.get("editor_log_cursor", 0)), true)
		decision = _run_project_liveness_decision(status, errors_info)
		connection.send_deferred_response(request_id, _run_project_response(base_data, decision))
		return


static func _run_project_response(base_data: Dictionary, decision: Dictionary) -> Dictionary:
	var data := base_data.duplicate(true)
	var game_status: Dictionary = decision.get("game_status", {})
	data["game_status"] = game_status
	data["helper_live"] = bool(game_status.get("helper_live", false))
	data["session_active"] = bool(game_status.get("session_active", false))
	if bool(data.get("was_already_running", false)):
		data["reason"] = _run_project_already_running_message(decision)
	else:
		data["reason"] = decision.get("message", data.get("reason", "Play/stop is a runtime action"))
	data["recent_errors"] = decision.get("recent_errors", [])
	data["recent_errors_scope"] = decision.get("recent_errors_scope", "none")
	data["recent_errors_may_predate_run"] = decision.get("recent_errors_may_predate_run", false)
	data["recent_errors_truncated"] = decision.get("recent_errors_truncated", false)
	data.merge(McpDebuggerPlugin.split_errors_by_scope(data["recent_errors"], data["recent_errors_scope"]), true)
	return {"data": data}


static func _run_project_already_running_message(decision: Dictionary) -> String:
	var state := str(decision.get("liveness_status", "unknown"))
	match state:
		"live":
			var live_errors: Array = decision.get("recent_errors", [])
			if not live_errors.is_empty() and str(decision.get("recent_errors_scope", "none")) == "run":
				return (
					"Project was already running; the Godot AI game helper is live, but %d editor error%s surfaced during this run (first: %s). Check logs_read(source='editor', include_details=true)."
					% [live_errors.size(), "s" if live_errors.size() != 1 else "", _format_editor_error_summary(live_errors[0])]
				)
			return "Project was already running; the Godot AI game helper is live."
		"not_live":
			var errors: Array = decision.get("recent_errors", [])
			var scope := str(decision.get("recent_errors_scope", "none"))
			if not errors.is_empty() and scope == "run":
				return "Project was already running but failed to load before the Godot AI game helper registered: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(errors[0])
			if not errors.is_empty():
				return "Project was already running but is not responding. A recent editor error may be related, but may predate this run: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(errors[0])
			return "Project was already running but did not become live before the helper-ready window elapsed. Check logs_read(source='editor', include_details=true) and poll editor_state."
		"break":
			var break_errors: Array = decision.get("recent_errors", [])
			if not break_errors.is_empty() and str(decision.get("recent_errors_scope", "none")) == "run":
				return "Project was already running but the game is parked at a debugger break: %s. Call project_manage(op='stop') to end the run, fix the error, and relaunch." % _format_editor_error_summary(break_errors[0])
			if not break_errors.is_empty():
				return "Project was already running but the game is parked at a debugger break. A recent editor error may be related, but may predate this run: %s. Call project_manage(op='stop') to end the run." % _format_editor_error_summary(break_errors[0])
			return "Project was already running but the game is parked at a debugger break. Call project_manage(op='stop') to end the run; the break reason is in the editor's Debugger panel."
		"no_helper":
			return "Project was already running, but no _mcp_game_helper autoload is expected. Headless or custom-main-loop projects cannot confirm helper liveness."
		"launching":
			return "Project was already running and is still waiting for the Godot AI game helper to register. Poll editor_state shortly."
		"stopped":
			return "Project was already marked playing by the editor, but no active game liveness run exists."
		_:
			return "Project was already running; current liveness status is %s." % state


## Static (with the rest of the deferred-finisher chain) so the #712
## load-bearing-static coroutines above can call it after their owner
## handler was freed. Uses no instance state.
static func _run_project_liveness_decision(status: Dictionary, errors_info: Dictionary = {}) -> Dictionary:
	var enriched_status := McpDebuggerPlugin.with_liveness_flags(status)
	var state := str(status.get("status", "stopped"))
	var recent_errors: Array = errors_info.get("errors", [])
	var errors_scope := str(errors_info.get("scope", "none"))
	var truncated := bool(errors_info.get("truncated", false))
	## Clear errors that predate this run's window — they don't belong in
	## a successful launch response and only add noise. They remain
	## reachable via logs_read(source='editor') and the retained buffer so
	## failed-run debugging is unaffected.
	## #635 tradeoff: a genuine in-run error whose Errors-tab row carries
	## an empty or byte-identical time text can be misclassified as
	## retained_recent and will be dropped here. Still reachable via
	## logs_read.
	if state == "live" and errors_scope == "retained_recent":
		recent_errors = []
		errors_scope = "none"
	var correlated_error := not recent_errors.is_empty() and errors_scope == "run"
	var elapsed_msec := int(status.get("elapsed_msec", 0))
	var ready_wait_msec := int(status.get("ready_wait_msec", int(RUN_READY_WAIT_SEC * 1000.0)))
	var decision := {
		"resolve": false,
		"game_status": enriched_status,
		"liveness_status": state,
		"recent_errors": recent_errors,
		"recent_errors_scope": errors_scope,
		"recent_errors_may_predate_run": errors_scope == "retained_recent",
		"recent_errors_truncated": truncated,
		"message": "",
	}
	if state == "live":
		decision["resolve"] = true
		if correlated_error:
			## #641: "live" only means the helper autoload registered — scripts
			## can still have failed to parse or load during boot (a broken
			## node script does not stop the game from running). Surface those
			## errors in the success message so agents don't read a clean
			## launch into a run that silently lost scripts.
			decision["message"] = (
				"Game launched and the Godot AI game helper is live, but %d editor error%s surfaced during startup (first: %s) — likely a script that failed to parse or load. Check logs_read(source='editor', include_details=true)."
				% [recent_errors.size(), "s" if recent_errors.size() != 1 else "", _format_editor_error_summary(recent_errors[0])]
			)
			if truncated:
				decision["message"] += " Editor logs since this run may be truncated; showing retained errors."
		else:
			decision["message"] = "Game launched and the Godot AI game helper is live."
	elif state == "break":
		## #645: the game process is parked in a remote-debugger break. A
		## boot-time parse error (GDScriptLanguage::debug_break_parse) produces
		## no Errors-tab row, no Logger entry, and no game-log line — the
		## synthesized break record is the only evidence, and it lands a
		## moment after the break signal (stack frames arrive async). Wait for
		## it (correlated_error) before resolving; the ready window is the
		## fallback if synthesis never lands.
		var break_info: Dictionary = status.get("break", {})
		var break_reason := str(break_info.get("reason", ""))
		if bool(break_info.get("pre_live", true)):
			decision["resolve"] = correlated_error or elapsed_msec >= ready_wait_msec
			var summary := break_reason
			if correlated_error:
				summary = _format_editor_error_summary(recent_errors[0])
			if summary.is_empty():
				summary = "script parse/load error (reason not captured)"
			decision["message"] = "Game hit a script error during startup and is frozen at a debugger break before the Godot AI game helper registered: %s. The run cannot continue; call project_manage(op='stop'), fix the error, and relaunch. Check logs_read(source='editor', include_details=true)." % summary
		else:
			var reason_suffix := (": %s" % break_reason) if not break_reason.is_empty() else ""
			decision["resolve"] = true
			decision["message"] = "Game is paused at a debugger break%s. Resume it from the editor's Debugger panel or call project_manage(op='stop')." % reason_suffix
	elif correlated_error:
		decision["resolve"] = true
		decision["liveness_status"] = "not_live"
		decision["message"] = "Game launched but failed to load before the Godot AI game helper registered: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(recent_errors[0])
		if truncated:
			decision["message"] += " Editor logs since this run may be truncated; showing retained errors."
	elif state == "not_live":
		decision["resolve"] = true
		if not recent_errors.is_empty():
			decision["message"] = "Game launched but is not responding. A recent editor error may be related, but may predate this run: %s. Check logs_read(source='editor', include_details=true)." % _format_editor_error_summary(recent_errors[0])
		else:
			decision["message"] = "Game launched but did not become live before the helper-ready window elapsed. It may still be booting or may have failed silently; check logs_read(source='editor', include_details=true) and poll editor_state."
	elif state == "no_helper":
		decision["resolve"] = true
		decision["message"] = "Game launched, but no _mcp_game_helper autoload is expected. Headless or custom-main-loop projects cannot confirm helper liveness; use editor_state and viewport/editor tools where applicable."
	elif state == "stopped":
		decision["resolve"] = true
		decision["message"] = "The play session stopped, or no active game liveness run exists, before the Godot AI game helper became live."
	elif state == "launching" and elapsed_msec >= ready_wait_msec:
		decision["resolve"] = true
		decision["message"] = "Game launched but is not yet live after %.1fs; it may still be booting. Poll editor_state and check logs_read(source='editor', include_details=true)." % (float(elapsed_msec) / 1000.0)
	return decision


static func _format_editor_error_summary(entry: Dictionary) -> String:
	return McpSurfacedErrorTracker.format_editor_error_summary(entry)


func stop_project(params: Dictionary) -> Dictionary:
	# Idempotent: a project that's already stopped satisfies the caller's intent.
	# Returning INVALID_PARAMS here was the largest single source of fleet-wide
	# project_manage failures (87 installs/24h). was_running=false lets callers
	# distinguish a no-op stop from one that actually halted a running session.
	if not EditorInterface.is_playing_scene():
		return {
			"data": {
				"stopped": true,
				"was_running": false,
				"undoable": false,
				"reason": "Project was not running; no action taken",
			}
		}

	if _debugger_plugin != null:
		_debugger_plugin.end_game_run()
	EditorInterface.stop_playing_scene()

	# stop_playing_scene() is async — is_playing_scene() only flips to false on
	# the next frame, and readiness_changed follows in _process. Defer the
	# response so we can reply with authoritative readiness instead of letting
	# the server poll for the event. Issue #29.
	var request_id: String = params.get("_request_id", "")
	if _connection != null and not request_id.is_empty():
		_finish_stop_project_deferred(request_id, _connection)
		return McpDispatcher.DEFERRED_RESPONSE

	# Fallback for contexts without a connection (e.g. batch_execute via
	# dispatch_direct, or unit tests that instantiate the handler with null).
	return {
		"data": {
			"stopped": true,
			"was_running": true,
			"undoable": false,
			"reason": "Play/stop is a runtime action",
		}
	}


# Wait two frames so Godot can tick the stop-play state change. After this
# is_playing_scene() reflects truth and get_readiness() is authoritative.
# If the plugin tears down (_exit_tree frees _connection) during the await,
# is_instance_valid() goes false and we drop the response silently — the
# server's 5s request timeout will surface the failure to the caller.
# `static` is load-bearing (#712): see _finish_run_project_deferred.
static func _finish_stop_project_deferred(request_id: String, connection) -> void:
	var tree: SceneTree = connection.get_tree()
	await tree.process_frame
	await tree.process_frame
	if not is_instance_valid(connection):
		return
	connection.send_deferred_response(request_id, {
		"data": {
			"stopped": true,
			"was_running": true,
			"undoable": false,
			"reason": "Play/stop is a runtime action",
			"readiness_after": McpConnection.get_readiness(),
		}
	})


func search_filesystem(params: Dictionary) -> Dictionary:
	var name_filter: String = params.get("name", "")
	var type_filter: String = params.get("type", "")
	var path_filter: String = params.get("path", "")

	if name_filter.is_empty() and type_filter.is_empty() and path_filter.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "At least one filter (name, type, path) is required")

	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return ErrorCodes.make_not_ready(
			ErrorCodes.SUB_EDITOR_UNAVAILABLE,
			"EditorFileSystem not available", false)

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
