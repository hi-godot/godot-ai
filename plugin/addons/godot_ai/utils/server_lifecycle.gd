@tool
class_name McpServerLifecycleManager
extends RefCounted

## Server spawn / stop / respawn / adopt / recover orchestration plus the
## update-reload handoff. Owns the server-state machine
## (`McpServerState`), version-check seam (`McpServerVersionCheck`),
## adoption metadata, and connection-blocked / dev-mismatch flags.
##
## State previously lived on plugin.gd; PR 6 (#297) moved it here so
## PR 7 (UpdateManager extraction) can absorb the same encapsulation
## pattern. The plugin still owns the physical editor surfaces
## (Connection, Dock, Timer, EditorSettings I/O) and exposes them via
## `_host.<method>()` shims; the test fixtures override those shims to
## drive the manager without touching the editor.
##
## `_host` is untyped to honor the self-update parse-hazard policy
## plugin.gd calls out near `_connection`.
var _host

const UvCacheCleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
const McpServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const McpStartupPathScript := preload("res://addons/godot_ai/utils/mcp_startup_path.gd")
const McpAdoptionLabelScript := preload("res://addons/godot_ai/utils/mcp_adoption_label.gd")
const McpServerVersionCheckScript := preload("res://addons/godot_ai/utils/server_version_check.gd")

# ---- State (owned here, was on plugin.gd through PR 5) ---------------

## Single source of truth for the server-spawn/adopt/version lifecycle.
## See `McpServerState` for the transition table.
var _server_state: int = McpServerStateScript.UNINITIALIZED

## OS-level state populated only when WE spawned the process.
var _server_pid: int = -1
var _server_spawn_ms: int = 0
var _server_exit_ms: int = 0

## Version metadata. `expected_version` is what the plugin shipped with;
## `actual_version` is what the live server reported via handshake_ack.
var _server_expected_version: String = ""
var _server_actual_version: String = ""
var _server_actual_name: String = ""

## Diagnostic + recovery flags surfaced to the dock via `get_status()`.
var _server_status_message: String = ""
var _server_dev_version_mismatch_allowed: bool = false
var _can_recover_incompatible: bool = false
var _connection_blocked: bool = false

## One-shot guard for the stale-uvx-index recovery (#172). Reset at the
## top of `start_server` so each fresh spawn attempt gets its own
## refresh budget.
var _refresh_retried: bool = false

## Bounded deadline for the foreign-port adoption-confirmation watcher.
## Zero when disarmed.
var _adoption_watch_deadline_ms: int = 0

## Branch-tag from the most recent `start_server` walk. See
## `McpStartupPath`. Drives the startup-trace log.
var _startup_path: String = McpStartupPathScript.UNSET

## Version-check seam. Lazily constructed on `arm_version_check` so
## tests that exercise the manager without a connection don't have to
## stub it out.
var _version_check


func _init(host) -> void:
	_host = host


# ---- Public state accessors --------------------------------------------

func get_state() -> int:
	return _server_state


func get_status_dict() -> Dictionary:
	return {
		"state": _server_state,
		"exit_ms": _server_exit_ms,
		"actual_name": _server_actual_name,
		"actual_version": _server_actual_version,
		"expected_version": _server_expected_version,
		"message": _server_status_message,
		"dev_version_mismatch_allowed": _server_dev_version_mismatch_allowed,
		"can_recover_incompatible": _can_recover_incompatible,
		"connection_blocked": _connection_blocked,
	}


func get_server_pid() -> int:
	return _server_pid


func get_startup_path() -> String:
	return _startup_path


func get_adoption_watch_deadline_ms() -> int:
	return _adoption_watch_deadline_ms


func is_awaiting_server_version() -> bool:
	return _version_check != null and _version_check.is_active()


func is_connection_blocked() -> bool:
	return _connection_blocked


# ---- State-machine entry points ---------------------------------------

## Validated transition. Returns true on success; false (and logs a
## warning) when the transition is illegal under `McpServerState`'s
## table. Callers that need first-writer-wins among terminal diagnoses
## use `set_terminal_diagnosis` instead — that helper silently no-ops
## without warning when the diagnosis would be a regression.
func transition_state(target: int) -> bool:
	if _server_state == target:
		return true
	if not McpServerStateScript.can_transition(_server_state, target):
		push_warning(
			"MCP | rejected illegal state transition %s -> %s"
			% [
				McpServerStateScript.name_of(_server_state),
				McpServerStateScript.name_of(target),
			]
		)
		return false
	_server_state = target
	return true


## First-writer-wins mutator for terminal diagnoses (CRASHED,
## NO_COMMAND, PORT_EXCLUDED, INCOMPATIBLE, FOREIGN_PORT). Used during
## spawn to make sure a late watch-loop CRASHED doesn't clobber an
## earlier proactive PORT_EXCLUDED. Silent no-op when the current state
## is already a terminal diagnosis — the existing diagnosis is kept.
func set_terminal_diagnosis(target: int) -> bool:
	if not McpServerStateScript.is_terminal_diagnosis(target):
		push_warning(
			"MCP | set_terminal_diagnosis called with non-terminal %s"
			% McpServerStateScript.name_of(target)
		)
		return false
	if McpServerStateScript.is_terminal_diagnosis(_server_state):
		return false
	_server_state = target
	return true


# ---- Adoption confirmation watcher -------------------------------------

## Arm the FOREIGN_PORT adoption-confirmation watcher. SPAWN_GRACE_MS
## ahead of `now`; `tick_adoption_watch` self-disarms after this expires
## so per-frame cost drops back to zero on a permanent foreign occupant.
func arm_adoption_watch() -> void:
	_adoption_watch_deadline_ms = (
		Time.get_ticks_msec() + int(_host.SPAWN_GRACE_MS)
	)


func disarm_adoption_watch() -> void:
	_adoption_watch_deadline_ms = 0


func tick_adoption_watch(now_msec: int) -> void:
	if _adoption_watch_deadline_ms > 0 and now_msec >= _adoption_watch_deadline_ms:
		_adoption_watch_deadline_ms = 0


# ---- Server version-check seam ----------------------------------------

func arm_version_check(connection, expected_version: String) -> void:
	if _version_check == null:
		_version_check = McpServerVersionCheckScript.new(self)
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	_version_check.arm(connection, expected)


func disarm_version_check() -> void:
	if _version_check != null:
		_version_check.disarm()


func get_version_check():
	return _version_check


## Resolves a possibly-empty expected version to the plugin's shipping
## version. Manager methods that are called via test fixtures may
## receive an empty string when the test never seeded
## `_server_expected_version`, so this is the one place that fallback
## lives.
func _resolve_expected_version(supplied: String) -> String:
	if not supplied.is_empty():
		return supplied
	return _expected_server_version()


func _expected_server_version() -> String:
	return ClientConfigurator.get_plugin_version()


## Called by McpServerVersionCheck when handshake_ack carries a version
## string. Decides compatible vs incompatible and transitions the state.
func handle_server_version_verified(expected_version: String, version: String) -> void:
	_server_actual_name = "godot-ai"
	_server_actual_version = version
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	var compatibility := _server_version_compatibility(
		version,
		expected,
		ClientConfigurator.is_dev_checkout()
	)
	if compatibility.get("compatible", false):
		_can_recover_incompatible = false
		_server_dev_version_mismatch_allowed = bool(
			compatibility.get("dev_mismatch_allowed", false)
		)
		if _server_dev_version_mismatch_allowed:
			_server_status_message = (
				"Using dev server v%s with plugin v%s "
				+ "(dev checkout version mismatch allowed)."
			) % [version, expected]
		## Foreign-port and post-spawn handshakes both clear to READY
		## on a successful handshake. Late re-arms from READY also land
		## here and self-confirm.
		transition_state(McpServerStateScript.READY)
		_host._update_process_enabled()
		return
	var live := {"version": version, "status_code": 200, "name": "godot-ai"}
	_set_incompatible_server(live, expected, ClientConfigurator.http_port())
	if _host._connection != null:
		_host._connection.connect_blocked = true
		_host._connection.connect_block_reason = _server_status_message
		_host._connection.disconnect_from_server()
	_host._update_process_enabled()


func handle_server_version_unverified(expected_version: String) -> void:
	var expected := _resolve_expected_version(expected_version)
	_server_expected_version = expected
	var live := {"version": "", "status_code": 0, "error": "missing_handshake_ack"}
	_set_incompatible_server(live, expected, ClientConfigurator.http_port())
	if _host._connection != null:
		_host._connection.connect_blocked = true
		_host._connection.connect_block_reason = _server_status_message
		_host._connection.disconnect_from_server()
	_host._update_process_enabled()


# ---- Compatibility / version helpers (pure) ---------------------------

static func _server_version_compatibility(
	actual_version: String,
	expected_version: String,
	is_dev_checkout: bool
) -> Dictionary:
	if actual_version.is_empty():
		return {"compatible": false, "reason": "unknown", "dev_mismatch_allowed": false}
	if actual_version == expected_version:
		return {"compatible": true, "reason": "exact", "dev_mismatch_allowed": false}
	if is_dev_checkout:
		return {"compatible": true, "reason": "dev_mismatch", "dev_mismatch_allowed": true}
	return {"compatible": false, "reason": "version_mismatch", "dev_mismatch_allowed": false}


static func _server_status_compatibility(
	actual_version: String,
	expected_version: String,
	actual_ws_port: int,
	expected_ws_port: int,
	is_dev_checkout: bool,
) -> Dictionary:
	var version_result := _server_version_compatibility(
		actual_version,
		expected_version,
		is_dev_checkout
	)
	if not bool(version_result.get("compatible", false)):
		return version_result
	if actual_ws_port != expected_ws_port:
		return {"compatible": false, "reason": "ws_port_mismatch", "dev_mismatch_allowed": false}
	return version_result


static func _managed_record_has_version_drift(record_version: String, current_version: String) -> bool:
	return not record_version.is_empty() and record_version != current_version


# ---- Incompatible-server bookkeeping ----------------------------------

func _set_incompatible_server(live: Dictionary, expected_version: String, port: int) -> void:
	## Latches the incompatible diagnosis into manager state and asks
	## the dock to re-sweep client rows so they don't show stale green.
	## Threads the caller's `live` snapshot through the recovery proof
	## helper so we don't double-probe the port (~500ms each).
	transition_state(McpServerStateScript.INCOMPATIBLE)
	_connection_blocked = true
	_server_expected_version = expected_version
	_server_actual_name = str(live.get("name", ""))
	_server_actual_version = _live_version_for_message(live)
	_server_dev_version_mismatch_allowed = false
	_server_status_message = _incompatible_server_message(
		live, expected_version, port, int(_host._resolved_ws_port)
	)
	var proof: Dictionary = _host._evaluate_recovery_port_occupant_proof(port, live)
	var proof_name := str(proof.get("proof", ""))
	_can_recover_incompatible = not proof_name.is_empty()
	print("MCP | proof: %s" % (proof_name if _can_recover_incompatible else "(none)"))
	_host._refresh_dock_client_statuses()


static func _incompatible_server_message(
	live: Dictionary,
	expected_version: String,
	port: int,
	expected_ws_port: int
) -> String:
	var version := _live_version_for_message(live)
	var actual_ws_port := _live_ws_port_for_message(live)
	if not version.is_empty():
		if actual_ws_port > 0 and actual_ws_port != expected_ws_port:
			return (
				"Port %d is occupied by godot-ai server v%s using WS port %d; "
				+ "plugin expects v%s with WS port %d. Stop the old server or "
				+ "change both HTTP and WS ports."
			) % [port, version, actual_ws_port, expected_version, expected_ws_port]
		return (
			"Port %d is occupied by godot-ai server v%s; plugin expects v%s. "
			+ "Stop the old server or change both HTTP and WS ports."
		) % [port, version, expected_version]
	var status_code := int(live.get("status_code", 0))
	if status_code > 0:
		return (
			"Port %d is occupied by an unverified server (status endpoint returned HTTP %d); "
			+ "plugin expects godot-ai v%s. Stop the other server or change both HTTP and WS ports."
		) % [port, status_code, expected_version]
	return (
		"Port %d is occupied by another process; plugin expects godot-ai v%s. "
		+ "Stop the other process or change both HTTP and WS ports."
	) % [port, expected_version]


static func _live_status_identifies_godot_ai(live: Dictionary) -> bool:
	return str(live.get("name", "")) == "godot-ai"


static func _live_version_for_message(live: Dictionary) -> String:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return ""
	return str(live.get("version", ""))


static func _live_ws_port_for_message(live: Dictionary) -> int:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return 0
	return int(live.get("ws_port", 0))


# ---- start_server / spawn watch / respawn -----------------------------

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
		_startup_path = McpStartupPathScript.GUARDED
		transition_state(McpServerStateScript.GUARDED)
		return

	_refresh_retried = false

	var port := ClientConfigurator.http_port()
	var ws_port := ClientConfigurator.ws_port()
	var current_version := _expected_server_version()
	_server_expected_version = current_version

	if bool(_host._is_port_in_use(port)):
		var record: Dictionary = _host._read_managed_server_record()
		var record_version := str(record.get("version", ""))
		var record_ws_port := int(record.get("ws_port", 0))
		_host._set_resolved_ws_port(PortResolver.resolved_ws_port_for_existing_server(
			record_ws_port,
			record_version,
			current_version,
			int(_host._resolve_ws_port())
		))
		ws_port = int(_host._resolved_ws_port)
		var live: Dictionary = _host._probe_live_server_status_for_port(port)
		var live_version := str(_host._verified_status_version(live))
		var live_ws_port := int(_host._verified_status_ws_port(live))
		var compatibility: Dictionary = _server_status_compatibility(
			live_version,
			current_version,
			live_ws_port,
			ws_port,
			ClientConfigurator.is_dev_checkout()
		)
		if compatibility.get("compatible", false):
			_server_actual_name = "godot-ai"
			_server_actual_version = live_version
			_can_recover_incompatible = false
			_server_dev_version_mismatch_allowed = bool(compatibility.get("dev_mismatch_allowed", false))
			if bool(_server_dev_version_mismatch_allowed):
				_server_status_message = (
					"Using dev server v%s on WS port %d with plugin v%s "
					+ "(dev checkout version mismatch allowed)."
				) % [str(_server_actual_version), live_ws_port, current_version]
			var owner := int(_host._find_managed_pid(port))
			var owner_label := adopt_compatible_server(record_version, current_version, owner)
			_host._server_started_this_session = true
			_startup_path = McpStartupPathScript.ADOPTED
			transition_state(McpServerStateScript.READY)
			print(_compatible_adoption_log_message(
				owner_label,
				int(_server_pid),
				owner,
				str(_server_actual_version),
				live_ws_port,
				current_version
			))
			return
		if bool(_managed_record_has_version_drift(record_version, current_version)):
			print("MCP | managed server v%s does not match plugin v%s, restarting"
				% [record_version, current_version])
		## Forward `live` so the recovery proof helper reuses our snapshot.
		## The kill invalidates it, so the failure arm re-probes below.
		if not recover_strong_port_occupant(port, 3.0, live):
			_host._server_started_this_session = true
			var post_recovery_live: Dictionary = _host._probe_live_server_status_for_port(port)
			_set_incompatible_server(post_recovery_live, current_version, port)
			_startup_path = McpStartupPathScript.INCOMPATIBLE
			push_warning(str(_server_status_message))
			return
	else:
		_startup_path = McpStartupPathScript.FREE

	_host._set_resolved_ws_port(_host._resolve_ws_port())
	ws_port = _host._resolved_ws_port

	_host._startup_trace_count("server_command_discovery")
	var server_cmd := ClientConfigurator.get_server_command()
	if server_cmd.is_empty():
		set_terminal_diagnosis(McpServerStateScript.NO_COMMAND)
		_startup_path = McpStartupPathScript.NO_COMMAND
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
	if WindowsPortReservation.is_port_excluded(port):
		_host._server_started_this_session = true
		set_terminal_diagnosis(McpServerStateScript.PORT_EXCLUDED)
		_startup_path = McpStartupPathScript.RESERVED
		push_warning("MCP | port %d is reserved by Windows (Hyper-V / WSL2 / Docker)" % port)
		return

	_server_pid = OS.create_process(cmd, args)
	var spawned_pid := int(_server_pid)
	if spawned_pid > 0:
		_server_spawn_ms = Time.get_ticks_msec()
		_server_exit_ms = 0
		_host._server_started_this_session = true
		transition_state(McpServerStateScript.SPAWNING)
		## Record the launcher PID so same-session
		## prepare_for_update_reload has something to kill. The next
		## editor start's adopt branch heals it to the real port owner.
		_host._write_managed_server_record(spawned_pid, current_version)
		_startup_path = McpStartupPathScript.SPAWNED
		print("MCP | started server (PID %d, v%s): %s %s" % [spawned_pid, current_version, cmd, " ".join(args)])
		_host._start_server_watch()
	else:
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		_startup_path = McpStartupPathScript.CRASHED
		push_warning("MCP | failed to start server")


## Watch-loop callback (1 Hz, capped by SERVER_WATCH_MS).
## `--pid-file` is the source of truth on Windows / uvx where the
## launcher PID dies quickly after spawning the real interpreter.
func check_server_health() -> void:
	if int(_server_pid) <= 0:
		_host._stop_server_watch()
		return
	var elapsed := Time.get_ticks_msec() - int(_server_spawn_ms)
	var real_pid := PortResolver.read_pid_file()
	var spawn_pid := int(_server_pid)
	if real_pid > 0 and real_pid != spawn_pid and PortResolver.pid_alive(real_pid):
		_server_pid = real_pid
	elif not PortResolver.pid_alive(spawn_pid):
		if elapsed >= int(_host.SPAWN_GRACE_MS) and not McpServerStateScript.is_terminal_diagnosis(_server_state):
			if bool(_host._should_retry_with_refresh()):
				_refresh_retried = true
				respawn_with_refresh()
				return
			_server_exit_ms = elapsed
			set_terminal_diagnosis(McpServerStateScript.CRASHED)
			disarm_version_check()
			_host._update_process_enabled()
			_host._log_buffer.log("server exited after %dms — see Godot output log" % int(_server_exit_ms))
			_host._stop_server_watch()
		return
	if elapsed >= int(_host.SERVER_WATCH_MS):
		## Survived startup — mid-session crashes surface via WebSocket disconnect.
		_host._stop_server_watch()


## Retry the spawn with uvx `--refresh` prepended (PyPI index can lag a
## fresh publish ~10 min — #172). One-shot per session via _refresh_retried.
func respawn_with_refresh() -> void:
	_host._startup_trace_count("server_command_discovery")
	var server_cmd := ClientConfigurator.get_server_command(true)
	if server_cmd.is_empty():
		return
	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(_host._build_server_flags(ClientConfigurator.http_port(), int(_host._resolved_ws_port)))
	_host._clear_pid_file()
	_host._log_buffer.log("retrying with --refresh (PyPI index may be stale)")
	_server_pid = OS.create_process(cmd, args)
	var spawn_pid := int(_server_pid)
	if spawn_pid > 0:
		_server_spawn_ms = Time.get_ticks_msec()
		_server_exit_ms = 0
		var current_version := _expected_server_version()
		_host._write_managed_server_record(spawn_pid, current_version)
		print("MCP | retried server (PID %d, v%s): %s %s" % [spawn_pid, current_version, cmd, " ".join(args)])
	else:
		## OS.create_process returned -1 on the retry — surface CRASHED
		## rather than loop. `_refresh_retried` is already true.
		set_terminal_diagnosis(McpServerStateScript.CRASHED)
		disarm_version_check()
		_host._update_process_enabled()
		_host._log_buffer.log("refresh retry failed to spawn — see Godot output log")
		_host._stop_server_watch()


func adopt_compatible_server(record_version: String, current_version: String, owner: int) -> String:
	_server_actual_name = "godot-ai"
	_can_recover_incompatible = false
	if record_version == current_version and owner > 0:
		_server_pid = owner
		_host._write_managed_server_record(owner, current_version)
		return McpAdoptionLabelScript.MANAGED
	_server_pid = -1
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	return McpAdoptionLabelScript.EXTERNAL


static func _compatible_adoption_log_message(
	owner_label: String,
	owned_pid: int,
	observed_owner_pid: int,
	live_version: String,
	live_ws_port: int,
	current_version: String
) -> String:
	if owner_label == McpAdoptionLabelScript.MANAGED:
		return "MCP | adopted managed server (PID %d, live v%s, WS %d, plugin v%s)" % [
			owned_pid,
			live_version,
			live_ws_port,
			current_version
		]
	return "MCP | adopted external server owner_pid=%d (live v%s, WS %d, plugin v%s)" % [
		observed_owner_pid,
		live_version,
		live_ws_port,
		current_version
	]


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
	if int(_server_pid) <= 0:
		transition_state(McpServerStateScript.STOPPED)
		return
	transition_state(McpServerStateScript.STOPPING)
	## Kill the tracked PID AND the real Python PID — they differ for the
	## uvx tier (the launcher exits before its child) and on Windows
	## `OS.kill` is `TerminateProcess` which doesn't walk the child tree.
	var port := ClientConfigurator.http_port()
	var killed: Array = []
	var candidates: Array[int] = [int(_server_pid)]
	var real_pid := int(_host._find_managed_pid(port))
	if real_pid > 0 and (
		candidates.has(real_pid)
		or _host._pid_cmdline_is_godot_ai_for_proof(real_pid)
	):
		candidates.append(real_pid)
	var listener_pids: Array = _host._find_all_pids_on_port(port)
	for pid in listener_pids:
		var listener_pid := int(pid)
		if candidates.has(listener_pid):
			candidates.append(listener_pid)
		elif _host._pid_cmdline_is_godot_ai_for_proof(listener_pid):
			candidates.append(listener_pid)
	killed = _host._kill_processes_and_windows_spawn_children(candidates)
	if not killed.is_empty():
		print("MCP | stopped server (PID %s)" % str(killed))
	_server_pid = -1
	_host._wait_for_port_free(port, 2.0)
	## Preserve record/pid-file when port is still held — the drift
	## branch on the next start_server retries the kill (#159 follow-up).
	_host._finalize_stop_if_port_free(port)
	transition_state(McpServerStateScript.STOPPED)

	## Server's `_pydantic_core.pyd` hard-link is now released — sweep
	## stale uvx builds before they trip the next `uvx mcp-proxy`.
	UvCacheCleanup.purge_stale_builds()


## Kill the server, reset the re-entrancy guard so the re-enabled plugin
## spawns fresh (#132). User-mode only kills via strong proof.
func prepare_for_update_reload() -> void:
	stop_server()
	_host._server_started_this_session = false
	if ClientConfigurator.is_dev_checkout():
		return

	var port := ClientConfigurator.http_port()
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


# ---- Recovery click ----------------------------------------------------

## Returns true when a pure-state probe says recovery is allowed:
## current state is INCOMPATIBLE, the port is still held, and we have
## proof of ownership over the occupant. Pure-state in the sense that
## nothing is killed — that's `recover_incompatible_server`.
func can_recover_incompatible_server() -> bool:
	if _server_state != McpServerStateScript.INCOMPATIBLE:
		return false
	var port := ClientConfigurator.http_port()
	if not bool(_host._is_port_in_use(port)):
		return false
	var proof: Dictionary = _host._evaluate_recovery_port_occupant_proof(port)
	return not str(proof.get("proof", "")).is_empty()


func recover_incompatible_server() -> bool:
	if _server_state != McpServerStateScript.INCOMPATIBLE:
		return false

	var port := ClientConfigurator.http_port()
	var proof: Dictionary = _host._evaluate_recovery_port_occupant_proof(port)
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false
	print("MCP | proof: %s" % str(proof.get("proof", "")))

	## Move into STOPPING so the post-kill respawn passes the
	## first-writer-wins guards.
	transition_state(McpServerStateScript.STOPPING)
	var killed: Array = _host._kill_processes_and_windows_spawn_children(targets)
	if not killed.is_empty():
		print("MCP | killed pids %s on port %d" % [str(killed), port])
	_host._wait_for_port_free(port, 5.0)
	if _host._is_port_in_use(port):
		## Kill failed; re-latch INCOMPATIBLE so the dock keeps the
		## diagnostic UI.
		transition_state(McpServerStateScript.INCOMPATIBLE)
		return false

	UvCacheCleanup.purge_stale_builds()
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	transition_state(McpServerStateScript.STOPPED)
	_connection_blocked = false
	_server_status_message = ""
	_server_actual_version = ""
	_server_actual_name = ""
	_can_recover_incompatible = false
	_host._server_started_this_session = false
	_server_pid = -1
	start_server()
	return true


## Restart authorisation — a live PID means we spawned/adopted, a
## non-empty managed record is the cross-session proof used by the
## drift branch.
func can_restart_managed_server() -> bool:
	if _server_pid > 0:
		return true
	var record: Dictionary = _host._read_managed_server_record()
	return not str(record.get("version", "")).is_empty()


func has_managed_server() -> bool:
	return _server_pid > 0


## Reset state for a force-restart. Drops the managed record, clears
## the pid-file, and resets the spawn guard so the follow-up
## `start_server()` walks the spawn arm.
func reset_for_force_restart() -> void:
	_host._clear_managed_server_record()
	_host._clear_pid_file()
	_host._server_started_this_session = false
	_server_pid = -1
	transition_state(McpServerStateScript.UNINITIALIZED)


## Ownership-checked kill of the port occupant + respawn. Driven from
## the dock's "Restart Server" button when the plugin adopted a foreign
## server whose version drifted from the plugin.
func force_restart_server() -> void:
	if not can_restart_managed_server():
		push_warning("MCP | refusing to kill server on port %d without managed-server ownership proof"
			% ClientConfigurator.http_port())
		return
	var port := ClientConfigurator.http_port()
	## Kill every LISTENER on the port, not just the first one. A dev
	## server run via `uvicorn --reload` owns port 8000 through both a
	## reloader parent AND a worker child — killing only one (or zero,
	## if the single-pid parse fell over on multi-line lsof output) leaves
	## the other holding the port past `_wait_for_port_free`'s window.
	transition_state(McpServerStateScript.STOPPING)
	_host._kill_processes_and_windows_spawn_children(_host._find_all_pids_on_port(port))
	_host._wait_for_port_free(port, 5.0)
	if _host._is_port_in_use(port):
		## Kill failed; clean baseline for the follow-up
		## `_set_incompatible_server`.
		transition_state(McpServerStateScript.UNINITIALIZED)
		_set_incompatible_server(
			_host._probe_live_server_status_for_port(port),
			_expected_server_version(),
			port
		)
		return
	## Same rationale as `stop_server`: the server child python just
	## released its `pydantic_core` mapping, so this is the only window in
	## which the hard-linked copies under `builds-v0\.tmp*` are deletable.
	## Sweep before respawning so the upcoming `uvx mcp-proxy` build doesn't
	## inherit the same cleanup-failure path that triggered the restart.
	UvCacheCleanup.purge_stale_builds()
	reset_for_force_restart()
	start_server()
