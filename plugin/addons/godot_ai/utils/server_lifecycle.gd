@tool
class_name McpServerLifecycleManager
extends RefCounted

## Server spawn / stop / respawn / adopt / recover orchestration plus the
## update-reload handoff. Reads and writes plugin state through `_host`
## so the PR 4 characterization fixtures' overrides of plugin-instance
## hooks (`_find_all_pids_on_port`, `_read_managed_server_record`,
## `_is_port_in_use`, …) keep landing.
##
## `_host` is untyped to honor the same self-update parse-hazard policy
## plugin.gd calls out near `_connection`.
var _host

const UvCacheCleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")


func _init(host) -> void:
	_host = host


## Branch table (recorded version is the "is this ours?" signal — uvx
## launcher PIDs go stale; #135/#137):
##   port free                                -> spawn fresh, record PID
##   port in use, record matches + live ok   -> adopt port owner (heals PID)
##   port in use, record drifts              -> kill owner + respawn
##   port in use, no verified live match     -> block adoption + warn
func start_server() -> void:
	if _host._server_started_this_session:
		## Static flag persists across disable/enable cycles in one editor
		## session — re-entrant spawn guard for plugin-reload-during-update.
		_host._startup_path = "guarded"
		return

	_host._refresh_retried = false

	var port := McpClientConfigurator.http_port()
	var ws_port := McpClientConfigurator.ws_port()
	var current_version := McpClientConfigurator.get_plugin_version()
	_host._server_expected_version = current_version

	if bool(_host._is_port_in_use(port)):
		var record: Dictionary = _host._read_managed_server_record()
		var record_version := str(record.get("version", ""))
		var record_ws_port := int(record.get("ws_port", 0))
		_host._set_resolved_ws_port(McpPortResolver.resolved_ws_port_for_existing_server(
			record_ws_port,
			record_version,
			current_version,
			int(_host._resolve_ws_port())
		))
		ws_port = int(_host._resolved_ws_port)
		var live: Dictionary = _host._probe_live_server_status_for_port(port)
		var live_version := str(_host._verified_status_version(live))
		var live_ws_port := int(_host._verified_status_ws_port(live))
		var compatibility: Dictionary = _host._server_status_compatibility(
			live_version,
			current_version,
			live_ws_port,
			ws_port,
			McpClientConfigurator.is_dev_checkout()
		)
		if compatibility.get("compatible", false):
			_host._server_actual_name = "godot-ai"
			_host._server_actual_version = live_version
			_host._can_recover_incompatible = false
			_host._server_dev_version_mismatch_allowed = bool(compatibility.get("dev_mismatch_allowed", false))
			if bool(_host._server_dev_version_mismatch_allowed):
				_host._server_status_message = (
					"Using dev server v%s on WS port %d with plugin v%s "
					+ "(dev checkout version mismatch allowed)."
				) % [str(_host._server_actual_version), live_ws_port, current_version]
			var owner := int(_host._find_managed_pid(port))
			var owner_label := adopt_compatible_server(record_version, current_version, owner)
			_host._server_started_this_session = true
			_host._startup_path = "adopted"
			print(_host._compatible_adoption_log_message(
				owner_label,
				int(_host._server_pid),
				owner,
				str(_host._server_actual_version),
				live_ws_port,
				current_version
			))
			return
		if bool(_host._managed_record_has_version_drift(record_version, current_version)):
			print("MCP | managed server v%s does not match plugin v%s, restarting"
				% [record_version, current_version])
		## Forward `live` so the recovery proof helper reuses our snapshot.
		## The kill invalidates it, so the failure arm re-probes below.
		if not recover_strong_port_occupant(port, 3.0, live):
			_host._server_started_this_session = true
			var post_recovery_live: Dictionary = _host._probe_live_server_status_for_port(port)
			_host._set_incompatible_server(post_recovery_live, current_version, port)
			_host._startup_path = "incompatible"
			push_warning(str(_host._server_status_message))
			return
	else:
		_host._startup_path = "free"

	_host._set_resolved_ws_port(_host._resolve_ws_port())
	ws_port = _host._resolved_ws_port

	_host._startup_trace_count("server_command_discovery")
	var server_cmd := McpClientConfigurator.get_server_command()
	if server_cmd.is_empty():
		_host._set_spawn_state(McpSpawnState.NO_COMMAND)
		_host._startup_path = "no_command"
		push_warning("MCP | could not find server command")
		return

	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(_host._build_server_flags(port, ws_port))

	## Wipe any stale pid-file so a failed launch can't leave last
	## session's PID for `_find_managed_pid` to read.
	_host._clear_pid_file()

	## Proactive Windows port-reservation check (#146) — bind would
	## fail silently with WinError 10013 inside a Hyper-V / WSL2 /
	## Docker exclusion range; netstat shows nothing.
	if McpWindowsPortReservation.is_port_excluded(port):
		_host._server_started_this_session = true
		_host._set_spawn_state(McpSpawnState.PORT_EXCLUDED)
		_host._startup_path = "reserved"
		push_warning("MCP | port %d is reserved by Windows (Hyper-V / WSL2 / Docker)" % port)
		return

	_host._server_pid = OS.create_process(cmd, args)
	var spawned_pid := int(_host._server_pid)
	if spawned_pid > 0:
		_host._server_spawn_ms = Time.get_ticks_msec()
		_host._server_exit_ms = 0
		_host._server_started_this_session = true
		## Record the launcher PID so same-session
		## prepare_for_update_reload has something to kill. The next
		## editor start's adopt branch heals it to the real port owner.
		_host._write_managed_server_record(spawned_pid, current_version)
		_host._startup_path = "spawned"
		print("MCP | started server (PID %d, v%s): %s %s" % [spawned_pid, current_version, cmd, " ".join(args)])
		_host._start_server_watch()
	else:
		_host._set_spawn_state(McpSpawnState.CRASHED)
		_host._startup_path = "crashed"
		push_warning("MCP | failed to start server")


## Watch-loop callback (1 Hz, capped by SERVER_WATCH_MS).
## `--pid-file` is the source of truth on Windows / uvx where the
## launcher PID dies quickly after spawning the real interpreter.
func check_server_health() -> void:
	if int(_host._server_pid) <= 0:
		_host._stop_server_watch()
		return
	var elapsed := Time.get_ticks_msec() - int(_host._server_spawn_ms)
	var real_pid := McpPortResolver.read_pid_file()
	var server_pid := int(_host._server_pid)
	if real_pid > 0 and real_pid != server_pid and McpPortResolver.pid_alive(real_pid):
		_host._server_pid = real_pid
	elif not McpPortResolver.pid_alive(server_pid):
		if elapsed >= int(_host.SPAWN_GRACE_MS) and str(_host._spawn_state) == McpSpawnState.OK:
			if bool(_host._should_retry_with_refresh()):
				_host._refresh_retried = true
				respawn_with_refresh()
				return
			_host._server_exit_ms = elapsed
			_host._set_spawn_state(McpSpawnState.CRASHED)
			_host._awaiting_server_version = false
			_host._server_version_deadline_ms = 0
			_host._update_process_enabled()
			_host._log_buffer.log("server exited after %dms — see Godot output log" % int(_host._server_exit_ms))
			_host._stop_server_watch()
		return
	if elapsed >= int(_host.SERVER_WATCH_MS):
		## Survived startup — mid-session crashes surface via WebSocket disconnect.
		_host._stop_server_watch()


## Retry the spawn with uvx `--refresh` prepended (PyPI index can lag a
## fresh publish ~10 min — #172). One-shot per session via _refresh_retried.
func respawn_with_refresh() -> void:
	_host._startup_trace_count("server_command_discovery")
	var server_cmd := McpClientConfigurator.get_server_command(true)
	if server_cmd.is_empty():
		return
	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(_host._build_server_flags(McpClientConfigurator.http_port(), int(_host._resolved_ws_port)))
	_host._clear_pid_file()
	_host._log_buffer.log("retrying with --refresh (PyPI index may be stale)")
	_host._server_pid = OS.create_process(cmd, args)
	var server_pid := int(_host._server_pid)
	if server_pid > 0:
		_host._server_spawn_ms = Time.get_ticks_msec()
		_host._server_exit_ms = 0
		var current_version := McpClientConfigurator.get_plugin_version()
		_host._write_managed_server_record(server_pid, current_version)
		print("MCP | retried server (PID %d, v%s): %s %s" % [server_pid, current_version, cmd, " ".join(args)])
	else:
		## OS.create_process returned -1 on the retry — surface CRASHED
		## rather than loop. `_refresh_retried` is already true.
		_host._set_spawn_state(McpSpawnState.CRASHED)
		_host._awaiting_server_version = false
		_host._server_version_deadline_ms = 0
		_host._update_process_enabled()
		_host._log_buffer.log("refresh retry failed to spawn — see Godot output log")
		_host._stop_server_watch()


func adopt_compatible_server(record_version: String, current_version: String, owner: int) -> String:
	_host._server_actual_name = "godot-ai"
	_host._can_recover_incompatible = false
	if record_version == current_version and owner > 0:
		_host._server_pid = owner
		_host._write_managed_server_record(owner, current_version)
		return "managed"
	_host._server_pid = -1
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return "external"


## `pre_kill_live` is forwarded into the proof helper so it doesn't
## re-probe a port the caller already probed. The kill invalidates the
## snapshot — callers MUST re-probe before consuming live-status data
## after this returns.
func recover_strong_port_occupant(port: int, wait_s: float, pre_kill_live: Dictionary = {}) -> bool:
	var proof: Dictionary = _host._evaluate_strong_port_occupant_proof(port, pre_kill_live)
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false

	print("MCP | strong proof: %s" % str(proof.get("proof", "")))
	var killed: Array = _host._kill_processes_and_windows_spawn_children(targets)
	if not killed.is_empty():
		print("MCP | killed pids %s on port %d" % [str(killed), port])
	_host._wait_for_port_free(port, wait_s)
	if bool(_host._is_port_in_use(port)):
		return false

	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return true


func stop_server() -> void:
	_host._stop_server_watch()
	if int(_host._server_pid) <= 0:
		return
	## Kill the tracked PID AND the real Python PID — they differ for the
	## uvx tier (the launcher exits before its child) and on Windows
	## `OS.kill` is `TerminateProcess` which doesn't walk the child tree.
	var port := McpClientConfigurator.http_port()
	var killed: Array = []
	var candidates: Array[int] = [int(_host._server_pid)]
	var real_pid := int(_host._find_managed_pid(port))
	if real_pid > 0:
		candidates.append(real_pid)
	var listener_pids: Array = _host._find_all_pids_on_port(port)
	for pid in listener_pids:
		candidates.append(int(pid))
	killed = _host._kill_processes_and_windows_spawn_children(candidates)
	if not killed.is_empty():
		print("MCP | stopped server (PID %s)" % str(killed))
	_host._server_pid = -1
	_host._wait_for_port_free(port, 2.0)
	## Preserve record/pid-file when port is still held — the drift
	## branch on the next start_server retries the kill (#159 follow-up).
	_host._finalize_stop_if_port_free(port)

	## Server's `_pydantic_core.pyd` hard-link is now released — sweep
	## stale uvx builds before they trip the next `uvx mcp-proxy`.
	UvCacheCleanup.purge_stale_builds()


## Kill the server, reset the re-entrancy guard so the re-enabled plugin
## spawns fresh (#132). User-mode only kills via strong proof.
func prepare_for_update_reload() -> void:
	stop_server()
	_host._server_started_this_session = false
	if McpClientConfigurator.is_dev_checkout():
		return

	var port := McpClientConfigurator.http_port()
	if not bool(_host._is_port_in_use(port)):
		return

	var proof: Dictionary = _host._evaluate_strong_port_occupant_proof(port)
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return

	_host._kill_processes_and_windows_spawn_children(targets)
	_host._wait_for_port_free(port, 3.0)
	if not bool(_host._is_port_in_use(port)):
		_host._clear_managed_server_record()
		_host._clear_pid_file()
