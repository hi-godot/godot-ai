@tool
class_name McpServerLifecycleManager
extends RefCounted

## One serialized lifecycle episode. Late effect results carry its ID.
signal snapshot_changed(snapshot: Dictionary)
signal transport_ready(ws_port: int, ws_capability: String)
signal transport_cleared(reason: String)
signal effect_requested(episode_id: int, effect: String, payload: Dictionary)
signal startup_finished(path: String)

const Authority := preload("res://addons/godot_ai/utils/server_authority.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const ServerState := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const ServerVersionCheck := preload("res://addons/godot_ai/utils/server_version_check.gd")
const TransportCapability := preload("res://addons/godot_ai/utils/transport_capability.gd")
const UvResolution := preload("res://addons/godot_ai/utils/uv_resolution_policy.gd")

const DORMANT := "DORMANT"
const STARTING := "STARTING"
const READY := "READY"
const BLOCKED := "BLOCKED"
const RECOVERING := "RECOVERING"
## How long a server launched to replace an occupant may wait for the port.
const REPLACEMENT_WAIT_FOR_PORT_MS := 5000
const STOPPING := "STOPPING"

const PROBE := "PROBE"
const LAUNCH := "LAUNCH"
const PROVE := "PROVE"
const REPLACE := "REPLACE"
const STOP := "STOP"

const STATUS_PATH := "/godot-ai/status"
const DEFAULT_PROBE_TIMEOUT_MS := 800
const DEFAULT_PROVE_TIMEOUT_MS := 180_000
const LAUNCH_FINGERPRINT_TIMEOUT_MS := 15_000
const REPLACEMENT_TTL_MS := 15_000
const MAX_STATUS_BODY_BYTES := 8 * 1024

var _episode: Dictionary = _dormant_episode(0)
var _next_episode_id := 0
var _plan: Dictionary = {}
var _transport
var _process_grant
var _replacement_authorization
var _effect: Dictionary = {}

func configure(plan: Dictionary) -> void:
	## Capture caller-owned values once. Configuration is intentionally inert.
	if not _plan.is_empty():
		return
	_plan = plan.duplicate(true)
	_plan["http_port"] = int(_plan.get("http_port", ClientConfigurator.DEFAULT_HTTP_PORT))
	_plan["ws_port"] = int(_plan.get("ws_port", ClientConfigurator.DEFAULT_WS_PORT))
	_plan["expected_version"] = str(_plan.get("expected_version", ""))
	_plan["capability_path"] = str(_plan.get("capability_path", ""))
	_plan["probe_timeout_ms"] = int(_plan.get("probe_timeout_ms", DEFAULT_PROBE_TIMEOUT_MS))
	_plan["prove_timeout_ms"] = int(_plan.get("prove_timeout_ms", DEFAULT_PROVE_TIMEOUT_MS))
	_plan["keep_alive"] = bool(_plan.get("keep_alive", false))
	_plan["automatic_effects"] = bool(_plan.get("automatic_effects", true))
	_plan["defer_effects"] = bool(_plan.get("defer_effects", true))

func start_server() -> void:
	if _plan.is_empty():
		_block_without_effect("not_configured", "Server lifecycle is not configured.")
		return
	if str(_episode.get("state")) in [STARTING, RECOVERING, STOPPING]:
		return
	if _process_grant != null:
		force_restart_server()
		return
	_begin_start_episode()


func _begin_start_episode(existing_id := 0, probe := true) -> void:
	_cancel_effect()
	_replacement_authorization = null
	_transport = null
	if existing_id <= 0:
		_next_episode_id += 1
		existing_id = _next_episode_id
	_episode = {
		"id": existing_id,
		"state": STARTING,
		"phase": PROBE if probe else LAUNCH,
		"reason": "",
		"message": "Probing the configured server endpoint." if probe else "Launching the managed server.",
		"ready_kind": "",
		"effect": "",
		"expected_version": str(_plan.get("expected_version", "")),
		"actual_version": "",
		"blocked_target": {},
		"launch": {},
		"after_stop": "",
	}
	_publish()
	if not probe:
		return
	_request_effect(PROBE, {
		"http_port": int(_plan.http_port),
		"expected_version": str(_plan.expected_version),
		"expected_ws_port": int(_plan.ws_port),
		"timeout_ms": int(_plan.probe_timeout_ms),
	})


func stop_server(force_inline := false) -> void:
	## Ordinary duplicate Stop clicks coalesce. Update/exit teardown passes
	## force_inline: it must join even an existing STOP worker before scripts can
	## be replaced, then re-check the same exact grant synchronously.
	if str(_episode.get("state")) == STOPPING and not force_inline:
		return
	_adopt_cancelled_launch(_cancel_effect())
	_next_episode_id += 1
	var launch: Dictionary = _episode.get("launch", {}).duplicate(true)
	_episode = _stopping_episode(_next_episode_id, launch, "")
	_transport = null
	_replacement_authorization = null
	transport_cleared.emit("server stopping")
	_publish()
	if _process_grant == null:
		_finish_stop()
		return
	_request_effect(STOP, _stop_payload(launch), force_inline)


func force_restart_server() -> bool:
	if not has_managed_server():
		return false
	_cancel_effect()
	_next_episode_id += 1
	var launch: Dictionary = _episode.get("launch", {}).duplicate(true)
	_episode = _stopping_episode(_next_episode_id, launch, "start")
	_episode["message"] = "Restarting the managed server."
	_transport = null
	transport_cleared.emit("server restarting")
	_publish()
	_request_effect(STOP, _stop_payload(launch))
	return true


func authorize_replacement(now_msec := -1, ttl_msec := REPLACEMENT_TTL_MS) -> bool:
	if str(_episode.get("state")) != BLOCKED:
		return false
	var target: Dictionary = _episode.get("blocked_target", {})
	if not bool(target.get("replaceable", false)):
		return false
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	_replacement_authorization = Authority.ReplacementAuthorization.new(
		str(target.get("instance_id", "")),
		str(target.get("version", "")),
		int(target.get("port", 0)),
		now_msec + maxi(0, ttl_msec),
	)
	return _replacement_authorization.is_available(now_msec)


func replace_authorized(now_msec := -1) -> bool:
	if str(_episode.get("state")) != BLOCKED or _replacement_authorization == null:
		return false
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	var target: Dictionary = _episode.get("blocked_target", {}).duplicate(true)
	if not _replacement_authorization.spend(
		now_msec,
		str(target.get("instance_id", "")),
		str(target.get("version", "")),
		int(target.get("port", 0)),
	):
		_replacement_authorization = null
		return false
	_replacement_authorization = null
	_episode["state"] = RECOVERING
	_episode["phase"] = ""
	_episode["message"] = "Replacing the explicitly authorized server."
	_episode["effect"] = ""
	_publish()
	## The replacement launches our server first and kills the target only
	## then, so the port never looks free to a bridge polling to spawn its
	## own backend; the launched server waits for the port to free.
	var launch_plan := _plan.duplicate(true)
	launch_plan["wait_for_port_ms"] = REPLACEMENT_WAIT_FOR_PORT_MS
	_request_effect(REPLACE, {
		"target": target,
		"timeout_ms": int(_plan.get("probe_timeout_ms", DEFAULT_PROBE_TIMEOUT_MS)),
		"launch": launch_plan,
	})
	return true


func request_replacement() -> bool:
	var now := Time.get_ticks_msec()
	return authorize_replacement(now) and replace_authorized(now)


func can_recover_incompatible_server() -> bool:
	return (
		str(_episode.get("state")) == BLOCKED
		and bool(_episode.get("blocked_target", {}).get("replaceable", false))
	)


func prepare_for_update_reload() -> Dictionary:
	stop_server(true)
	var state := str(_episode.get("state", ""))
	if state == DORMANT and _process_grant == null:
		return {"ok": true}
	return {
		"ok": false,
		"reason": str(_episode.get("reason", "stop_incomplete")),
		"message": str(_episode.get(
			"message", "The managed server did not stop before update activation."
		)),
	}


func teardown_for_editor_exit(live_snapshot: Dictionary = {}) -> void:
	## A launch effect can create the process immediately before teardown joins
	## it. Recover that exact PID+fingerprint result before deciding whether
	## there is an owned child to stop or intentionally detach.
	_adopt_cancelled_launch(_cancel_effect())
	if _process_grant == null:
		_detach_to_dormant("adopted server left running")
		return
	if bool(_plan.get("keep_alive", false)):
		_detach_to_dormant("keep_server_on_exit")
		return
	var live := live_snapshot.duplicate(true) if not live_snapshot.is_empty() else _probe_current_transport()
	if active_lease_count(live) > 0:
		_detach_to_dormant("active attach lease")
		return
	stop_server(true)


func detach_server(reason := "server left running") -> void:
	_detach_to_dormant(reason)


func _detach_to_dormant(reason: String) -> void:
	_cancel_effect()
	_process_grant = null
	_transport = null
	_replacement_authorization = null
	_next_episode_id += 1
	_episode = _dormant_episode(_next_episode_id)
	_episode["message"] = reason
	transport_cleared.emit(reason)
	_publish()


func transport_authenticated(version: String) -> void:
	if str(_episode.get("state")) != READY:
		return
	var expected := str(_episode.get("expected_version", ""))
	if _server_version_compatibility(version, expected).get("compatible", false):
		_episode["actual_version"] = version
		_publish()
		return
	var public_transport: Dictionary = _transport.public_snapshot() if _transport != null else {}
	_block(
		"incompatible",
		"Server v%s does not match plugin v%s. Choose Replace to continue."
		% [version, expected],
		{
			"instance_id": str(public_transport.get("server_instance_id", "")),
			"version": version,
			"port": int(public_transport.get("http_port", 0)),
			"replaceable": not str(public_transport.get("server_instance_id", "")).is_empty(),
		},
	)


func transport_lost(reason := "Authenticated server endpoint was lost.") -> void:
	if str(_episode.get("state")) != READY:
		return
	_transport = null
	_block("endpoint_lost", reason)


func complete_effect(episode_id: int, effect: String, result: Dictionary) -> bool:
	if episode_id != int(_episode.get("id", -1)):
		return false
	if effect != str(_episode.get("effect", "")):
		return false
	_episode["effect"] = ""
	match effect:
		PROBE:
			_complete_probe(result)
		LAUNCH:
			_complete_launch(result)
		PROVE:
			_complete_prove(result)
		REPLACE:
			_complete_replace(result)
		STOP:
			_complete_stop(result)
		_:
			return false
	return true


func _complete_probe(result: Dictionary) -> void:
	match str(result.get("outcome", "blocked")):
		"compatible":
			var transport = result.get("transport")
			if transport == null or not transport.is_valid():
				_block("invalid_transport", "The server returned invalid transport authority.")
				return
			_process_grant = null
			_ready("adopted", transport, str(result.get("version", "")))
		"free":
			_episode["phase"] = LAUNCH
			_episode["message"] = "Launching the managed server."
			_publish()
			var launch_plan := _plan.duplicate(true)
			launch_plan["baseline_instance_id"] = str(result.get("baseline_instance_id", ""))
			_request_effect(LAUNCH, launch_plan)
		_:
			_block(
				str(result.get("reason", "occupied")),
				str(result.get("message", "The configured endpoint is unavailable.")),
				result.get("target", {}),
			)


func _complete_launch(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_block(str(result.get("reason", "launch_failed")), str(result.get("message", "Server launch failed.")))
		return
	var pid := int(result.get("pid", 0))
	var fingerprint := str(result.get("fingerprint", ""))
	var launch := {
		"pid": pid,
		"fingerprint": fingerprint,
		"http_capability": str(result.get("http_capability", "")),
		"ws_capability": str(result.get("ws_capability", "")),
		"baseline_instance_id": str(result.get("baseline_instance_id", "")),
	}
	_process_grant = _owned_process_grant(pid, fingerprint)
	if not _process_grant.is_valid():
		_process_grant = null
		_block("launch_unproven", "The launched process identity could not be proven.")
		return
	_episode["launch"] = launch
	_episode["phase"] = PROVE
	_episode["prove_deadline_msec"] = (
		Time.get_ticks_msec() + int(_plan.get("prove_timeout_ms", DEFAULT_PROVE_TIMEOUT_MS))
	)
	_episode["message"] = "Waiting for the managed server capability record."
	_publish()
	_request_effect(PROVE, _prove_payload())


func _complete_prove(result: Dictionary) -> void:
	if bool(result.get("pending", false)):
		_episode["proof_pending_reason"] = str(result.get("reason", "unknown"))
		if Time.get_ticks_msec() >= int(_episode.get("prove_deadline_msec", 0)):
			_block(
				"proof_timeout",
				"The managed server proof timed out at %s."
				% str(_episode.get("proof_pending_reason", "unknown")),
			)
			return
		_retry_effect_after(PROVE, _prove_payload(), 0.15)
		return
	if not bool(result.get("ok", false)):
		var message := str(result.get("message", "Managed server proof failed."))
		var pending_reason := str(_episode.get("proof_pending_reason", ""))
		if not pending_reason.is_empty():
			message += " Last pending proof: %s." % pending_reason
		_block(str(result.get("reason", "proof_failed")), message)
		return
	var launch: Dictionary = _episode.get("launch", {})
	var pid := int(result.get("pid", 0))
	var fingerprint := str(result.get("fingerprint", ""))
	var exact_grant = _owned_process_grant(pid, fingerprint)
	if not exact_grant.is_valid():
		_block("process_proof_failed", "The server process identity changed before proof completed.")
		return
	_process_grant = exact_grant
	launch["pid"] = pid
	launch["fingerprint"] = fingerprint
	_episode["launch"] = launch
	_ready("owned", result.get("transport"), str(result.get("version", "")))


func _complete_replace(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_block(str(result.get("reason", "replacement_failed")), str(result.get("message", "Authorized replacement failed.")))
		return
	_process_grant = null
	_transport = null
	var launch: Dictionary = result.get("launch", {})
	if launch.is_empty():
		_begin_start_episode(int(_episode.get("id", 0)))
		return
	## Our server was launched before the target was killed and is taking
	## the port now; continue exactly as a fresh launch would, at its proof.
	_begin_start_episode(int(_episode.get("id", 0)), false)
	_complete_launch(launch)


func _complete_stop(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_block(str(result.get("reason", "stop_refused")), str(result.get("message", "Managed stop authority no longer matches the process.")))
		return
	_finish_stop()


func _finish_stop() -> void:
	var continue_with_start := str(_episode.get("after_stop", "")) == "start"
	var stopped_pid := get_server_pid()
	_process_grant = null
	_transport = null
	_replacement_authorization = null
	var pid_file := str(_plan.get("pid_file", ""))
	if not pid_file.is_empty() and FileAccess.file_exists(pid_file):
		DirAccess.remove_absolute(pid_file)
	var completed_id := int(_episode.get("id", 0))
	_episode = _dormant_episode(completed_id)
	_publish()
	if stopped_pid > 1:
		print("MCP | stopped server (PID %d)" % stopped_pid)
	if continue_with_start:
		_begin_start_episode()


func _ready(kind: String, transport, version: String) -> void:
	if transport == null or not transport.is_valid():
		_block("invalid_transport", "The server returned invalid transport authority.")
		return
	_transport = transport
	_episode["state"] = READY
	_episode["phase"] = ""
	_episode["ready_kind"] = kind
	_episode["actual_version"] = version
	_episode["reason"] = ""
	_episode["message"] = "Server ready (%s)." % kind
	_episode["blocked_target"] = {}
	_episode["launch"] = {}
	_publish()
	if kind == "owned":
		print("MCP | started server (PID %d)" % get_server_pid())
	elif kind == "adopted":
		print("MCP | adopted external server")
	transport_ready.emit(transport.ws_port(), transport.ws_capability())
	startup_finished.emit(kind)


func _block(reason: String, message: String, target: Dictionary = {}) -> void:
	_transport = null
	_replacement_authorization = null
	_episode["state"] = BLOCKED
	_episode["phase"] = ""
	_episode["reason"] = reason
	_episode["message"] = message
	_episode["blocked_target"] = target.duplicate(true)
	_episode["effect"] = ""
	_publish()
	transport_cleared.emit(message)
	startup_finished.emit("blocked:%s" % reason)


func _block_without_effect(reason: String, message: String) -> void:
	_next_episode_id += 1
	_episode = _dormant_episode(_next_episode_id)
	_episode["state"] = BLOCKED
	_episode["reason"] = reason
	_episode["message"] = message
	_publish()


func _request_effect(kind: String, payload: Dictionary, force_inline := false) -> void:
	if not _effect.is_empty():
		_block("effect_overlap", "Lifecycle attempted overlapping effects.")
		return
	_episode["effect"] = kind
	_publish()
	var episode_id := int(_episode.id)
	var copied := payload.duplicate(true)
	if not bool(_plan.get("automatic_effects", true)):
		effect_requested.emit(episode_id, kind, copied)
		return
	if force_inline or not bool(_plan.get("defer_effects", true)) or not (Engine.get_main_loop() is SceneTree):
		complete_effect(episode_id, kind, _execute_effect(kind, copied))
		return
	var thread := Thread.new()
	if thread.start(_execute_effect.bind(kind, copied)) != OK:
		complete_effect(episode_id, kind, {"ok": false, "reason": "worker_start_failed"})
		return
	_effect = {"thread": thread, "episode_id": episode_id, "kind": kind}
	_await_effect(thread, episode_id, kind)


func _await_effect(thread: Thread, episode_id: int, kind: String) -> void:
	var tree := Engine.get_main_loop()
	while thread.is_alive() and tree is SceneTree:
		await (tree as SceneTree).process_frame
	if _effect.get("thread") != thread:
		return
	var result: Variant = thread.wait_to_finish()
	_effect.clear()
	if result is Dictionary:
		complete_effect(episode_id, kind, result)
	else:
		complete_effect(episode_id, kind, {"ok": false, "reason": "invalid_effect_result"})


func _cancel_effect() -> Dictionary:
	if _effect.is_empty():
		return {}
	var kind := str(_effect.get("kind", ""))
	var thread: Thread = _effect.get("thread")
	_effect.clear()
	if thread == null:
		return {"kind": kind, "result": {"ok": false, "reason": "missing_effect_thread"}}
	var result: Variant = thread.wait_to_finish()
	return {
		"kind": kind,
		"result": (
			result
			if result is Dictionary
			else {"ok": false, "reason": "invalid_effect_result"}
		),
	}


## Preserve process authority when cancellation joins a launch that already
## spawned. The caller may then stop by exact fingerprint; it never kills by a
## bare PID and never treats a failed/unproven launch as owned.
func _adopt_cancelled_launch(cancelled: Dictionary) -> bool:
	if str(cancelled.get("kind", "")) != LAUNCH:
		return false
	var result: Dictionary = cancelled.get("result", {})
	if not bool(result.get("ok", false)):
		return false
	var grant = _owned_process_grant(
		int(result.get("pid", 0)), str(result.get("fingerprint", ""))
	)
	if not grant.is_valid():
		return false
	_process_grant = grant
	_episode["launch"] = {
		"pid": int(result.get("pid", 0)),
		"fingerprint": str(result.get("fingerprint", "")),
		"http_capability": str(result.get("http_capability", "")),
		"ws_capability": str(result.get("ws_capability", "")),
		"baseline_instance_id": str(result.get("baseline_instance_id", "")),
	}
	return true


static func _owned_process_grant(pid: int, fingerprint: String):
	return Authority.OwnedProcessGrant.new(
		pid, fingerprint, maxi(1, Time.get_ticks_msec())
	)


func _retry_effect_after(kind: String, payload: Dictionary, delay_seconds: float) -> void:
	var episode_id := int(_episode.get("id", 0))
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		await (tree as SceneTree).create_timer(delay_seconds).timeout
	if episode_id == int(_episode.get("id", -1)) and str(_episode.get("state")) == STARTING:
		_request_effect(kind, payload)


func _execute_effect(kind: String, payload: Dictionary) -> Dictionary:
	match kind:
		PROBE:
			return _effect_probe(payload)
		LAUNCH:
			return _effect_launch(payload)
		PROVE:
			return _effect_prove(payload)
		REPLACE:
			return _effect_replace(payload)
		STOP:
			return _effect_stop(payload)
	return {"ok": false, "reason": "unknown_effect"}


func _effect_probe(payload: Dictionary) -> Dictionary:
	var port := int(payload.http_port)
	var expected_version := str(payload.expected_version)
	var expected_ws_port := int(payload.expected_ws_port)
	var capability := _read_capability(port)
	var live := _probe_with_capability(port, capability, int(payload.timeout_ms))
	if _authenticated_status_matches_record(live, capability):
		var version := str(live.get("version", ""))
		var ws_port := int(live.get("ws_port", 0))
		if _server_status_compatibility(version, expected_version, ws_port, expected_ws_port).get("compatible", false):
			return {
				"outcome": "compatible",
				"version": version,
				"transport": _transport_from(port, ws_port, live, capability),
			}
		return _blocked_probe_result("incompatible", port, live, true)
	if PortResolver.is_port_in_use(port):
		return _blocked_probe_result("occupied", port, live)
	return {
		"outcome": "free",
		"baseline_instance_id": str(capability.get("instance_nonce", "")),
	}


func _effect_launch(payload: Dictionary) -> Dictionary:
	var port := int(payload.http_port)
	if bool(payload.get("http_port_reserved", false)):
		return {"ok": false, "reason": "port_reserved", "message": "Port %d is reserved by Windows." % port}
	var server_command: Array = payload.get("server_command", [])
	if server_command.is_empty():
		return {"ok": false, "reason": "no_command", "message": "No godot-ai server command was found."}
	var args: Array[String] = []
	args.assign(server_command.slice(1))
	args.append_array(_server_flags(payload))
	var environment := {
		"GODOT_AI_PLUGIN_SPAWNED": "1",
	}
	if int(payload.get("wait_for_port_ms", 0)) > 0:
		environment["GODOT_AI_WAIT_FOR_PORT_MS"] = str(int(payload.get("wait_for_port_ms", 0)))
	if OS.get_name() != "Windows" and not bool(payload.get("keep_alive", false)):
		environment["GODOT_AI_OWNER_PID"] = str(OS.get_process_id())
	if bool(payload.get("keep_alive", false)):
		environment["GODOT_AI_NO_IDLE_EXIT"] = "1"
	if bool(payload.get("disable_telemetry", false)):
		environment["GODOT_AI_DISABLE_TELEMETRY"] = "true"
	var worktree_src := str(payload.get("worktree_src", ""))
	if not worktree_src.is_empty():
		var old_pythonpath := str(payload.get("ambient_pythonpath", ""))
		var separator := ";" if OS.get_name() == "Windows" else ":"
		environment["PYTHONPATH"] = (
			worktree_src if old_pythonpath.is_empty() else worktree_src + separator + old_pythonpath
		)
	var pid_file := str(payload.get("pid_file", ""))
	if not pid_file.is_empty() and FileAccess.file_exists(pid_file):
		DirAccess.remove_absolute(pid_file)
	var spawned := spawn_capability_process(str(server_command[0]), args, environment)
	var pid := int(spawned.pid)
	if pid <= 1:
		return {"ok": false, "reason": "launch_failed", "message": "The server process could not be launched."}
	## OS.create_process can return before POSIX exec replaces the child image.
	## Capture only after the command is branded and its exact fingerprint is
	## stable across two reads; otherwise a legitimate exec looks like PID reuse.
	var exact_grant := PortResolver.capture_process_kill_grant(pid, true)
	var fingerprint_deadline := Time.get_ticks_msec() + LAUNCH_FINGERPRINT_TIMEOUT_MS
	while exact_grant.is_empty() and Time.get_ticks_msec() < fingerprint_deadline:
		OS.delay_msec(100)
		exact_grant = PortResolver.capture_process_kill_grant(pid, true)
	var fingerprint := str(exact_grant.get("fingerprint", ""))
	return {
		"ok": not fingerprint.is_empty(),
		"reason": "launch_unproven" if fingerprint.is_empty() else "",
		"message": "The launched process identity could not be captured." if fingerprint.is_empty() else "",
		"pid": pid,
		"fingerprint": fingerprint,
		"http_capability": spawned.http,
		"ws_capability": spawned.websocket,
		"baseline_instance_id": str(payload.get("baseline_instance_id", "")),
	}


func _effect_prove(payload: Dictionary) -> Dictionary:
	var launch_grant = payload.get("grant")
	var launch_pid := int(launch_grant.process_id()) if launch_grant != null else -1
	var launch_alive := PortResolver.pid_alive(launch_pid)
	var launch_fingerprint := (
		PortResolver.process_fingerprint(launch_pid)
		if launch_alive
		else ""
	)
	var launch_disposition := _owned_process_disposition(
		launch_grant,
		launch_alive,
		launch_fingerprint,
	)
	if launch_disposition != "owned":
		return {
			"ok": false,
			"reason": "launch_%s" % launch_disposition,
			"message": "The launched server process exited or changed identity before publishing capabilities.",
		}
	var port := int(payload.http_port)
	var capability := _read_capability(port)
	if capability.is_empty() or str(capability.get("instance_nonce", "")) == str(payload.get("baseline_instance_id", "")):
		return {"pending": true, "reason": "capability_record"}
	if (
		str(capability.get("http", "")) != str(payload.get("http_capability", ""))
		or str(capability.get("websocket", "")) != str(payload.get("ws_capability", ""))
	):
		return {"pending": true, "reason": "capability_pair"}
	var live := _probe_with_capability(port, capability, int(payload.timeout_ms))
	if not _authenticated_status_matches_record(live, capability):
		return {"pending": true, "reason": "authenticated_status"}
	var version := str(live.get("version", ""))
	var ws_port := int(live.get("ws_port", 0))
	if not _server_status_compatibility(
		version, str(payload.expected_version), ws_port, int(payload.expected_ws_port)
	).get("compatible", false):
		return {"ok": false, "reason": "incompatible", "message": "The launched server does not match this plugin."}
	var pid := PortResolver.read_pid_file(str(payload.get("pid_file", "")))
	if pid <= 1:
		return {"pending": true, "reason": "pid_file"}
	if not PortResolver.find_all_pids_on_port(port).has(pid):
		return {"pending": true, "reason": "listener_pid"}
	if not PortResolver.pid_cmdline_is_godot_ai(pid):
		return {"pending": true, "reason": "process_brand"}
	if not PortResolver.process_descends_from(pid, launch_pid):
		return {"pending": true, "reason": "launch_lineage"}
	var fingerprint := PortResolver.process_fingerprint(pid)
	if fingerprint.is_empty():
		return {"pending": true, "reason": "process_fingerprint"}
	## Close every capture window before minting process authority. The same
	## launch-lineage PID must still own the listener, the private capability
	## record must still name the authenticated instance, and the process
	## fingerprint must remain unchanged after the final probe.
	var final_capability := _read_capability(port)
	var final_live := _probe_with_capability(port, final_capability, int(payload.timeout_ms))
	if (
		PortResolver.read_pid_file(str(payload.get("pid_file", ""))) != pid
		or not PortResolver.find_all_pids_on_port(port).has(pid)
		or not PortResolver.process_descends_from(pid, launch_pid)
		or PortResolver.process_fingerprint(pid) != fingerprint
		or final_capability != capability
		or not _authenticated_status_matches_record(final_live, final_capability)
		or str(final_live.get("instance_id", "")) != str(live.get("instance_id", ""))
	):
		return {"pending": true, "reason": "final_capture_window"}
	var final_version := str(final_live.get("version", ""))
	var final_ws_port := int(final_live.get("ws_port", 0))
	if not _server_status_compatibility(
		final_version,
		str(payload.expected_version),
		final_ws_port,
		int(payload.expected_ws_port),
	).get("compatible", false):
		return {
			"ok": false,
			"reason": "incompatible",
			"message": "The launched server changed compatibility before authority was granted.",
		}
	return {
		"ok": true,
		"pid": pid,
		"fingerprint": fingerprint,
		"version": final_version,
		"transport": _transport_from(port, final_ws_port, final_live, final_capability),
	}


func _effect_replace(payload: Dictionary) -> Dictionary:
	var target: Dictionary = payload.get("target", {})
	var port := int(target.get("port", 0))
	var capability := _read_capability(port)
	var live := _probe_with_capability(port, capability, int(payload.timeout_ms))
	if not _replacement_target_matches(target, live, capability):
		return {"ok": false, "reason": "replacement_target_changed", "message": "The authorized server changed before replacement."}
	var candidates: Array[int] = []
	for pid in PortResolver.find_all_pids_on_port(port):
		if PortResolver.pid_cmdline_is_godot_ai(pid):
			candidates.append(pid)
	if candidates.size() != 1:
		return {"ok": false, "reason": "replacement_unproven", "message": "The authorized server process could not be proven."}
	var pid := candidates[0]
	var fingerprint := PortResolver.process_fingerprint(pid)
	if fingerprint.is_empty():
		return {"ok": false, "reason": "replacement_unproven", "message": "The authorized server process could not be fingerprinted."}
	# Reprobe, then bind the kill to the captured PID + start fingerprint.
	live = _probe_with_capability(port, capability, int(payload.timeout_ms))
	if (
		not _replacement_target_matches(target, live, capability)
		or not PortResolver.find_all_pids_on_port(port).has(pid)
		or PortResolver.process_fingerprint(pid) != fingerprint
	):
		return {"ok": false, "reason": "replacement_target_changed", "message": "The authorized server changed before replacement."}
	## Launch our server before the kill so the port passes straight from
	## the target to it (the server waits for the port); a bridge polling
	## for a free port to spawn its own backend never sees one. The launch
	## baseline is the record the target published, which the proof must
	## see replaced.
	var launch_plan: Dictionary = payload.get("launch", {})
	var launch := {}
	if not launch_plan.is_empty():
		launch_plan = launch_plan.duplicate(true)
		launch_plan["baseline_instance_id"] = str(capability.get("instance_nonce", ""))
		launch = _effect_launch(launch_plan)
		if not bool(launch.get("ok", false)):
			return {
				"ok": false,
				"reason": str(launch.get("reason", "launch_failed")),
				"message": str(launch.get("message", "Server launch failed.")),
			}
	var killed := PortResolver.kill_exact_processes(
		[{"pid": pid, "fingerprint": fingerprint}],
		true,
	)
	if not killed.has(pid):
		if not launch.is_empty():
			PortResolver.kill_exact_processes(
				[{"pid": int(launch.pid), "fingerprint": str(launch.fingerprint)}], true
			)
		return {"ok": false, "reason": "replacement_failed"}
	if launch.is_empty():
		PortResolver.wait_for_port_free(port, 5.0)
		return {"ok": not PortResolver.is_port_in_use(port), "reason": ""}
	return {"ok": true, "reason": "", "launch": launch}


func _effect_stop(payload: Dictionary) -> Dictionary:
	var grant = payload.get("grant")
	if grant == null:
		return {"ok": true}
	var pid := int(grant.process_id())
	var port := int(payload.get("http_port", 0))
	var alive := PortResolver.pid_alive(pid)
	var fingerprint := PortResolver.process_fingerprint(pid) if alive else ""
	var disposition := _owned_process_disposition(grant, alive, fingerprint)
	if disposition == "unproven":
		return {"ok": false, "reason": "process_authority_mismatch", "message": "Managed process identity no longer matches its stop grant."}
	var grants: Array[Dictionary] = []
	var server_grant := _launched_server_kill_grant(payload, pid)
	if not server_grant.is_empty():
		grants.append(server_grant)
	if disposition == "owned":
		grants.append({"pid": pid, "fingerprint": fingerprint})
	PortResolver.kill_exact_processes(grants, true)
	if port > 0:
		PortResolver.wait_for_port_free(port, 3.0)
	var targets_gone := true
	for exact in grants:
		if PortResolver.process_fingerprint(int(exact.pid)) == str(exact.fingerprint):
			targets_gone = false
	var port_free := port <= 0 or not PortResolver.is_port_in_use(port)
	## Killing something of ours must also free its listener. When there was
	## nothing of ours left to kill, whoever holds the port now is not ours to
	## prove stopped; the next start's probe deals with that occupant.
	var stopped := targets_gone and (grants.is_empty() or port_free)
	return {
		"ok": stopped,
		"already_gone": grants.is_empty() and port_free,
		"reason": "" if stopped else "process_stop_failed",
		"message": "" if stopped else "A launched server process or listener could not be proven stopped.",
	}


func _launched_server_kill_grant(payload: Dictionary, launch_pid: int) -> Dictionary:
	var launch: Dictionary = payload.get("launch", {})
	if launch.is_empty():
		return {}
	var server_pid := PortResolver.read_pid_file(str(payload.get("pid_file", "")))
	var port := int(payload.get("http_port", 0))
	if (
		server_pid <= 1
		or server_pid == launch_pid
		or not PortResolver.process_descends_from(server_pid, launch_pid)
		or not PortResolver.find_all_pids_on_port(port).has(server_pid)
	):
		return {}
	var capability := _read_capability(port)
	if (
		str(capability.get("http", "")) != str(launch.get("http_capability", ""))
		or str(capability.get("websocket", "")) != str(launch.get("ws_capability", ""))
	):
		return {}
	var live := _probe_with_capability(
		port, capability, int(payload.get("timeout_ms", DEFAULT_PROBE_TIMEOUT_MS))
	)
	if not _authenticated_status_matches_record(live, capability):
		return {}
	var exact := PortResolver.capture_process_kill_grant(server_pid, true)
	if exact.is_empty():
		return {}
	if (
		PortResolver.read_pid_file(str(payload.get("pid_file", ""))) != server_pid
		or not PortResolver.process_descends_from(server_pid, launch_pid)
		or not PortResolver.find_all_pids_on_port(port).has(server_pid)
		or PortResolver.process_fingerprint(server_pid) != str(exact.fingerprint)
	):
		return {}
	return exact


static func _owned_process_disposition(grant, alive: bool, fingerprint: String) -> String:
	if grant == null:
		return "gone"
	if not alive:
		return "gone"
	var pid := int(grant.process_id())
	if fingerprint.is_empty():
		return "unproven"
	if not grant.matches(pid, fingerprint):
		return "replaced"
	return "owned"


func _prove_payload() -> Dictionary:
	var launch: Dictionary = _episode.get("launch", {})
	return {
		"http_port": int(_plan.http_port),
		"expected_ws_port": int(_plan.ws_port),
		"expected_version": str(_plan.expected_version),
		"timeout_ms": int(_plan.probe_timeout_ms),
		"pid_file": str(_plan.get("pid_file", "")),
		"http_capability": str(launch.get("http_capability", "")),
		"ws_capability": str(launch.get("ws_capability", "")),
		"baseline_instance_id": str(launch.get("baseline_instance_id", "")),
		"grant": _process_grant,
	}


func _stop_payload(launch: Dictionary) -> Dictionary:
	return {
		"grant": _process_grant,
		"http_port": int(_plan.get("http_port", 0)),
		"pid_file": str(_plan.get("pid_file", "")),
		"timeout_ms": int(_plan.get("probe_timeout_ms", DEFAULT_PROBE_TIMEOUT_MS)),
		"launch": launch.duplicate(true),
	}


func _probe_current_transport() -> Dictionary:
	if _transport == null:
		return {}
	return _probe_with_capability(
		_transport.http_port(),
		{"http": _transport.http_capability()},
		int(_plan.get("probe_timeout_ms", DEFAULT_PROBE_TIMEOUT_MS)),
	)


func _read_capability(port: int) -> Dictionary:
	return TransportCapability.read_for_http_port(
		port, str(_plan.get("capability_path", ""))
	)


static func probe_live_server_status(
	port: int, timeout_ms := DEFAULT_PROBE_TIMEOUT_MS, captured_path := ""
) -> Dictionary:
	var capability := TransportCapability.read_for_http_port(port, captured_path)
	return _probe_with_capability(port, capability, timeout_ms)


static func _probe_with_capability(port: int, capability: Dictionary, timeout_ms: int) -> Dictionary:
	var result := {"reachable": false, "name": "", "version": "", "ws_port": 0, "instance_id": "", "status_code": 0, "error": ""}
	var http_capability := str(capability.get("http", ""))
	if http_capability.is_empty():
		result.error = "missing_capability"
		return result
	var client := HTTPClient.new()
	var error := client.connect_to_host("127.0.0.1", port)
	if error != OK:
		result.error = "connect_%d" % error
		return result
	var deadline := Time.get_ticks_msec() + maxi(1, timeout_ms)
	while client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		client.poll()
		if Time.get_ticks_msec() >= deadline:
			result.error = "connect_timeout"
			return result
		OS.delay_msec(10)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		result.error = "connect_status_%d" % client.get_status()
		return result
	error = client.request(HTTPClient.METHOD_GET, STATUS_PATH, [
		"Accept: application/json", "Authorization: Bearer %s" % http_capability,
	])
	if error != OK:
		result.error = "request_%d" % error
		return result
	var body := PackedByteArray()
	while true:
		var status := client.get_status()
		if status == HTTPClient.STATUS_REQUESTING:
			client.poll()
		elif status == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if body.size() + chunk.size() > MAX_STATUS_BODY_BYTES:
				result.error = "response_too_large"
				return result
			body.append_array(chunk)
		elif status == HTTPClient.STATUS_CONNECTED:
			break
		else:
			result.error = "response_status_%d" % status
			return result
		if Time.get_ticks_msec() >= deadline:
			result.error = "response_timeout"
			return result
		OS.delay_msec(10)
	result.status_code = client.get_response_code()
	if int(result.status_code) != 200:
		result.error = "http_%d" % int(result.status_code)
		return result
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		result.error = "invalid_json"
		return result
	result.merge(project_status_payload(parsed), true)
	return result


static func project_status_payload(parsed: Dictionary) -> Dictionary:
	var projected := {
		"reachable": true,
		"name": str(parsed.get("name", "")),
		"version": str(parsed.get("server_version", parsed.get("version", ""))),
		"ws_port": int(parsed.get("ws_port", 0)),
		"instance_id": str(parsed.get("instance_id", "")),
		"package_path": str(parsed.get("package_path", "")),
	}
	var leases: Variant = parsed.get("active_lease_count")
	if leases is int or leases is float:
		var numeric := float(leases)
		if is_finite(numeric) and numeric == floor(numeric):
			projected.active_lease_count = maxi(0, int(numeric))
	var telemetry: Variant = parsed.get("telemetry_enabled")
	if telemetry is bool:
		projected.telemetry_enabled = telemetry
	return projected


static func _authenticated_status_matches_record(live: Dictionary, capability: Dictionary) -> bool:
	return (
		bool(live.get("reachable", false))
		and str(live.get("name", "")) == "godot-ai"
		and not str(capability.get("instance_nonce", "")).is_empty()
		and str(live.get("instance_id", "")) == str(capability.get("instance_nonce", ""))
	)


static func _replacement_target_matches(
	target: Dictionary, live: Dictionary, capability: Dictionary
) -> bool:
	return (
		_authenticated_status_matches_record(live, capability)
		and str(live.get("instance_id", "")) == str(target.get("instance_id", ""))
		and str(live.get("version", "")) == str(target.get("version", ""))
	)


static func _transport_from(port: int, ws_port: int, live: Dictionary, capability: Dictionary):
	return Authority.TransportAuthority.new(
		port,
		ws_port,
		str(live.get("instance_id", "")),
		str(capability.get("http", "")),
		str(capability.get("websocket", "")),
	)


static func _blocked_probe_result(
	reason: String, port: int, live: Dictionary, allow_replacement := false
) -> Dictionary:
	var instance_id := str(live.get("instance_id", ""))
	var version := str(live.get("version", ""))
	var replaceable := (
		allow_replacement
		and str(live.get("name", "")) == "godot-ai"
		and not instance_id.is_empty()
		and not version.is_empty()
	)
	var message := "Port %d is occupied by another process." % port
	if replaceable:
		message = "Port %d is occupied by godot-ai v%s; choose Replace to continue." % [port, version]
	return {
		"outcome": "blocked",
		"reason": reason,
		"message": message,
		"target": {"instance_id": instance_id, "version": version, "port": port, "replaceable": replaceable},
	}


static func generate_capability_pair() -> Dictionary:
	var http := _random_hex(32)
	var websocket := _random_hex(32)
	while websocket == http:
		websocket = _random_hex(32)
	return {"http": http, "websocket": websocket}


static func spawn_capability_process(
	command: String, args: Array[String], extra_environment: Dictionary = {}
) -> Dictionary:
	var pair := generate_capability_pair()
	var environment := extra_environment.duplicate(true)
	environment["GODOT_AI_HTTP_CAPABILITY"] = pair.http
	environment["GODOT_AI_WS_TOKEN"] = pair.websocket
	return {
		"pid": _create_process_with_environment(command, args, environment),
		"http": pair.http,
		"websocket": pair.websocket,
	}


static func _random_hex(byte_count: int) -> String:
	return Crypto.new().generate_random_bytes(byte_count).hex_encode()


static func _create_process_with_environment(command: String, args: Array[String], environment: Dictionary) -> int:
	var previous := {}
	PortResolver.lock_process_spawn()
	var full_command: Array = [command]
	full_command.append_array(args)
	var saved_uv_environment := (
		UvResolution.isolate_environment()
		if UvResolution.is_production_command(full_command)
		else {}
	)
	for key in environment:
		previous[key] = {"present": OS.has_environment(key), "value": OS.get_environment(key)}
		OS.set_environment(key, str(environment[key]))
	var pid := OS.create_process(command, args)
	for key in previous:
		if bool(previous[key].present):
			OS.set_environment(key, str(previous[key].value))
		else:
			OS.unset_environment(key)
	UvResolution.restore_environment(saved_uv_environment)
	PortResolver.unlock_process_spawn()
	return pid


static func _server_flags(plan: Dictionary) -> Array[String]:
	var flags: Array[String] = [
		"--transport", "streamable-http",
		"--port", str(plan.http_port),
		"--ws-port", str(plan.ws_port),
		"--pid-file", str(plan.get("pid_file", "")),
	]
	var excluded := str(plan.get("excluded_domains", ""))
	if not excluded.is_empty():
		flags.append_array(["--exclude-domains", excluded])
	var allow_hosts := str(plan.get("allow_hosts", ""))
	if not allow_hosts.is_empty():
		flags.append_array(["--allow-host", allow_hosts])
	return flags


static func active_lease_count(live: Dictionary) -> int:
	if str(live.get("name", "")) != "godot-ai":
		return 0
	return maxi(0, int(live.get("active_lease_count", 0)))


static func _server_version_compatibility(actual_version: String, expected_version: String) -> Dictionary:
	return ServerVersionCheck.evaluate(actual_version, expected_version)


static func _server_status_compatibility(actual_version: String, expected_version: String, actual_ws_port: int, expected_ws_port: int) -> Dictionary:
	var version := _server_version_compatibility(actual_version, expected_version)
	if not bool(version.compatible):
		return version
	if actual_ws_port != expected_ws_port:
		return {"compatible": false, "reason": "ws_port_mismatch"}
	return {"compatible": true, "reason": ""}


func get_status_dict() -> Dictionary:
	var state := str(_episode.get("state", DORMANT))
	var reason := str(_episode.get("reason", ""))
	return {
		"episode_id": int(_episode.get("id", 0)),
		"episode_state": state,
		"phase": str(_episode.get("phase", "")),
		"ready_kind": str(_episode.get("ready_kind", "")),
		"state": _dock_state(state, reason),
		"expected_version": str(_episode.get("expected_version", _plan.get("expected_version", ""))),
		"actual_version": str(_episode.get("actual_version", "")),
		"actual_name": "godot-ai" if state == READY else "",
		"message": str(_episode.get("message", "")),
		"connection_blocked": state != READY,
		"can_recover_incompatible": can_recover_incompatible_server(),
		"conflict_port": int(_episode.get("blocked_target", {}).get("port", 0)),
		"conflict_version": str(_episode.get("blocked_target", {}).get("version", "")),
		"keep_alive": bool(_plan.get("keep_alive", false)),
	}


func get_server_pid() -> int:
	return int(_process_grant.process_id()) if _process_grant != null else -1


func is_connection_blocked() -> bool:
	return str(_episode.get("state")) != READY


func has_managed_server() -> bool:
	return _process_grant != null and _process_grant.is_valid()


func can_restart_managed_server() -> bool:
	return has_managed_server()


func episode_snapshot() -> Dictionary:
	var snapshot := _episode.duplicate(true)
	var launch: Dictionary = snapshot.get("launch", {})
	launch.erase("http_capability")
	launch.erase("ws_capability")
	snapshot["launch"] = launch
	return snapshot


func authority_snapshot() -> Dictionary:
	return {
		"transport": _transport.public_snapshot() if _transport != null else {},
		"owned_pid": get_server_pid(),
		"replacement_available": _replacement_authorization != null,
	}


func _publish() -> void:
	snapshot_changed.emit(get_status_dict().duplicate(true))


static func _dormant_episode(episode_id: int) -> Dictionary:
	return {
		"id": episode_id, "state": DORMANT, "phase": "", "reason": "",
		"message": "Server lifecycle is dormant.", "ready_kind": "", "effect": "",
		"expected_version": "", "actual_version": "", "blocked_target": {},
		"launch": {}, "after_stop": "",
	}


static func _stopping_episode(episode_id: int, launch: Dictionary, after_stop: String) -> Dictionary:
	return {
		"id": episode_id, "state": STOPPING, "phase": "", "reason": "",
		"message": "Stopping the managed server.", "ready_kind": "", "effect": "",
		"expected_version": "", "actual_version": "", "blocked_target": {},
		"launch": launch, "after_stop": after_stop,
	}


static func _dock_state(state: String, reason: String) -> int:
	match state:
		DORMANT:
			return ServerState.STOPPED
		STARTING:
			return ServerState.SPAWNING
		READY:
			return ServerState.READY
		RECOVERING, STOPPING:
			return ServerState.STOPPING
		BLOCKED:
			match reason:
				"incompatible": return ServerState.INCOMPATIBLE
				"no_command": return ServerState.NO_COMMAND
				"port_reserved": return ServerState.PORT_EXCLUDED
				"occupied", "replacement_unproven": return ServerState.FOREIGN_PORT
				_: return ServerState.CRASHED
	return ServerState.UNINITIALIZED
