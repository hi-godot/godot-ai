@tool
extends Node

## Plugin-lifetime owner for every background client-configuration job.
##
## The Dock is replaceable UI. Threads cannot share that lifetime: a timed-out
## probe or package pre-warm can outlive the panel that requested it, and
## destroying a live Godot Thread corrupts the GDScript VM. This node therefore
## owns both worker pools, their cancellation, phases, and one action slot per
## client until its Thread has been joined. It publishes copied value snapshots
## and outcomes; it never retains the Dock, plugin, lifecycle, or update manager.

const Client := preload("res://addons/godot_ai/clients/_base.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const ClientRegistry := preload("res://addons/godot_ai/clients/_registry.gd")
const JsonStrategy := preload("res://addons/godot_ai/clients/_json_strategy.gd")
const TomlStrategy := preload("res://addons/godot_ai/clients/_toml_strategy.gd")
const DshStrategy := preload("res://addons/godot_ai/clients/_dsh_strategy.gd")
const CliStrategy := preload("res://addons/godot_ai/clients/_cli_strategy.gd")
const RefreshState := preload("res://addons/godot_ai/utils/mcp_client_refresh_state.gd")
const MutationLock := preload("res://addons/godot_ai/utils/client_mutation_lock.gd")

const STATUS_COOLDOWN_MSEC := 15 * 1000
const STATUS_TIMEOUT_MSEC := 30 * 1000
## One scoped CLI configure may run three bounded cleanup commands, one write,
## discovery, and read-back verification before it reaches the optional package
## prewarm. Keep the owner watchdog above that real mutation budget.
const ACTION_TIMEOUT_MSEC := 75 * 1000
const MCP_ACTION_DEFERRED_GRACE_MSEC := 5 * 1000
const MAX_MCP_STATUS_WAITERS := 64
const PHASE_PREWARM := "prewarm"
const MUTATION_UNPROVEN_META := &"_godot_ai_client_mutation_termination_unproven"
const POST_UPDATE_UNPROVEN_META := &"_godot_ai_post_update_termination_unproven"

signal snapshot_changed(snapshot: Dictionary)
signal status_refresh_completed(results: Dictionary)
signal mcp_status_completed(request_ids: Array[String], payload: Dictionary)
signal mcp_action_completed(request_id: String, payload: Dictionary)
signal post_update_repin_completed(result: Dictionary)
signal action_completed(client_id: String, action: String, result: Dictionary, prewarm: Dictionary)
signal action_timed_out(client_id: String, action: String, detail: String)

var _accepting_work := false
var _client_health_blocked := false
var _client_ids: Array[String] = []

var _refresh_thread: Thread
var _refresh_state := RefreshState.IDLE
var _refresh_pending := false
var _refresh_pending_force := false
var _refresh_completed_msec := 0
var _refresh_started_msec := 0
var _refresh_generation := 0
## request_id -> first refresh generation allowed to answer it. An MCP request
## arriving behind a partial Dock refresh waits for the coalesced all-client
## retry instead of accepting the partial result.
var _mcp_status_waiters: Dictionary = {}

var _action_threads: Dictionary = {}
var _action_started_msec: Dictionary = {}
var _action_names: Dictionary = {}
var _action_request_ids: Dictionary = {}
var _action_timeout_reported: Dictionary = {}
var _action_phase_mutex := Mutex.new()
var _action_phases: Dictionary = {}
var _action_cancel_mutex := Mutex.new()
var _action_cancelled: Dictionary = {}
## client_id -> action whose CLI termination could not be proven. Mirrored into
## process-lifetime Engine metadata for immediate reload safety; the CLI
## strategy's global lock directory is the durable cross-restart authority.
var _mutation_termination_unproven: Dictionary = {}
## A successful update enters one pre-activation migration job. It is owned and
## joined here like every other client worker, while ordinary Dock/MCP work
## remains closed and the server lifecycle stays dormant.
var _post_update_thread: Thread
var _post_update_generation := 0
var _post_update_cancel_mutex := Mutex.new()
var _post_update_cancelled := false
var _post_update_termination_unproven := false
var _last_snapshot: Dictionary = {}


func _init() -> void:
	var mutations: Variant = Engine.get_meta(MUTATION_UNPROVEN_META, {})
	if mutations is Dictionary:
		_mutation_termination_unproven = (mutations as Dictionary).duplicate(true)
	_post_update_termination_unproven = bool(
		Engine.get_meta(POST_UPDATE_UNPROVEN_META, false)
	)


func _ready() -> void:
	## Work can start before this node is ready: the plugin begins post-update
	## client migration while it is still entering the tree, and this callback
	## runs after that. Idle only when nothing is in flight; becoming ready
	## must never cancel the poll for a thread that is already running.
	set_process(_has_work_in_flight())


func _has_work_in_flight() -> bool:
	return _post_update_thread != null or _refresh_thread != null or not _action_threads.is_empty()


## Construction is inert. The composition root calls activate only after its
## startup barrier has allowed normal client work.
func activate() -> void:
	if _refresh_state == RefreshState.SHUTTING_DOWN or _post_update_thread != null:
		return
	_accepting_work = true
	set_process(true)
	_publish_snapshot()
	_retry_deferred_refresh()


func set_client_health_blocked(blocked: bool) -> void:
	_client_health_blocked = blocked
	if not blocked:
		_retry_deferred_refresh()


func snapshot() -> Dictionary:
	var busy: Array[String] = []
	for client_id in _action_threads:
		busy.append(String(client_id))
	busy.sort()
	return {
		"accepting_work": _accepting_work,
		"refresh_state": _refresh_state,
		"refresh_completed": _refresh_completed_msec > 0,
		"post_update_repin_running": _post_update_thread != null,
		"busy_actions": busy,
		"action_names": _action_names.duplicate(true),
		"action_phases": _read_action_phases(),
	}


func _publish_snapshot() -> void:
	var value := snapshot()
	if value == _last_snapshot:
		return
	_last_snapshot = value.duplicate(true)
	snapshot_changed.emit(value)


func _process(_delta: float) -> void:
	_poll_post_update_repin()
	_poll_refresh()
	_poll_actions()
	_check_refresh_timeout()
	_check_action_timeouts()
	_retry_deferred_refresh()


## Stop accepting work, cooperatively cancel action subprocesses, then realize
## every Thread before scripts can be overwritten. Godot exposes no timed join;
## deadline_msec is reported honestly rather than pretending the join can be
## interrupted without risking VM corruption.
func quiesce(deadline_msec: int = 0) -> Dictionary:
	_accepting_work = false
	_refresh_state = RefreshState.SHUTTING_DOWN
	_publish_snapshot()
	for client_id in _action_threads:
		_set_action_cancelled(String(client_id), true)
	_set_post_update_cancelled(true)
	_refresh_generation += 1
	if _refresh_thread != null:
		_refresh_thread.wait_to_finish()
		_refresh_thread = null
	if _post_update_thread != null:
		_record_unproven_post_update_result(_post_update_thread.wait_to_finish())
		_post_update_thread = null
	for thread in _action_threads.values():
		if thread != null:
			_record_unproven_action_payload((thread as Thread).wait_to_finish())
	_action_threads.clear()
	_action_started_msec.clear()
	_action_names.clear()
	_action_request_ids.clear()
	_action_timeout_reported.clear()
	_action_phase_mutex.lock()
	_action_phases.clear()
	_action_phase_mutex.unlock()
	_action_cancel_mutex.lock()
	_action_cancelled.clear()
	_action_cancel_mutex.unlock()
	_refresh_pending = false
	_refresh_pending_force = false
	_mcp_status_waiters.clear()
	set_process(false)
	_publish_snapshot()
	var termination_unproven := (
		_post_update_termination_unproven
		or not _mutation_termination_unproven.is_empty()
		or MutationLock.is_locked()
	)
	return {
		"ok": not termination_unproven,
		"deadline_exceeded": deadline_msec > 0 and Time.get_ticks_msec() > deadline_msec,
		"termination_unproven": termination_unproven,
	}


## Re-open the same owner after a pre-activation update failure. Successful
## activation tears down the plugin instead, so this is only a bail-out path.
func resume_after_quiesce() -> void:
	if _refresh_state != RefreshState.SHUTTING_DOWN:
		return
	_refresh_state = RefreshState.IDLE
	_set_post_update_cancelled(false)
	activate()


## Start the hard post-update client barrier. The signed transaction outcome
## supplies both versions; a mismatch with the code actually loaded fails
## closed before touching client config or starting the server.
func begin_post_update_repin(
	from_version: String, to_version: String, replace_owned_mismatches: bool = false
) -> Dictionary:
	## `from_version` is empty when the closed-editor installer put v4 into a
	## project that had no add-on: nothing was replaced, and owned client
	## entries still repin to the installed version on this first start.
	var replaced := from_version.strip_edges()
	var installed := to_version.strip_edges()
	if installed.is_empty():
		return {"ok": false, "error": "Post-update target version is missing."}
	if installed != ClientConfigurator.get_plugin_version():
		return {"ok": false, "error": "Post-update target does not match the loaded plugin."}
	if MutationLock.is_locked():
		return {"ok": false, "error": MutationLock.recovery_message()}
	if _post_update_termination_unproven or not _mutation_termination_unproven.is_empty():
		return {"ok": false, "error": MutationLock.recovery_message()}
	if (
		_accepting_work
		or _post_update_thread != null
		or _refresh_thread != null
		or not _action_threads.is_empty()
		or _refresh_state == RefreshState.SHUTTING_DOWN
	):
		return {"ok": false, "error": "Client work is not idle for post-update migration."}
	ClientConfigurator.warm_env_snapshot()
	_warm_worker_bytecode()
	var probes: Array[Dictionary] = []
	for client_id in ClientConfigurator.client_ids():
		var probe := ClientConfigurator.client_status_probe_snapshot(client_id)
		## Manual-only descriptors remain visible in ordinary status UI, but M6
		## cannot safely parse or rewrite them. In particular Zed owns JSONC and
		## may contain comments that the strict shared JSON parser must reject.
		## Keep manual remediation outside the hard startup barrier.
		if not probe.is_empty() and bool(probe.get("automatic_config_edits", true)):
			probes.append(probe)
	var context := ClientConfigurator.capture_launch_context()
	if context.is_empty():
		return {"ok": false, "error": "Post-update launch context is unavailable."}
	_set_post_update_cancelled(false)
	_post_update_generation += 1
	_post_update_thread = Thread.new()
	var start_error := _post_update_thread.start(
		Callable(self, "_run_post_update_repin").bind(
			probes,
			context,
			replaced,
			installed,
			replace_owned_mismatches,
			_post_update_generation,
		)
	)
	if start_error != OK:
		_post_update_thread = null
		return {"ok": false, "error": "Could not start post-update client migration."}
	set_process(true)
	_publish_snapshot()
	return {"ok": true}


func _run_post_update_repin(
	probes: Array[Dictionary],
	context: Dictionary,
	from_version: String,
	to_version: String,
	replace_owned_mismatches: bool,
	generation: int,
) -> Dictionary:
	var prewarm := ClientConfigurator.prewarm_server_package_blocking(
		to_version,
		ClientConfigurator.PREWARM_TIMEOUT_MS,
		Callable(self, "_is_post_update_cancelled"),
	)
	var configured_ids: Array[String] = []
	var repinned_ids: Array[String] = []
	var foreign_ids: Array[String] = []
	if bool(prewarm.get("termination_failed", false)):
		return _post_update_result(
			false,
			generation,
			configured_ids,
			repinned_ids,
			"Post-update package pre-warm could not be proven stopped; stop relevant uvx processes or reboot before retrying.",
			prewarm,
			true,
		)
	var server_url := ClientConfigurator.server_url_from(context)
	var resolved_launch := ClientConfigurator.resolve_attach_launch(context)
	for probe in probes:
		if _is_post_update_cancelled():
			return _post_update_result(false, generation, configured_ids, repinned_ids,
				"Post-update client migration was cancelled.", prewarm)
		var client_id := String(probe.get("id", ""))
		var details := ClientConfigurator.check_status_details_for_url_with_cli_path(
			client_id,
			server_url,
			String(probe.get("cli_path", "")),
			context,
			resolved_launch,
		)
		var status := int(details.get("status", Client.Status.ERROR))
		if status == Client.Status.NOT_CONFIGURED:
			continue
		if status == Client.Status.ERROR:
			return _post_update_result(false, generation, configured_ids, repinned_ids,
				"%s status failed: %s" % [client_id, str(details.get("error_msg", "unknown error"))], prewarm)
		if status == Client.Status.CONFIGURED:
			configured_ids.append(client_id)
			continue
		if replace_owned_mismatches:
			## A major migration rewrites only entries that launch Godot AI.
			## An entry under our name that starts something else is the
			## user's own server: leave it, name it, let Configure replace it.
			if not bool(details.get("owned", false)):
				foreign_ids.append(client_id)
				continue
		elif not ClientConfigurator.entry_drift_is_version_pin_only(
			client_id, from_version, context
		):
			return _post_update_result(false, generation, configured_ids, repinned_ids,
				"%s has non-version configuration drift; automatic migration refused." % client_id, prewarm)
		var configured := ClientConfigurator.configure(client_id, server_url, context)
		if str(configured.get("status", "error")) != "ok":
			return _post_update_result(false, generation, configured_ids, repinned_ids,
				"%s repin failed: %s" % [client_id, str(configured.get("message", "unknown error"))],
				prewarm,
				bool(configured.get("termination_failed", false)),
				client_id)
		var verified := ClientConfigurator.check_status_details_for_url_with_cli_path(
			client_id,
			server_url,
			String(probe.get("cli_path", "")),
			context,
			resolved_launch,
		)
		if int(verified.get("status", Client.Status.ERROR)) != Client.Status.CONFIGURED:
			return _post_update_result(false, generation, configured_ids, repinned_ids,
				"%s repin could not be verified." % client_id, prewarm)
		configured_ids.append(client_id)
		repinned_ids.append(client_id)
	configured_ids.sort()
	repinned_ids.sort()
	foreign_ids.sort()
	return _post_update_result(
		true, generation, configured_ids, repinned_ids, "", prewarm, false, "", foreign_ids
	)


static func _post_update_result(
	ok: bool,
	generation: int,
	configured_ids: Array[String],
	repinned_ids: Array[String],
	error: String,
	prewarm: Dictionary,
	termination_failed: bool = false,
	unsafe_client_id: String = "",
	foreign_ids: Array[String] = [],
) -> Dictionary:
	return {
		"ok": ok,
		"generation": generation,
		"configured_ids": configured_ids.duplicate(),
		"repinned_ids": repinned_ids.duplicate(),
		"error": error,
		"prewarm": prewarm.duplicate(true),
		"termination_failed": termination_failed,
		"unsafe_client_id": unsafe_client_id,
		## Entries under our name that launch something else; left unchanged.
		"foreign_ids": foreign_ids.duplicate(),
	}


func _poll_post_update_repin() -> void:
	if _post_update_thread == null or _post_update_thread.is_alive():
		return
	var payload: Variant = _post_update_thread.wait_to_finish()
	_post_update_thread = null
	if _refresh_state == RefreshState.SHUTTING_DOWN:
		return
	var result: Dictionary = (
		(payload as Dictionary).duplicate(true)
		if payload is Dictionary
		else {"ok": false, "error": "Post-update client migration returned no result."}
	)
	_record_unproven_post_update_result(result)
	if int(result.get("generation", -1)) != _post_update_generation:
		return
	post_update_repin_completed.emit(result)
	_publish_snapshot()


func request_action(client_id: String, action: String) -> bool:
	var started := _start_action(client_id, action, "")
	if not bool(started.get("ok", false)) and bool(started.get("termination_failed", false)):
		action_completed.emit(
			client_id,
			action,
			{
				"status": "error",
				"message": str(started.get("error", "Client action is unavailable.")),
				"termination_failed": true,
			},
			{},
		)
	return bool(started.get("ok", false))


## MCP mutations use the same one-slot owner as Dock actions. They preserve the
## tool's previous mutation-only behavior: package prewarm remains a Dock-only
## convenience. The returned timeout is the bounded out-of-band reply budget.
func request_mcp_action(request_id: String, client_id: String, action: String) -> Dictionary:
	if request_id.is_empty():
		return {"ok": false, "error": "Client mutation requires a deferred request context."}
	return _start_action(client_id, action, request_id)


func _start_action(client_id: String, action: String, request_id: String) -> Dictionary:
	if not _accepting_work:
		return {"ok": false, "error": "Client worker is unavailable."}
	if action not in ["configure", "remove"]:
		return {"ok": false, "error": "Unknown client action: %s" % action}
	if _mutation_termination_unproven.has(client_id):
		return {
			"ok": false,
			"error": MutationLock.recovery_message(),
			"termination_failed": true,
		}
	if _action_threads.has(client_id):
		return {"ok": false, "error": "A client action is already running for %s." % client_id}
	if not ClientConfigurator.has_client(client_id):
		return {"ok": false, "error": "Unknown client: %s" % client_id}
	ClientConfigurator.warm_env_snapshot()
	_set_action_cancelled(client_id, false)
	_clear_action_phase(client_id)
	var context := ClientConfigurator.capture_launch_context()
	_action_names[client_id] = action
	_action_request_ids[client_id] = request_id
	_action_timeout_reported.erase(client_id)
	_action_started_msec[client_id] = Time.get_ticks_msec()
	var thread := Thread.new()
	_action_threads[client_id] = thread
	var error := thread.start(
		Callable(self, "_run_action").bind(
			client_id,
			action,
			ClientConfigurator.server_url_from(context),
			context,
			request_id.is_empty(),
		)
	)
	if error != OK:
		_action_threads.erase(client_id)
		_action_started_msec.erase(client_id)
		_action_names.erase(client_id)
		_action_request_ids.erase(client_id)
		return {"ok": false, "error": "Could not start client worker thread."}
	_publish_snapshot()
	return {
		"ok": true,
		"deferred_timeout_ms": _mcp_action_deferred_timeout_msec(action),
	}


func _run_action(
	client_id: String,
	action: String,
	server_url: String,
	context: Dictionary,
	prewarm_after_configure: bool,
) -> Dictionary:
	var result: Dictionary
	var prewarm: Dictionary = {}
	if action == "remove":
		result = ClientConfigurator.remove(client_id, server_url, context)
	else:
		result = ClientConfigurator.configure(client_id, server_url, context)
		if result.get("status") == "ok" and prewarm_after_configure:
			_set_action_phase(client_id, PHASE_PREWARM)
			prewarm = ClientConfigurator.prewarm_attach_launch(
				context,
				ClientConfigurator.PREWARM_TIMEOUT_MS,
				{},
				Callable(self, "_is_action_cancelled").bind(client_id),
			)
	return {
		"client_id": client_id,
		"action": action,
		"result": result,
		"prewarm": prewarm,
	}


func _poll_actions() -> void:
	var phase_changed := false
	for client_id in _action_threads.keys():
		var thread: Thread = _action_threads[client_id]
		if thread == null:
			continue
		if thread.is_alive():
			phase_changed = phase_changed or not _read_action_phase(String(client_id)).is_empty()
			continue
		var payload: Variant = thread.wait_to_finish()
		_action_threads[client_id] = null
		var action := String(_action_names.get(client_id, "configure"))
		var result: Dictionary = {"status": "error", "message": "worker returned no result"}
		var prewarm: Dictionary = {}
		if payload is Dictionary:
			var data := payload as Dictionary
			action = String(data.get("action", action))
			result = (data.get("result", {}) as Dictionary).duplicate(true)
			prewarm = (data.get("prewarm", {}) as Dictionary).duplicate(true)
		_finalize_action(String(client_id), action, result, prewarm)
	if phase_changed:
		_publish_snapshot()


func _finalize_action(
	client_id: String,
	action: String,
	result: Dictionary,
	prewarm: Dictionary,
) -> void:
	## Safety evidence is consumed before the sole slot is released. A completed
	## timed-out worker therefore cannot reopen a race window between is_alive()
	## flipping false and its termination_failed payload being persisted.
	_record_unproven_action_result(client_id, action, result, prewarm)
	var request_id := String(_action_request_ids.get(client_id, ""))
	_action_threads.erase(client_id)
	_action_started_msec.erase(client_id)
	_action_names.erase(client_id)
	_action_request_ids.erase(client_id)
	_action_timeout_reported.erase(client_id)
	_set_action_cancelled(client_id, false)
	_clear_action_phase(client_id)
	if _refresh_state != RefreshState.SHUTTING_DOWN:
		action_completed.emit(client_id, action, result.duplicate(true), prewarm.duplicate(true))
		if not request_id.is_empty():
			mcp_action_completed.emit(
				request_id,
				_mcp_action_payload(client_id, result),
			)
	_publish_snapshot()


static func _mcp_action_payload(client_id: String, result: Dictionary) -> Dictionary:
	if str(result.get("status", "error")) == "error":
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			str(result.get("message", "Configuration failed for '%s'" % client_id)),
		)
	return {"data": result.duplicate(true)}


static func _mcp_action_deferred_timeout_msec(_action: String) -> int:
	return ACTION_TIMEOUT_MSEC + MCP_ACTION_DEFERRED_GRACE_MSEC


func _record_unproven_action_payload(payload: Variant) -> void:
	if not payload is Dictionary:
		return
	var data := payload as Dictionary
	var result: Dictionary = {}
	var prewarm: Dictionary = {}
	if data.get("result", null) is Dictionary:
		result = data.get("result", {}) as Dictionary
	if data.get("prewarm", null) is Dictionary:
		prewarm = data.get("prewarm", {}) as Dictionary
	_record_unproven_action_result(
		str(data.get("client_id", "")),
		str(data.get("action", "configure")),
		result,
		prewarm,
	)


func _record_unproven_action_result(
	client_id: String,
	action: String,
	result: Dictionary,
	prewarm: Dictionary,
) -> void:
	if client_id.is_empty():
		return
	if (
		bool(result.get("termination_failed", false))
		or bool(prewarm.get("termination_failed", false))
	):
		_mark_mutation_termination_unproven(client_id, action)


func _record_unproven_post_update_result(payload: Variant) -> void:
	if not payload is Dictionary:
		return
	var result := payload as Dictionary
	if not bool(result.get("termination_failed", false)):
		return
	var client_id := str(result.get("unsafe_client_id", ""))
	if client_id.is_empty():
		_post_update_termination_unproven = true
		Engine.set_meta(POST_UPDATE_UNPROVEN_META, true)
	else:
		_mark_mutation_termination_unproven(client_id, "post_update_repin")


func _mark_mutation_termination_unproven(client_id: String, action: String) -> void:
	_mutation_termination_unproven[client_id] = action
	Engine.set_meta(
		MUTATION_UNPROVEN_META,
		_mutation_termination_unproven.duplicate(true),
	)


func _check_action_timeouts(now_msec: int = -1) -> void:
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	for client_id in _action_threads.keys():
		if bool(_action_timeout_reported.get(client_id, false)):
			continue
		var started := int(_action_started_msec.get(client_id, 0))
		if started > 0 and now - started >= _action_budget(String(client_id)):
			_report_action_timeout(String(client_id), now - started)


func _action_budget(client_id: String) -> int:
	if _read_action_phase(client_id) == PHASE_PREWARM:
		return ACTION_TIMEOUT_MSEC + ClientConfigurator.PREWARM_TIMEOUT_MS
	return ACTION_TIMEOUT_MSEC


func _report_action_timeout(client_id: String, elapsed_msec: int) -> void:
	if not _action_threads.has(client_id):
		return
	var thread: Thread = _action_threads[client_id]
	var alive := thread != null and thread.is_alive()
	if alive:
		_set_action_cancelled(client_id, true)
	_action_timeout_reported[client_id] = true
	var action := String(_action_names.get(client_id, "configure"))
	var label := "Remove" if action == "remove" else "Configure"
	var detail := (
		"%s is taking longer than expected and is being stopped; this row remains locked until its worker is joined." % label
		if alive
		else "%s did not report completion in time; waiting to inspect its result." % label
	)
	print(
		"MCP | client action timed out: client=%s action=%s elapsed_ms=%d worker_alive=%s"
		% [client_id, action, elapsed_msec, str(alive)]
	)
	action_timed_out.emit(client_id, action, detail)
	_publish_snapshot()


func request_status_refresh(ids: Array[String], force := false) -> bool:
	_client_ids = ids.duplicate()
	if not _accepting_work or _client_health_blocked:
		return false
	if RefreshState.has_worker_alive(_refresh_state):
		## One refresh worker total. A timed-out probe remains visible and owns
		## the slot until its bounded subprocess calls return; repeated force
		## requests collapse into one retry instead of growing live Threads.
		_refresh_pending = true
		_refresh_pending_force = _refresh_pending_force or force
		_publish_snapshot()
		return false
	if RefreshState.is_blocked_for_spawn(_refresh_state):
		return false
	if not force and _refresh_completed_msec > 0:
		if Time.get_ticks_msec() - _refresh_completed_msec < STATUS_COOLDOWN_MSEC:
			return false
	if ids.is_empty():
		return false
	if _filesystem_busy():
		_refresh_state = RefreshState.DEFERRED_FOR_FILESYSTEM
		_refresh_pending_force = _refresh_pending_force or force
		_publish_snapshot()
		return false
	if force:
		ClientConfigurator.invalidate_cli_cache()
	_warm_worker_bytecode()
	var probes: Array[Dictionary] = []
	for client_id in ids:
		var probe := ClientConfigurator.client_status_probe_snapshot(client_id)
		if not probe.is_empty():
			probes.append(probe)
	if probes.is_empty():
		_finish_refresh({})
		return false
	var context := ClientConfigurator.capture_launch_context()
	_refresh_state = RefreshState.RUNNING
	_refresh_pending = false
	_refresh_pending_force = false
	_refresh_started_msec = Time.get_ticks_msec()
	_refresh_generation += 1
	_refresh_thread = Thread.new()
	var error := _refresh_thread.start(
		Callable(self, "_run_status_refresh").bind(
			probes,
			ClientConfigurator.server_url_from(context),
			context,
			_refresh_generation,
		)
	)
	if error != OK:
		_refresh_thread = null
		_refresh_state = RefreshState.IDLE
		_publish_snapshot()
		return false
	_publish_snapshot()
	return true


## Queue one deferred MCP response onto the same aggregate refresh worker the
## Dock uses. The dispatcher bounds its pending table; this local cap also
## protects direct/future callers. No connection or handler is retained.
func request_mcp_status(request_id: String) -> bool:
	if (
		request_id.is_empty()
		or not _accepting_work
		or _client_health_blocked
		or _refresh_state == RefreshState.SHUTTING_DOWN
		or _mcp_status_waiters.has(request_id)
		or _mcp_status_waiters.size() >= MAX_MCP_STATUS_WAITERS
	):
		return false
	var target_generation := _refresh_generation + 1
	_mcp_status_waiters[request_id] = target_generation
	request_status_refresh(ClientConfigurator.client_ids(), true)
	if (
		_refresh_generation >= target_generation
		or _refresh_pending
		or _refresh_state == RefreshState.DEFERRED_FOR_FILESYSTEM
	):
		return true
	_mcp_status_waiters.erase(request_id)
	return false


func _run_status_refresh(
	probes: Array[Dictionary],
	server_url: String,
	context: Dictionary,
	generation: int,
) -> Dictionary:
	var results: Dictionary = {}
	var resolved_launch := ClientConfigurator.resolve_attach_launch(context)
	for probe in probes:
		var client_id := String(probe.get("id", ""))
		if client_id.is_empty():
			continue
		var details := ClientConfigurator.check_status_details_for_url_with_cli_path(
			client_id,
			server_url,
			String(probe.get("cli_path", "")),
			context,
			resolved_launch,
		)
		results[client_id] = {
			"status": details.get("status", Client.Status.NOT_CONFIGURED),
			"installed": bool(probe.get("installed", false)),
			"error_msg": details.get("error_msg", ""),
		}
	return {"results": results, "generation": generation}


func _poll_refresh() -> void:
	if _refresh_thread == null or _refresh_thread.is_alive():
		return
	var payload: Variant = _refresh_thread.wait_to_finish()
	_refresh_thread = null
	if not (payload is Dictionary):
		_finish_refresh({}, _refresh_generation, "Client status worker returned an invalid response.")
		return
	var data := payload as Dictionary
	if int(data.get("generation", -1)) != _refresh_generation:
		return
	var results := (data.get("results", {}) as Dictionary).duplicate(true)
	var timed_out := _refresh_state == RefreshState.RUNNING_TIMED_OUT
	_finish_refresh(
		{} if timed_out else results,
		int(data.get("generation", _refresh_generation)),
		"Client status probe timed out." if timed_out else "",
	)


func _finish_refresh(
	results: Dictionary, completed_generation: int = -1, mcp_error: String = ""
) -> void:
	_refresh_completed_msec = Time.get_ticks_msec()
	if _refresh_state != RefreshState.SHUTTING_DOWN:
		_refresh_state = RefreshState.IDLE
	if not _client_health_blocked and _refresh_state != RefreshState.SHUTTING_DOWN:
		status_refresh_completed.emit(results.duplicate(true))
		_complete_mcp_status_waiters(results, completed_generation, mcp_error)
	_publish_snapshot()
	if _refresh_pending:
		var force := _refresh_pending_force
		_refresh_pending = false
		_refresh_pending_force = false
		request_status_refresh(_client_ids, force)


func _complete_mcp_status_waiters(
	results: Dictionary, completed_generation: int, error: String
) -> void:
	if completed_generation < 0 or _mcp_status_waiters.is_empty():
		return
	var completed: Array[String] = []
	for request_id in _mcp_status_waiters:
		if int(_mcp_status_waiters[request_id]) <= completed_generation:
			completed.append(String(request_id))
	for request_id in completed:
		_mcp_status_waiters.erase(request_id)
	if completed.is_empty():
		return
	var payload := (
		McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, error)
		if not error.is_empty()
		else ClientConfigurator.client_status_response(results)
	)
	mcp_status_completed.emit(completed, payload.duplicate(true))

func _refresh_timed_out() -> bool:
	return (
		RefreshState.has_worker_alive(_refresh_state)
		and _refresh_started_msec > 0
		and Time.get_ticks_msec() - _refresh_started_msec >= STATUS_TIMEOUT_MSEC
	)


func _check_refresh_timeout() -> void:
	if _refresh_state == RefreshState.RUNNING and _refresh_timed_out():
		_refresh_state = RefreshState.RUNNING_TIMED_OUT
		_publish_snapshot()


func _retry_deferred_refresh() -> void:
	if _refresh_state != RefreshState.DEFERRED_FOR_FILESYSTEM:
		return
	if not _accepting_work or _client_health_blocked or _filesystem_busy():
		return
	var force := _refresh_pending_force
	_refresh_state = RefreshState.IDLE
	_refresh_pending_force = false
	request_status_refresh(_client_ids, force)


func _filesystem_busy() -> bool:
	var filesystem := EditorInterface.get_resource_filesystem()
	return filesystem != null and filesystem.is_scanning()


func _warm_worker_bytecode() -> void:
	var ids := ClientConfigurator.client_ids()
	if ids.is_empty():
		return
	var client := ClientRegistry.get_by_id(String(ids[0]))
	if client != null:
		JsonStrategy.verify_entry(client, {}, "")
		DshStrategy.command_launch_error(client, {})
	TomlStrategy.format_body(PackedStringArray(), "")
	CliStrategy.format_args(PackedStringArray(), "", "")
	ClientConfigurator.warm_env_snapshot()


func _set_action_cancelled(client_id: String, cancelled: bool) -> void:
	_action_cancel_mutex.lock()
	if cancelled:
		_action_cancelled[client_id] = true
	else:
		_action_cancelled.erase(client_id)
	_action_cancel_mutex.unlock()


func _is_action_cancelled(client_id: String) -> bool:
	_action_cancel_mutex.lock()
	var cancelled := bool(_action_cancelled.get(client_id, false))
	_action_cancel_mutex.unlock()
	return cancelled


func _set_post_update_cancelled(cancelled: bool) -> void:
	_post_update_cancel_mutex.lock()
	_post_update_cancelled = cancelled
	_post_update_cancel_mutex.unlock()


func _is_post_update_cancelled() -> bool:
	_post_update_cancel_mutex.lock()
	var cancelled := _post_update_cancelled
	_post_update_cancel_mutex.unlock()
	return cancelled


func _set_action_phase(client_id: String, phase: String) -> void:
	_action_phase_mutex.lock()
	_action_phases[client_id] = phase
	_action_phase_mutex.unlock()


func _read_action_phase(client_id: String) -> String:
	_action_phase_mutex.lock()
	var phase := String(_action_phases.get(client_id, ""))
	_action_phase_mutex.unlock()
	return phase


func _read_action_phases() -> Dictionary:
	_action_phase_mutex.lock()
	var phases := _action_phases.duplicate(true)
	_action_phase_mutex.unlock()
	return phases


func _clear_action_phase(client_id: String) -> void:
	_action_phase_mutex.lock()
	_action_phases.erase(client_id)
	_action_phase_mutex.unlock()
