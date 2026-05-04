@tool
class_name McpServerLifecycleManager
extends RefCounted

## Server lifecycle orchestration extracted from plugin.gd.
##
## Owns the spawn / stop / respawn / adopt / recover paths plus the
## update-reload handoff. Was inline in plugin.gd until #297 / PR 5; the
## extraction is line-count surgery only — the methods retain their exact
## semantics and observable behavior, including ordering, log messages,
## and the static spawn-guard contract.
##
## Why a `_host` reference instead of pure injection: the PR 4
## characterization suite (`_ProofPlugin extends GodotAiPlugin`) overrides
## a slate of plugin-instance hooks (`_find_all_pids_on_port`,
## `_read_managed_server_record`, `_pid_cmdline_is_godot_ai_for_proof`,
## `_probe_live_server_status_for_port`, `_is_port_in_use`,
## `_kill_processes_and_windows_spawn_children`, `_wait_for_port_free`,
## `_clear_managed_server_record`) and pokes plugin-instance state
## (`_spawn_state`, `_server_pid`, `_connection_blocked`, …). Those tests
## are the regression net for #159 / #259 / #297 PR 3, and the PR 5
## extraction must not regress them. Reaching state and overridable hooks
## through `_host` keeps that surface stable. PR 6 will revisit the state
## model and may cut more of these knots; for now, behavior preservation
## wins over conceptual purity.

## Held untyped on purpose so the script-load step doesn't depend on
## plugin.gd's class registration order, mirroring the same parse-hazard
## policy the plugin file calls out near `_connection`.
var _host

const UvCacheCleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")


func _init(host) -> void:
	_host = host


## Branch on port state + EditorSettings record. The record lets a later
## editor session recognize and manage a server it didn't spawn itself;
## treating the stored `version` (not `pid`) as the "is this ours?" signal
## handles the uvx tier, where the recorded PID is a launcher that has
## long since exited. See #135 and #137.
##
##   port free                            -> spawn fresh, record PID
##   port in use, record.version matches
##        + live verification passes       -> adopt the port owner
##                                              (self-heals stale PID)
##   port in use, record.version drifts   -> kill port owner + respawn
##                                              (fixes cold-start drift
##                                              from manual file replace)
##   port in use, no verified live match  -> block adoption + warn
func start_server() -> void:
	if _host._server_started_this_session:
		## Guard against re-entrant spawns (e.g. plugin reload during update).
		## The static flag persists across disable/enable cycles within the
		## same editor session, preventing cascading server process creation.
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
		## Trust the cached WS port from the managed record only when the
		## record is current ownership proof — see plugin.gd::_start_server
		## for the full WS-port + record-version rationale (#259).
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
			## Version verified — port speaks current-compatible godot-ai.
			## If the managed record matches, adopt ownership and self-heal
			## its PID. Otherwise reuse external/dev server without recording
			## ownership, so plugin unloads never kill it.
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
		## `live` is forwarded so the recovery path's proof helpers reuse
		## the snapshot we already paid for. The kill itself invalidates
		## that snapshot, so the failure-mode arm below re-probes before
		## handing data to `_set_incompatible_server`.
		if not recover_strong_port_occupant(port, 3.0, live):
			_host._server_started_this_session = true
			var post_recovery_live: Dictionary = _host._probe_live_server_status_for_port(port)
			_host._set_incompatible_server(post_recovery_live, current_version, port)
			_host._startup_path = "incompatible"
			push_warning(str(_host._server_status_message))
			return
		## Fall through to spawn.
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

	## Wipe any stale pid-file before spawning so a failed launch can't
	## leave last session's PID sitting there for `_find_managed_pid` to
	## read and act on.
	_host._clear_pid_file()

	## Proactive Windows port-reservation check — see plugin.gd::_start_server
	## (issue #146) for why we skip the spawn entirely when the port is
	## inside a Hyper-V / WSL2 / Docker reservation range.
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
		## Record the launcher PID immediately so a same-session
		## prepare_for_update_reload has something to kill. On the next
		## editor start, the adopt branch self-heals the PID to the actual
		## port owner (uvx's child).
		_host._write_managed_server_record(spawned_pid, current_version)
		_host._startup_path = "spawned"
		print("MCP | started server (PID %d, v%s): %s %s" % [spawned_pid, current_version, cmd, " ".join(args)])
		_host._start_server_watch()
	else:
		_host._set_spawn_state(McpSpawnState.CRASHED)
		_host._startup_path = "crashed"
		push_warning("MCP | failed to start server")


## Watch-loop callback — fires every second up to SERVER_WATCH_MS. See
## plugin.gd::_check_server_health for the "pid-file is the source of
## truth on Windows / uvx" rationale and the SPAWN_GRACE_MS interaction.
func check_server_health() -> void:
	if int(_host._server_pid) <= 0:
		_host._stop_server_watch()
		return
	var elapsed := Time.get_ticks_msec() - int(_host._server_spawn_ms)
	## Python writes its real PID to `--pid-file` right after argparse —
	## before the heavy imports. On Windows launchers (uvx) the direct
	## child can exit quickly after spawning the real interpreter, so the
	## pid-file is more reliable than `_server_pid` for liveness. Adopt
	## the real PID whenever we see a live one; fall back to _server_pid
	## otherwise.
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
		## Server survived startup — stop watching. Mid-session crashes
		## after this point surface via the WebSocket disconnect path.
		_host._stop_server_watch()


## Re-run `OS.create_process` with `--refresh` prepended to the uvx args
## and reset the watch-loop baseline so the next tick evaluates the new
## process, not the dead one. See plugin.gd::_respawn_with_refresh for
## the full ownership / record handling rationale.
func respawn_with_refresh() -> void:
	_host._startup_trace_count("server_command_discovery")
	var server_cmd := McpClientConfigurator.get_server_command(true)
	if server_cmd.is_empty():
		## Can't happen in practice — we only reach here after a successful
		## first resolve at the top of `start_server()` — but keep the shape
		## symmetric so a future refactor doesn't silently break the retry.
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
		## OS.create_process returned -1 on the retry — can't distinguish
		## from a real crash, so surface CRASHED immediately rather than
		## looping. `_refresh_retried` is already true so we won't try again.
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


## `pre_kill_live` is forwarded to `_evaluate_strong_port_occupant_proof`
## so the proof helper doesn't re-probe a port the caller already probed.
## The kill itself invalidates that snapshot — by the time this function
## returns, the caller must re-probe before consuming any live-status data.
## See plugin.gd::_recover_strong_port_occupant for the original docstring.
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
	## Kill both the process we tracked and the real Python PID if they
	## differ — see plugin.gd::_stop_server for the uvx-launcher /
	## TerminateProcess rationale.
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
	## Brief wait so a follow-up spawn doesn't race a still-closing socket.
	_host._wait_for_port_free(port, 2.0)
	## Only forget this server if the port is actually free — see
	## plugin.gd::_stop_server for the "preserve on failed kill" rationale.
	_host._finalize_stop_if_port_free(port)

	## Sweep stale `uvx` build venvs now that the server's hard-linked
	## `_pydantic_core.pyd` mapping is gone. Without this, the next
	## `uvx mcp-proxy` invocation from Claude Desktop's MCP launcher fails
	## to clean its build dir and the MCP transport never starts. See
	## `utils/uv_cache_cleanup.gd` for the full hard-link explanation.
	UvCacheCleanup.purge_stale_builds()


## Prepare for a plugin-self-update reload cycle: kill the server process
## and reset the re-entrancy guard so the re-enabled plugin spawns a fresh
## server. See plugin.gd::prepare_for_update_reload for the #132 rationale.
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
