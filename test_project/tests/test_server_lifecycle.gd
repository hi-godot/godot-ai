@tool
extends McpTestSuite

## Seam-level coverage for McpServerLifecycleManager. End-to-end behavior
## (drift kills, strong-proof recoveries, watch-loop crash detection) is
## still locked in by the PR 4 characterization suite in
## test_plugin_lifecycle.gd, which drives plugin.gd's public methods.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const McpServerLifecycleManagerScript := preload(
	"res://addons/godot_ai/utils/server_lifecycle.gd"
)


## Mirrors `_ProofPlugin` from test_plugin_lifecycle.gd, scoped to the
## hooks the manager actually touches. Note: state fields like
## `_server_pid` and `_server_state` live on the manager (PR 6, #297) —
## tests seed them via `manager._server_pid = ...` after construction
## rather than poking the host.
class _ManagerHostStub extends GodotAiPlugin:
	var listener_pids: Array[int] = []
	var managed_record := {"pid": 0, "version": "", "ws_port": 0}
	var live_status := {"name": "", "version": "", "ws_port": 0, "status_code": 0}
	var alive_pids: Array[int] = []
	var branded_pids: Array[int] = []
	var pid_file_pid := 0
	var managed_pid_lookup := 0
	var port_in_use := false
	var port_in_use_sequence: Array[bool] = []
	var killed_targets: Array[int] = []
	var cleared_record_calls := 0
	var stop_watch_calls := 0
	var finalize_calls := 0
	var probe_calls := 0

	func _find_all_pids_on_port(_port: int) -> Array[int]:
		var pids: Array[int] = []
		pids.assign(listener_pids)
		return pids

	func _read_managed_server_record() -> Dictionary:
		return managed_record.duplicate()

	func _read_pid_file_for_proof() -> int:
		return pid_file_pid

	func _pid_alive_for_proof(pid: int) -> bool:
		return alive_pids.has(pid)

	func _pid_cmdline_is_godot_ai_for_proof(pid: int) -> bool:
		return branded_pids.has(pid)

	func _probe_live_server_status_for_port(_port: int) -> Dictionary:
		probe_calls += 1
		return live_status.duplicate()

	## Deterministic false: the real helper consults the launch mode and the
	## on-disk pid-file, which vary across dev machines / CI. No test in this
	## suite exercises the uvx --refresh retry.
	func _should_retry_with_refresh() -> bool:
		return false

	func _is_port_in_use(_port: int) -> bool:
		if not port_in_use_sequence.is_empty():
			return bool(port_in_use_sequence.pop_front())
		return port_in_use

	func _kill_processes_and_windows_spawn_children(pids: Array[int], verify_brand: bool = false) -> Array[int]:
		var accepted: Array[int] = []
		for pid in pids:
			## Mirror production's kill-time re-check (#686) against the
			## stub's alive/branded lists so tests can exercise the
			## proof→kill TOCTOU gap.
			if verify_brand and not (alive_pids.has(pid) and branded_pids.has(pid)):
				continue
			accepted.append(pid)
			if not killed_targets.has(pid):
				killed_targets.append(pid)
		return accepted

	func _wait_for_port_free(_port: int, _timeout_s: float) -> void:
		pass

	func _clear_managed_server_record() -> void:
		cleared_record_calls += 1

	func _stop_server_watch() -> void:
		stop_watch_calls += 1

	func _finalize_stop_if_port_free(_port: int) -> bool:
		finalize_calls += 1
		return not _is_port_in_use(_port)

	func _find_managed_pid(_port: int) -> int:
		return managed_pid_lookup


## Host for the deferred-walk (#678) verdict-race test below: a worker-side
## nap keeps the startup walk deterministically suspended inside its first
## `_run_blocking` op (without it a fast worker can finish before the first
## `is_alive()` check and the whole walk completes without suspending). The
## nap runs on the worker thread, never the main thread.
class _SuspendedWalkHostStub extends _ManagerHostStub:
	func _is_port_in_use(port: int) -> bool:
		OS.delay_msec(100)
		return super._is_port_in_use(port)


const TEST_PORT := 65431

const _TENV1 := "GODOT_AI_DISABLE_TELEMETRY"
const _TENV2 := "DISABLE_TELEMETRY"

var _saved_tenv1: Variant = null
var _saved_tenv2: Variant = null
var _saved_telemetry_setting: Variant = null


func suite_name() -> String:
	return "server_lifecycle"


## The manager walks below run on _ManagerHostStub (which extends
## plugin.gd) and can publish via _host._set_resolved_ws_port — writing
## plugin.gd's SHARED statics. See the twin guard in
## test_plugin_lifecycle.gd: a leaked fixture port would poison the next
## live plugin reload's first dial now that the seed keeps a published
## resolution. Capture once, restore after every test.
var _saved_resolved_ws_port := 0
var _saved_ws_port_published := false


func suite_setup(_ctx: Dictionary) -> void:
	_saved_tenv1 = OS.get_environment(_TENV1) if OS.has_environment(_TENV1) else null
	_saved_tenv2 = OS.get_environment(_TENV2) if OS.has_environment(_TENV2) else null
	var es := EditorInterface.get_editor_settings()
	if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
		_saved_telemetry_setting = es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)
	_saved_resolved_ws_port = GodotAiPlugin._resolved_ws_port
	_saved_ws_port_published = GodotAiPlugin._ws_port_resolution_published


func teardown() -> void:
	GodotAiPlugin._resolved_ws_port = _saved_resolved_ws_port
	GodotAiPlugin._ws_port_resolution_published = _saved_ws_port_published


func suite_teardown() -> void:
	_restore_tenv(_TENV1, _saved_tenv1)
	_restore_tenv(_TENV2, _saved_tenv2)
	EditorInterface.get_editor_settings().set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, _saved_telemetry_setting)
	GodotAiPlugin._resolved_ws_port = _saved_resolved_ws_port
	GodotAiPlugin._ws_port_resolution_published = _saved_ws_port_published


func _restore_tenv(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))


func _clear_telemetry_env_vars() -> void:
	OS.unset_environment(_TENV1)
	OS.unset_environment(_TENV2)


# ----- seam wiring -----------------------------------------------------

func test_plugin_init_constructs_lifecycle_manager() -> void:
	## Tree-less construction must work — `_ProofPlugin.new()` in
	## test_plugin_lifecycle.gd calls `_start_server` on a never-entered
	## plugin, and that path goes through the manager.
	var plugin := GodotAiPlugin.new()
	assert_true(plugin._lifecycle is McpServerLifecycleManager)
	assert_true(plugin._lifecycle._host == plugin)
	plugin.free()


# ----- recover_strong_port_occupant ------------------------------------

func test_recover_returns_false_with_no_proof() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok: bool = await manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_false(ok)
	assert_true(killed.is_empty())


func test_recover_kills_and_clears_when_port_frees() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [22222] as Array[int]
	host.alive_pids = [22222] as Array[int]
	## The recorded PID is our managed server, so it's branded godot-ai — the
	## managed_record kill branch now requires that brand (#525).
	host.branded_pids = [22222] as Array[int]
	host.managed_record = {"pid": 22222, "version": "2.1.0", "ws_port": 9500}
	host.port_in_use_sequence = [false] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok: bool = await manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	host.free()

	assert_true(ok)


func test_recover_preserves_record_when_port_held() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [33333] as Array[int]
	host.alive_pids = [33333] as Array[int]
	## Branded ours so the managed_record proof fires and a kill is attempted;
	## the port then stays held, exercising the preserve-record path (#525).
	host.branded_pids = [33333] as Array[int]
	host.managed_record = {"pid": 33333, "version": "2.1.0", "ws_port": 9500}
	host.port_in_use_sequence = [true] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok: bool = await manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var cleared := host.cleared_record_calls
	host.free()

	assert_false(ok)
	assert_eq(cleared, 0)


# ----- _set_incompatible_server connection propagation (#691) ----------

func test_set_incompatible_server_propagates_to_live_connection() -> void:
	## Post-#678 the startup walk suspends before plugin.gd constructs
	## _connection, so an INCOMPATIBLE verdict landing later (recovery
	## failure, force-restart failure) must reach the live connection from
	## _set_incompatible_server itself — otherwise it keeps dialing the WS
	## port forever with the dock showing INCOMPATIBLE.
	var host := _ManagerHostStub.new()
	var conn := McpConnection.new()
	host._connection = conn
	var manager := McpServerLifecycleManagerScript.new(host)

	var live := {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	manager._set_incompatible_server(live, "9.9.9", TEST_PORT)
	var blocked := conn.connect_blocked
	var reason := conn.connect_block_reason
	var status_message := str(manager._server_status_message)
	conn.free()
	host.free()

	assert_true(blocked, "verdict must flip connect_blocked on the live connection")
	assert_false(reason.is_empty(), "block reason must carry the diagnosis")
	assert_eq(reason, status_message, "connection reason must match the manager's message")


func test_set_incompatible_server_disarms_version_check() -> void:
	## Leaving the version check armed after the diagnosis keeps per-frame
	## _process on for the plugin's whole lifetime (#691).
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	var conn := McpConnection.new()
	manager.arm_version_check(conn, "9.9.9")
	assert_true(manager.is_awaiting_server_version(), "precondition: check armed")

	var live := {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	manager._set_incompatible_server(live, "9.9.9", TEST_PORT)
	var still_awaiting: bool = manager.is_awaiting_server_version()
	conn.free()
	host.free()

	assert_false(still_awaiting,
		"_set_incompatible_server must disarm the version check")


func test_set_incompatible_server_tolerates_missing_connection() -> void:
	## Pre-connection verdicts (startup walk before plugin.gd builds
	## _connection, unit-test hosts) must not crash on the null connection.
	var host := _ManagerHostStub.new()
	host._connection = null
	var manager := McpServerLifecycleManagerScript.new(host)

	var live := {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	manager._set_incompatible_server(live, "9.9.9", TEST_PORT)
	var state := manager.get_state()
	host.free()

	assert_eq(state, McpServerState.INCOMPATIBLE)


# ----- sync verdict vs suspended startup walk (worker-slot ownership) ---

func test_sync_verdict_mid_walk_cancels_walk_before_claiming_worker_slot() -> void:
	## An incompatible-occupant startup walk suspends in _run_blocking
	## while the WS handshake verdict (McpServerVersionCheck, ticked from
	## the plugin's _process) can land handle_server_version_verified
	## concurrently. The verdict's _set_incompatible_server tail claims
	## the single active-worker slot, so it must cancel the suspended walk
	## first — pre-fix it stole the slot instead, the walk's op lost the
	## _invalidate_async_startup join guarantee, and the walk's resume got
	## a null with no generation bump ("Trying to assign value of type
	## 'Nil' to a variable of type 'Dictionary'" on v3.1.2/v3.1.3 startup
	## against an older attach-owned server holding the port).
	##
	## The runner does not await test coroutines, so this test makes only
	## synchronous observations: everything asserted below is latched
	## before _set_incompatible_server's first await. The closing
	## _invalidate_async_startup joins the tail's in-flight worker and
	## stales the detached walk/tail continuations, so they unwind on
	## later frames without touching the freed host.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _SuspendedWalkHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	host.live_status = {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager.defer_blocking_work = true

	manager.start_server()
	var walk_suspended: bool = manager._active_blocking_thread != null
	var in_flight_before: bool = manager._start_in_flight
	var gen_before := int(manager._async_generation)

	manager.handle_server_version_verified("9.9.9", "0.0.1")
	var gen_after := int(manager._async_generation)
	var in_flight_after: bool = manager._start_in_flight
	var state := manager.get_state()

	manager._invalidate_async_startup()
	GodotAiPlugin._server_started_this_session = saved_guard
	host.free()

	assert_true(walk_suspended,
		"precondition: the deferred walk must be suspended in _run_blocking")
	assert_true(in_flight_before,
		"precondition: the suspended walk must hold the re-entrancy guard")
	assert_gt(gen_after, gen_before,
		"sync verdict must invalidate the suspended walk before its tail claims the worker slot")
	assert_false(in_flight_after,
		"cancelling the walk must release its re-entrancy guard")
	assert_eq(state, McpServerState.INCOMPATIBLE)


# ----- adopt_compatible_server -----------------------------------------

func test_adopt_managed_when_versions_match() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 12121, true)
	var server_pid := int(manager._server_pid)
	host.free()

	assert_eq(label, McpAdoptionLabel.MANAGED)
	assert_eq(server_pid, 12121)


func test_adopt_external_when_matching_record_does_not_own_listener() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 22222, false)
	var cleared := host.cleared_record_calls
	var server_pid := int(manager._server_pid)
	host.free()

	assert_eq(label, McpAdoptionLabel.EXTERNAL)
	assert_eq(server_pid, -1)
	assert_eq(cleared, 1)


func test_adopt_external_when_record_drifts() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.1.0", "2.2.0", 22222)
	var cleared := host.cleared_record_calls
	host.free()

	assert_eq(label, McpAdoptionLabel.EXTERNAL)
	assert_eq(cleared, 1)


# ----- stop_server -----------------------------------------------------

func test_stop_short_circuits_when_no_pid() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = -1

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_true(killed.is_empty())


func test_stop_aggregates_launcher_pidfile_and_branded_listener_pids() -> void:
	## uvx leaks the launcher early on Windows; the real Python child
	## must still get killed. Coverage for Copilot review #5.
	var host := _ManagerHostStub.new()
	host.managed_pid_lookup = 22222
	host.listener_pids = [33333] as Array[int]
	## The tracked PID is brand-gated at kill time too now (#686), so the
	## live managed-server scenario seeds it alive + branded.
	host.alive_pids = [11111] as Array[int]
	host.branded_pids = [11111, 22222, 33333] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_eq(killed.size(), 3)
	assert_true(killed.has(11111))
	assert_true(killed.has(22222))
	assert_true(killed.has(33333))


func test_stop_does_not_trust_unbranded_managed_pid_fallback() -> void:
	## `_find_managed_pid` falls back to a port scrape when the pid-file is
	## stale or missing. That fallback is only proof when the PID is branded.
	var host := _ManagerHostStub.new()
	host.managed_pid_lookup = 22222
	host.listener_pids = [22222] as Array[int]
	host.alive_pids = [11111] as Array[int]
	host.branded_pids = [11111] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_eq(killed.size(), 1)
	assert_true(killed.has(11111))
	assert_false(killed.has(22222))


func test_stop_does_not_kill_unbranded_port_listeners() -> void:
	## A POSIX IPv6 wildcard listener can show up in the same lsof query
	## as our managed IPv4 server. Stop must never sweep unrelated PIDs
	## just because they share the configured HTTP port.
	var host := _ManagerHostStub.new()
	host.listener_pids = [33333] as Array[int]
	host.alive_pids = [11111] as Array[int]
	host.branded_pids = [11111] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_eq(killed.size(), 1)
	assert_true(killed.has(11111))
	assert_false(killed.has(33333))


func test_stop_does_not_kill_recycled_tracked_pid() -> void:
	## #686: nothing clears `_server_pid` when the server dies mid-session
	## (the health watch stops after SERVER_WATCH_MS). If the kernel
	## recycled the PID to an unrelated process by the time the user quits
	## Godot, stop_server must not kill it: the tracked seed is now gated on
	## alive + branded like every other candidate.
	var host := _ManagerHostStub.new()
	host.alive_pids = [11111] as Array[int]
	## Alive but NOT branded — the recycled-PID shape.
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_true(killed.is_empty(),
		"a tracked PID that no longer passes the brand check must not be killed")


func test_stop_does_not_kill_dead_tracked_pid() -> void:
	## Dead tracked PID: branded lists can be stale too — a PID that is not
	## alive must be skipped without OS.kill ever seeing it.
	var host := _ManagerHostStub.new()
	host.branded_pids = [11111] as Array[int]
	## Not in alive_pids — the server crashed hours ago.
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_true(killed.is_empty(),
		"a dead tracked PID must not be forwarded to the kill helper")


func test_stop_invokes_finalize_for_record_cleanup() -> void:
	## Preserves the "preserve record on failed kill" contract — the
	## finalize handoff must survive the extraction.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 44444

	manager.stop_server()
	var finalize_calls := host.finalize_calls
	host.free()

	assert_eq(finalize_calls, 1)


# ----- detach_server (keep_server_on_exit, #800) ----------------------

func test_detach_kills_nothing_and_preserves_record() -> void:
	## keep_server_on_exit teardown: the tracked server is alive, branded,
	## and listening — everything stop_server would kill — yet detach must
	## touch neither the process nor the record/pid-file.
	var host := _ManagerHostStub.new()
	host.listener_pids = [55555] as Array[int]
	host.alive_pids = [55555] as Array[int]
	host.branded_pids = [55555] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 55555

	manager.detach_server()
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	var finalize_calls := host.finalize_calls
	var stops := host.stop_watch_calls
	var pid_after := int(manager._server_pid)
	var state_after: int = manager._server_state
	host.free()

	assert_true(killed.is_empty(), "detach must not kill the server")
	assert_eq(cleared, 0, "detach must preserve the managed-server record")
	assert_eq(finalize_calls, 0, "detach must not run record-cleanup finalize")
	assert_eq(stops, 1, "detach must stop the server watch like stop_server")
	assert_eq(pid_after, -1)
	assert_eq(state_after, McpServerState.STOPPED)


func test_detach_invalidates_async_generation() -> void:
	## Same contract as stop_server: a suspended start_server resuming
	## after a keep-alive teardown must not resurrect state.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	var before := int(manager._async_generation)
	manager.detach_server()
	var after := int(manager._async_generation)
	var stale := manager._async_stale(before)
	host.free()
	assert_eq(after, before + 1, "detach_server must bump the async generation")
	assert_true(stale, "work captured before detach_server must read as stale")


## Exact save/restore for the keep_server_on_exit EditorSetting: track
## whether it existed so a previously-absent setting is erased rather than
## restored-as-null (which would depend on re-registration to clean up).
func _save_keep_setting(es: EditorSettings) -> Array:
	if es.has_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT):
		return [true, es.get_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT)]
	return [false, null]


func _restore_keep_setting(es: EditorSettings, saved: Array) -> void:
	if bool(saved[0]):
		es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, saved[1])
	else:
		es.erase(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT)


func test_keep_alive_env_staging_honors_setting() -> void:
	## With keep_server_on_exit ON, the spawn env must skip the owner pid
	## (no owner-PID reaper) and stage GODOT_AI_NO_IDLE_EXIT (no idle
	## backstop); with it OFF, NO_IDLE_EXIT must not be staged.
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, true)
	var owner_set_on := manager._set_owner_pid_env()
	var keep_set_on := manager._set_keep_alive_env()
	var idle_env_on := OS.get_environment("GODOT_AI_NO_IDLE_EXIT")
	if keep_set_on:
		OS.unset_environment("GODOT_AI_NO_IDLE_EXIT")

	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var keep_set_off := manager._set_keep_alive_env()

	_restore_keep_setting(es, saved)
	host.free()

	assert_false(owner_set_on, "keep-alive spawn must not hand the server an owner pid")
	assert_true(keep_set_on, "keep-alive spawn must stage GODOT_AI_NO_IDLE_EXIT")
	assert_eq(idle_env_on, "1")
	assert_false(keep_set_off, "default spawn must leave the idle backstop armed")


func test_teardown_for_exit_detaches_when_spawned_keep_alive() -> void:
	## Routing must follow the spawn-time flag, not the live setting: a
	## keep-alive-launched server survives editor exit even though the
	## setting has since been turned OFF.
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.listener_pids = [61111] as Array[int]
	host.alive_pids = [61111] as Array[int]
	host.branded_pids = [61111] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 61111
	manager._server_keep_alive = true

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	var finalize_calls := host.finalize_calls
	_restore_keep_setting(es, saved)
	host.free()

	assert_true(killed.is_empty(), "keep-alive-spawned server must not be killed on exit")
	assert_eq(cleared, 0)
	assert_eq(finalize_calls, 0)


func test_teardown_for_exit_kills_when_flag_clear_despite_setting() -> void:
	## Enable-mid-session: the running server was spawned WITHOUT the
	## keep-alive env opt-outs, so exit must kill it even though the
	## setting is now ON — detaching would preserve a record pointing at
	## a PID the owner-PID watchdog reaps moments later (#774 scenario).
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, true)
	var host := _ManagerHostStub.new()
	host.listener_pids = [62222] as Array[int]
	host.alive_pids = [62222] as Array[int]
	host.branded_pids = [62222] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 62222

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	var finalize_calls := host.finalize_calls
	_restore_keep_setting(es, saved)
	host.free()

	assert_true(killed.has(62222),
		"a server spawned without keep-alive env must die with the editor")
	assert_eq(finalize_calls, 1)


func test_adopt_managed_recovers_keep_alive_from_record() -> void:
	## A keep-alive survivor adopted by a later session must detach again
	## on that session's exit — the flag rides the managed-server record.
	var host := _ManagerHostStub.new()
	host.managed_record = {"pid": 12121, "version": "2.2.0", "ws_port": 9500, "keep_alive": true}
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 12121, true)
	var flag := manager._server_keep_alive
	host.free()

	assert_eq(label, McpAdoptionLabel.MANAGED)
	assert_true(flag, "managed adoption must recover the record's keep-alive flag")


func test_adopt_external_clears_keep_alive() -> void:
	## External adoption knows nothing about the occupant's launch env —
	## the conservative answer is kill-on-exit.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_keep_alive = true

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 22222, false)
	var flag := manager._server_keep_alive
	host.free()

	assert_eq(label, McpAdoptionLabel.EXTERNAL)
	assert_false(flag, "external adoption must reset the keep-alive flag")


# ----- check_server_health / start_server guards ----------------------

func test_check_server_health_short_circuits_when_pid_zero() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 0

	manager.check_server_health()
	var stops := host.stop_watch_calls
	host.free()

	assert_eq(stops, 1)


# ----- #647: post-crash foreign-port-conflict diagnosis ----------------

func test_diagnose_spawn_port_conflict_flags_foreign_http_occupant() -> void:
	var host := _ManagerHostStub.new()
	host.port_in_use = true
	host.live_status = {"name": "", "version": "", "ws_port": 0, "status_code": 0}
	var manager := McpServerLifecycleManagerScript.new(host)

	var conflict: Dictionary = manager._diagnose_spawn_port_conflict()
	host.free()

	assert_has_key(conflict, "message")
	var http_port := McpClientConfigurator.http_port()
	assert_eq(int(conflict.get("port", 0)), http_port)
	assert_contains(str(conflict.get("message", "")), "Port %d is in use by another application" % http_port)
	assert_contains(str(conflict.get("message", "")), "godot_ai/http_port")


func test_diagnose_spawn_port_conflict_ignores_godot_ai_occupant() -> void:
	## A port holder that identifies as godot-ai is stale-server /
	## adoption territory, not a foreign conflict — the CRASHED / retry
	## path must keep handling it. See #647.
	var host := _ManagerHostStub.new()
	host.port_in_use = true
	host.live_status = {"name": "godot-ai", "version": "1.0.0", "ws_port": 9500, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)

	var conflict: Dictionary = manager._diagnose_spawn_port_conflict()
	host.free()

	assert_true(conflict.is_empty(), "godot-ai occupant must not be diagnosed as foreign")


func test_diagnose_spawn_port_conflict_flags_foreign_ws_occupant() -> void:
	var host := _ManagerHostStub.new()
	## First probe (HTTP port) free, second (WS port) occupied.
	host.port_in_use_sequence = [false, true] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var conflict: Dictionary = manager._diagnose_spawn_port_conflict()
	var ws_port := int(GodotAiPlugin._resolved_ws_port)
	host.free()

	assert_has_key(conflict, "message")
	assert_eq(int(conflict.get("port", 0)), ws_port)
	assert_contains(str(conflict.get("message", "")), "WebSocket port %d is in use" % ws_port)
	assert_contains(str(conflict.get("message", "")), "godot_ai/ws_port")


func test_diagnose_spawn_port_conflict_empty_when_ports_free() -> void:
	var host := _ManagerHostStub.new()
	host.port_in_use = false
	var manager := McpServerLifecycleManagerScript.new(host)

	var conflict: Dictionary = manager._diagnose_spawn_port_conflict()
	host.free()

	assert_true(conflict.is_empty(), "no conflict expected when both ports are free")


func test_status_dict_carries_conflict_port() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._conflict_port = 9500

	var status: Dictionary = manager.get_status_dict()
	host.free()

	assert_eq(int(status.get("conflict_port", 0)), 9500)


# ----- spawn fast-exit: lost-port-race re-adoption ----------------------

func test_spawn_fast_exit_readopts_live_godot_ai_survivor() -> void:
	## Reproduced multi-editor failure (2026-07, Windows): the duplicate
	## spawn exits unable to bind while the surviving server still answers
	## /godot-ai/status. The watch must re-run the startup walk (which
	## adopts the survivor) instead of latching CRASHED and leaving the
	## stale spawn token 4003-looping against it.
	var current := McpClientConfigurator.get_plugin_version()
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	var saved_token: String = GodotAiPlugin._ws_auth_token
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host.port_in_use = false
	host.listener_pids = [12321] as Array[int]
	host.alive_pids = [12321] as Array[int]
	host.branded_pids = [12321] as Array[int]
	host.managed_record = {"pid": 55555, "version": current, "ws_port": 9500}
	host.live_status = {"name": "godot-ai", "version": current, "ws_port": 9500, "status_code": 200}
	GodotAiPlugin._server_started_this_session = true
	GodotAiPlugin._ws_auth_token = "stale-spawn-token"
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 99999
	manager.transition_state(McpServerState.SPAWNING)

	manager._diagnose_spawn_fast_exit(5500)
	var state := manager.get_state()
	var path := manager.get_startup_path()
	var killed := host.killed_targets.duplicate()
	var stop_watch_calls := host.stop_watch_calls
	var readopt_guard: bool = manager._readopt_after_spawn_exit_retried
	var walk_pending: bool = manager._readopt_walk_pending
	var token_after: String = GodotAiPlugin._ws_auth_token
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard
	GodotAiPlugin._ws_auth_token = saved_token

	assert_eq(state, McpServerState.READY,
		"fast exit with a live godot-ai survivor must re-walk and adopt")
	assert_eq(path, McpStartupPath.ADOPTED)
	assert_true(killed.is_empty(), "re-adoption must not kill the survivor")
	assert_true(stop_watch_calls >= 1, "the dead spawn's watch must stop")
	assert_false(readopt_guard,
		"successful adoption must refresh the re-adopt budget (#805)")
	assert_false(walk_pending,
		"the triggered walk must consume the pending flag (#805)")
	assert_eq(token_after, "",
		"external re-adoption must drop the stale spawn token")


func test_spawn_fast_exit_latches_flapping_crash_when_budget_spent() -> void:
	## #805 terminal bound: the budget was spent by an earlier fast exit and
	## the triggered walk preserved it (see the walk-budget tests below), so
	## a second fast exit against a live godot-ai occupant must latch a
	## specific CRASHED diagnosis — never re-walk again.
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host.port_in_use = true
	host.live_status = {"name": "godot-ai", "version": "1.0.0", "ws_port": 9500, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 99999
	manager.transition_state(McpServerState.SPAWNING)
	manager._readopt_after_spawn_exit_retried = true

	manager._diagnose_spawn_fast_exit(6000)
	var state := manager.get_state()
	var exit_ms := int(manager._server_exit_ms)
	var stop_watch_calls := host.stop_watch_calls
	var probe_calls := host.probe_calls
	var message: String = str(manager.get_status_dict().get("message", ""))
	host.free()

	assert_eq(state, McpServerState.CRASHED,
		"a spent budget with a live godot-ai occupant must latch CRASHED, not loop")
	assert_eq(exit_ms, 6000)
	assert_eq(stop_watch_calls, 1)
	assert_eq(probe_calls, 1, "the flapping latch must not trigger another walk or probe")
	assert_contains(message, "another godot-ai server",
		"the diagnosis must name the flapping occupant, not a generic crash")
	assert_contains(message, "Reload Plugin",
		"the diagnosis must point at the deliberate-retry action")


func test_triggered_walk_preserves_readopt_budget() -> void:
	## #805: a walk triggered by the re-adopt arm must NOT refresh the
	## budget at its top — if it fails to adopt (here: the occupant turned
	## incompatible by walk time) and later spawns fast-exit again, the
	## flapping latch above must be reachable. Drives the REAL walk.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	host.live_status = {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._readopt_after_spawn_exit_retried = true
	manager._readopt_walk_pending = true

	manager.start_server()
	var state := manager.get_state()
	var guard_after: bool = manager._readopt_after_spawn_exit_retried
	var pending_after: bool = manager._readopt_walk_pending
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_eq(state, McpServerState.INCOMPATIBLE,
		"fixture: the walk must terminate on the incompatible occupant, not spawn")
	assert_true(guard_after,
		"a re-adopt-triggered walk must preserve the spent budget (#805)")
	assert_false(pending_after,
		"the pending flag is one-shot: consumed by the walk it triggered")


func test_fresh_walk_resets_readopt_budget() -> void:
	## Complement of the preservation test: a user/plugin-initiated walk
	## (no pending flag) refreshes the budget, so a deliberate Reload
	## Plugin after the flapping latch gets a new re-adopt attempt.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	host.live_status = {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._readopt_after_spawn_exit_retried = true

	manager.start_server()
	var guard_after: bool = manager._readopt_after_spawn_exit_retried
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_false(guard_after,
		"a fresh walk must reset the re-adopt budget at its top")


# ----- stale-version recovery budget (post-self-update) ------------------

## Shared fixture shape for the stale-occupant walks below: an external
## previous-version godot-ai holds the port (branded, alive, answering
## /status) and no strong ownership proof exists (empty record, no
## pid-file) — the exact post-self-update shape when attach bridges kept
## the old backend alive.
func _stale_occupant_host() -> _ManagerHostStub:
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	host.listener_pids = [13131] as Array[int]
	host.alive_pids = [13131] as Array[int]
	host.branded_pids = [13131] as Array[int]
	host.live_status = {"name": "godot-ai", "version": "0.0.1", "ws_port": 9500, "status_code": 200}
	return host


func test_walk_without_authorization_never_weak_kills_stale_occupant() -> void:
	## Safety floor: with no authorized budget, the walk must keep the
	## pre-fix behavior — a killable (branded, alive) stale occupant with
	## only weak proof latches INCOMPATIBLE untouched.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _stale_occupant_host()
	var manager := McpServerLifecycleManagerScript.new(host)

	manager.start_server()
	var state := manager.get_state()
	var killed := host.killed_targets.duplicate()
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_eq(state, McpServerState.INCOMPATIBLE)
	assert_true(killed.is_empty(),
		"without authorize_stale_recovery the walk must never weak-proof-kill")


func test_walk_spends_budget_and_weak_kills_stale_occupant_when_authorized() -> void:
	## Post-update walk: authorized budget lets the incompatible arm escalate
	## from the (unprovable) strong recovery to the weak-proof kill. The
	## fixture keeps the port held after the kill so the walk stops at
	## INCOMPATIBLE instead of reaching a real spawn.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _stale_occupant_host()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager.authorize_stale_recovery()

	manager.start_server()
	var state := manager.get_state()
	var killed := host.killed_targets.duplicate()
	var budget := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_eq(killed, [13131] as Array[int],
		"authorized walk must weak-proof-kill the stale occupant")
	assert_eq(budget, 1, "the walk's recovery arm must spend exactly one round")
	assert_eq(state, McpServerState.INCOMPATIBLE,
		"fixture: the still-held port must stop the walk before a real spawn")


func test_walk_stale_budget_ignores_same_version_occupant() -> void:
	## The budget only ever targets a version DRIFT. A same-version occupant
	## that fails compatibility another way (here: WS port mismatch) must not
	## be killed by the stale arm, authorized or not.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _stale_occupant_host()
	host.live_status = {
		"name": "godot-ai",
		"version": McpClientConfigurator.get_plugin_version(),
		"ws_port": 1,
		"status_code": 200,
	}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager.authorize_stale_recovery()

	manager.start_server()
	var killed := host.killed_targets.duplicate()
	var budget := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_true(killed.is_empty(),
		"same-version occupants stay outside the stale-recovery authority")
	assert_eq(budget, 2, "no round may be spent on a same-version occupant")


func test_recover_stale_port_occupant_kills_with_weak_proof_and_clears() -> void:
	## Unit coverage for the weak-proof recovery itself: status_name proof is
	## enough, the kill brand-verifies, and a freed port clears record +
	## pid-file exactly like the strong-proof sibling.
	var host := _stale_occupant_host()
	## Held while the occupant lives, free on the post-kill re-check.
	host.port_in_use_sequence = [false] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var recovered: bool = await manager.recover_stale_port_occupant(TEST_PORT, 0.5)
	var killed := host.killed_targets.duplicate()
	var clear_calls := host.cleared_record_calls
	host.free()

	assert_true(recovered, "weak-proof recovery must succeed once the port frees")
	assert_eq(killed, [13131] as Array[int])
	assert_eq(clear_calls, 1, "a freed port must clear the managed record")


func test_recover_stale_port_occupant_refuses_foreign_occupant() -> void:
	## No godot-ai /status answer -> no weak proof -> nothing killed, even
	## with a branded-looking listener list.
	var host := _stale_occupant_host()
	host.live_status = {"name": "other-server", "version": "", "ws_port": 0, "status_code": 200}
	var manager := McpServerLifecycleManagerScript.new(host)

	var recovered: bool = await manager.recover_stale_port_occupant(TEST_PORT, 0.5)
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_false(recovered)
	assert_true(killed.is_empty(),
		"a foreign occupant must never be killed by the stale-recovery path")


func test_spawn_fast_exit_stale_occupant_with_budget_rewalks_and_spends() -> void:
	## The bridge-respawn race: the re-adopt one-shot (#805) is already
	## spent, but the live occupant is a verified stale version and budget
	## remains — the fast exit must spend a round and re-walk (which spends
	## another in its recovery arm) instead of latching the flapping CRASHED.
	var saved_guard: bool = GodotAiPlugin._server_started_this_session
	GodotAiPlugin._server_started_this_session = false
	var host := _stale_occupant_host()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 99999
	manager.transition_state(McpServerState.SPAWNING)
	manager._readopt_after_spawn_exit_retried = true
	manager.authorize_stale_recovery()

	manager._diagnose_spawn_fast_exit(6000)
	var state := manager.get_state()
	var killed := host.killed_targets.duplicate()
	var budget := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()
	GodotAiPlugin._server_started_this_session = saved_guard

	assert_eq(state, McpServerState.INCOMPATIBLE,
		"the stale retry must re-walk (ending INCOMPATIBLE on the held port), not latch CRASHED")
	assert_eq(killed, [13131] as Array[int],
		"the triggered walk must spend its round on the weak-proof kill")
	assert_eq(budget, 0,
		"one round spent at the fast exit + one in the walk's recovery arm")


func test_spawn_fast_exit_same_version_occupant_with_budget_still_latches() -> void:
	## The budget must not weaken the #805 flapping bound for same-version
	## occupants — that shape is multi-editor churn, not a stale update.
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host.port_in_use = true
	host.live_status = {
		"name": "godot-ai",
		"version": McpClientConfigurator.get_plugin_version(),
		"ws_port": 9500,
		"status_code": 200,
	}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 99999
	manager.transition_state(McpServerState.SPAWNING)
	manager._readopt_after_spawn_exit_retried = true
	manager.authorize_stale_recovery()

	manager._diagnose_spawn_fast_exit(6000)
	var state := manager.get_state()
	var budget := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()

	assert_eq(state, McpServerState.CRASHED,
		"same-version flapping must still latch the #805 terminal diagnosis")
	assert_eq(budget, 2, "no round may be spent on a same-version occupant")


## Records plugin-level recovery invocations so the handshake-trigger tests
## can assert spend-only dispatch without running a real recovery.
class _RecoveryRecordingHostStub extends _ManagerHostStub:
	var recovery_calls: Array = []

	func recover_incompatible_server(user_initiated: bool = true) -> bool:
		recovery_calls.append(user_initiated)
		return true


func test_handshake_mismatch_with_budget_triggers_spend_only_recovery() -> void:
	## Post-update the WS usually reaches the OLD backend before the walk
	## finishes; the mismatch verdict must consume the authorized budget and
	## fire the recovery flow as NON-user-initiated (spend-only — re-arming
	## from the trigger would unbound the kill/respawn loop).
	var host := _RecoveryRecordingHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	var manager := McpServerLifecycleManagerScript.new(host)
	manager.authorize_stale_recovery()

	manager.handle_server_version_verified("", "0.0.1")
	var state := manager.get_state()
	var calls := host.recovery_calls.duplicate()
	var budget := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()

	assert_eq(state, McpServerState.INCOMPATIBLE,
		"the verdict must still latch INCOMPATIBLE before the recovery fires")
	assert_eq(calls, [false],
		"the trigger must dispatch exactly one non-user-initiated recovery")
	assert_eq(budget, 1, "the trigger must spend one round")


func test_handshake_mismatch_without_budget_latches_without_recovery() -> void:
	var host := _RecoveryRecordingHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	host.port_in_use = true
	var manager := McpServerLifecycleManagerScript.new(host)

	manager.handle_server_version_verified("", "0.0.1")
	var state := manager.get_state()
	var calls := host.recovery_calls.duplicate()
	host.free()

	assert_eq(state, McpServerState.INCOMPATIBLE)
	assert_true(calls.is_empty(),
		"without authorized budget the mismatch verdict must stay manual")


func test_proven_recovery_resets_stale_budget() -> void:
	## Leftover authorized rounds must not survive into a later, unrelated
	## episode where they could weak-proof-kill a deliberately started
	## server: adoption and a verified compatible handshake both end the
	## episode.
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host._connection = null
	var manager := McpServerLifecycleManagerScript.new(host)
	var current := McpClientConfigurator.get_plugin_version()

	manager.authorize_stale_recovery()
	manager.adopt_compatible_server(current, current, 0, false)
	var budget_after_adopt := int(manager.get_status_dict().get("stale_recovery_budget", -1))

	manager.authorize_stale_recovery()
	manager._server_state = McpServerState.SPAWNING
	manager.handle_server_version_verified(current, current)
	var budget_after_verify := int(manager.get_status_dict().get("stale_recovery_budget", -1))
	host.free()

	assert_eq(budget_after_adopt, 0, "adoption must reset the stale budget")
	assert_eq(budget_after_verify, 0, "a verified compatible handshake must reset the stale budget")


func test_spawn_fast_exit_foreign_occupant_reuses_probe_snapshot() -> void:
	## The fast-exit handler probes the HTTP status endpoint once; the
	## foreign-conflict diagnosis must consume that snapshot instead of
	## paying a second ~500ms probe on the main thread.
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	host.port_in_use = true
	host.live_status = {"name": "", "version": "", "ws_port": 0, "status_code": 0}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 99999
	manager.transition_state(McpServerState.SPAWNING)

	manager._diagnose_spawn_fast_exit(6000)
	var state := manager.get_state()
	var probe_calls := host.probe_calls
	var conflict_port := int(manager._conflict_port)
	host.free()

	assert_eq(state, McpServerState.FOREIGN_PORT,
		"a non-godot-ai occupant must still surface FOREIGN_PORT through the new seam")
	assert_eq(probe_calls, 1, "conflict diagnosis must reuse the fast-exit probe snapshot")
	assert_eq(conflict_port, McpClientConfigurator.http_port())


func test_start_server_short_circuits_on_static_guard() -> void:
	GodotAiPlugin._server_started_this_session = true
	var host := _ManagerHostStub.new()
	host.port_in_use = true
	host.listener_pids = [99999] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)

	manager.start_server()
	var path := manager.get_startup_path()
	var killed := host.killed_targets.duplicate()
	var state := manager.get_state()
	host.free()
	GodotAiPlugin._server_started_this_session = false

	assert_eq(path, McpStartupPath.GUARDED)
	assert_eq(state, McpServerState.GUARDED)
	assert_true(killed.is_empty())


func test_prepare_for_update_reload_clears_spawn_guard() -> void:
	GodotAiPlugin._server_started_this_session = true
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = -1

	manager.prepare_for_update_reload()
	var guard_after := GodotAiPlugin._server_started_this_session
	host.free()
	GodotAiPlugin._server_started_this_session = false

	assert_false(guard_after)


## respawn_with_refresh is covered by script/ci-reload-test (10 reload
## iterations + full test suite). Stubbing McpClientConfigurator's
## get_server_command at this layer would re-implement config resolution.


# ----- _inject_telemetry_env -------------------------------------------

func test_inject_sets_env_when_telemetry_disabled_in_settings() -> void:
	_clear_telemetry_env_vars()
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	var env_present := OS.has_environment(_TENV1)
	if injected:
		OS.unset_environment(_TENV1)
	host.free()

	assert_true(injected, "_inject_telemetry_env must return true when it sets the var")
	assert_true(env_present, "GODOT_AI_DISABLE_TELEMETRY must be set in process env for the spawn")


func test_inject_env_is_unset_after_caller_restores() -> void:
	## Regression guard: start_server / respawn_with_refresh unset the var
	## immediately after OS.create_process. Verify the restore pattern works
	## so a future refactor can't silently leak the flag into later spawns.
	_clear_telemetry_env_vars()
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	if injected:
		OS.unset_environment(_TENV1)  ## mirrors what start_server / respawn_with_refresh do
	var env_present_after := OS.has_environment(_TENV1)
	host.free()

	assert_false(env_present_after, "editor process env must be clean after the spawn-window restore")


func test_inject_skips_when_setting_is_true() -> void:
	_clear_telemetry_env_vars()
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, true
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	var env_present := OS.has_environment(_TENV1)
	if injected:
		OS.unset_environment(_TENV1)
	host.free()

	assert_false(injected, "must not inject when telemetry is enabled")
	assert_false(env_present, "GODOT_AI_DISABLE_TELEMETRY must not be set when telemetry is enabled")


func test_inject_skips_when_godot_ai_disable_telemetry_already_present() -> void:
	## Env var already set by the user / CI — must not double-inject or
	## report it as injected (which would cause the caller to unset it on
	## cleanup, removing the user's own setting).
	OS.set_environment(_TENV1, "true")
	OS.unset_environment(_TENV2)
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	host.free()

	assert_false(injected, "must not inject when GODOT_AI_DISABLE_TELEMETRY is already in env")


func test_inject_skips_when_disable_telemetry_already_present() -> void:
	OS.unset_environment(_TENV1)
	OS.set_environment(_TENV2, "1")
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	host.free()

	assert_false(injected, "must not inject when DISABLE_TELEMETRY is already in env")


func test_inject_when_env_present_but_falsey_and_setting_disabled() -> void:
	## A falsey env value (e.g. DISABLE_TELEMETRY=0) must NOT suppress a dock UI
	## opt-out. The Python server parses the env truthily, so a falsey value
	## leaves the server *enabled* — the plugin has to inject the disable flag
	## so the opt-out actually reaches the spawned server. The old
	## has_environment() guard treated any value (even "0") as "handled" and
	## silently shipped telemetry against the user's UI choice. (#530)
	_clear_telemetry_env_vars()
	OS.set_environment(_TENV2, "0")
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var injected := manager._inject_telemetry_env()
	var env_present := OS.has_environment(_TENV1)
	host.free()
	_clear_telemetry_env_vars()

	assert_true(injected, "a falsey DISABLE_TELEMETRY must not suppress the UI opt-out")
	assert_true(env_present, "GODOT_AI_DISABLE_TELEMETRY must be injected for the spawn")


# ----- #678 async startup plumbing --------------------------------------

func test_run_blocking_inline_by_default() -> void:
	## With defer_blocking_work off (the default every unit test relies on)
	## the work runs inline and the surrounding coroutines never suspend —
	## call-then-assert keeps working.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	assert_false(manager.defer_blocking_work,
		"synchronous behavior must be the default (tests depend on it)")
	## `await` is a pass-through here: inline mode never suspends.
	var value: Variant = await manager._run_blocking(func() -> Variant: return 42)
	host.free()
	assert_eq(value, 42, "inline _run_blocking must return the work's value")


func test_start_server_reentrancy_guard() -> void:
	## Startup is a coroutine in production, so a second start_server can
	## arrive mid-flight — it must be a no-op, not a second walk.
	var host := _ManagerHostStub.new()
	host.port_in_use = true
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._start_in_flight = true
	manager.start_server()
	var state := manager.get_state()
	host.free()
	assert_eq(state, McpServerState.UNINITIALIZED,
		"an in-flight start must block a second walk from mutating state")


func test_stop_server_invalidates_async_generation() -> void:
	## stop_server (and therefore _exit_tree / update-reload prep) must
	## cancel in-flight async startup work so a suspended start_server
	## can't resurrect state after teardown began.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	var before := int(manager._async_generation)
	manager.stop_server()
	var after := int(manager._async_generation)
	var stale := manager._async_stale(before)
	host.free()
	assert_eq(after, before + 1, "stop_server must bump the async generation")
	assert_true(stale, "work captured before stop_server must read as stale")


func test_proof_helper_honors_record_override() -> void:
	## #678: when the proof helper runs on a worker thread it must not read
	## EditorSettings — the caller injects the record snapshot instead.
	var host := _ManagerHostStub.new()
	host.listener_pids = [4242]
	host.alive_pids = [4242]
	host.branded_pids = [4242]
	## The stub's internal record would NOT match; the override must win.
	host.managed_record = {"pid": 0, "version": "", "ws_port": 0}
	var proof: Dictionary = host._evaluate_strong_port_occupant_proof(
		TEST_PORT, {"name": ""}, {"pid": 4242, "version": "9.9.9", "ws_port": 0}
	)
	host.free()
	assert_eq(str(proof.get("proof", "")), "managed_record",
		"the injected record snapshot must drive the managed_record proof tier")
	assert_eq(proof.get("pids", []), [4242])


func test_force_restart_reset_invalidates_async_generation_and_guard() -> void:
	## #682 review: the one-shot kill-and-restart paths must cancel an
	## in-flight contended-port walk AND release the re-entrancy guard —
	## otherwise the dock's explicit restart is silently swallowed while
	## the stale walk resumes against post-kill reality.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._start_in_flight = true
	var before := int(manager._async_generation)
	manager.reset_for_force_restart()
	var after := int(manager._async_generation)
	var stale := manager._async_stale(before)
	var guard_released: bool = not manager._start_in_flight
	host.free()
	assert_eq(after, before + 1,
		"reset_for_force_restart must bump the async generation")
	assert_true(stale, "the in-flight walk must read as stale after the reset")
	assert_true(guard_released,
		"the follow-up start_server must not be swallowed by the stale walk's guard")


func test_invalidate_async_startup_joins_in_flight_worker() -> void:
	## macOS reload-churn wedge (post-#682 main CI): _exit_tree could free
	## the plugin while a walk's worker thread was still executing one of
	## its methods — use-after-free on the worker. Invalidation (run by
	## stop_server before the plugin frees) must JOIN the worker first.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	var thread := Thread.new()
	thread.start(func() -> void: OS.delay_msec(150))
	manager._active_blocking_thread = thread
	manager._invalidate_async_startup()
	var alive_after := thread.is_alive()
	var slot_cleared: bool = manager._active_blocking_thread == null
	host.free()
	assert_false(alive_after,
		"invalidation must join the in-flight worker before returning")
	assert_true(slot_cleared,
		"invalidation must take ownership of the thread slot so the stale walk cannot double-join")


# ----- #797: Windows uv-venv trampoline handoff -----

func test_handoff_pending_while_windows_spawn_dies_before_the_pid_file() -> void:
	## The reported case: a uv trampoline exits ~immediately, the real
	## interpreter is still starting, no pid-file yet. That must read as a
	## handoff in progress, not as "server exited".
	assert_true(McpServerLifecycleManagerScript.is_spawn_handoff_pending(
		"Windows", 0, 5146, 15000),
		"a dead spawn PID with no pid-file inside the window is a handoff, not an exit")


func test_handoff_not_pending_once_the_pid_file_lands() -> void:
	## Once the server publishes a PID there is something to heal onto, so the
	## caller's heal branch owns the case — waiting longer would strand it.
	assert_false(McpServerLifecycleManagerScript.is_spawn_handoff_pending(
		"Windows", 4242, 5146, 15000),
		"a published pid-file ends the handoff wait")


func test_handoff_expires_so_a_dead_windows_spawn_is_still_diagnosed() -> void:
	## The wait is bounded: a genuinely dead spawn that never publishes must
	## still reach the fast-exit diagnosis, inside SERVER_WATCH_MS.
	assert_false(McpServerLifecycleManagerScript.is_spawn_handoff_pending(
		"Windows", 0, 15000, 15000),
		"the handoff window must close so a real crash is not waited out forever")
	assert_true(int(GodotAiPlugin.SPAWN_HANDOFF_MS) < int(GodotAiPlugin.SERVER_WATCH_MS),
		"the handoff window must close before the watch loop stops looking")
	assert_true(int(GodotAiPlugin.SPAWN_HANDOFF_MS) > int(GodotAiPlugin.SPAWN_GRACE_MS),
		"a handoff window at or under the spawn grace would change nothing")


func test_handoff_never_pending_off_windows() -> void:
	## POSIX uv venvs exec rather than trampoline, so a dead spawn PID there is
	## a dead server. Delaying that diagnosis would slow honest crash reporting
	## on the platforms where this cannot happen.
	for os_name in ["Linux", "macOS", "FreeBSD", ""]:
		assert_false(McpServerLifecycleManagerScript.is_spawn_handoff_pending(
			os_name, 0, 100, 15000),
			"%s must keep the unchanged dead-spawn-is-a-dead-server behavior" % os_name)


func test_first_death_stamp_preserves_the_true_exit_time() -> void:
	## #797 is about an honest log line, so a diagnosis raised after waiting out
	## a handoff must still report when the process actually died — not when the
	## wait gave up. Drives the production stamp across successive watch ticks
	## rather than re-implementing first-write-wins in the test, so a regression
	## in check_server_health's stamping is actually caught.
	var stamp := 0
	for elapsed in [312, 1300, 14900]:
		stamp = McpServerLifecycleManagerScript.first_death_stamp(stamp, elapsed)
	assert_eq(stamp, 312,
		"the first observed death time must survive the wait, not the last tick")


func test_first_death_stamp_takes_the_first_tick_that_saw_the_death() -> void:
	## An unstamped slot adopts the current elapsed; the field is cleared to 0
	## per spawn, so this is the fresh-spawn entry point.
	assert_eq(McpServerLifecycleManagerScript.first_death_stamp(0, 5146), 5146,
		"an unstamped watch must record the tick that first saw the spawn dead")


# ----- #824: teardown honors active attach leases -----

func test_teardown_detaches_when_attach_leases_are_active() -> void:
	## The startup order the issue describes: editor spawns the backend, an MCP
	## client's attach bridge adopts it and registers a lease, then the editor
	## closes normally. Killing here would take the server out from under a live
	## client, so the backend survives and the plugin drops its managed claim.
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.listener_pids = [63333] as Array[int]
	host.alive_pids = [63333] as Array[int]
	host.branded_pids = [63333] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 1}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 63333

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	var pid_after := int(manager._server_pid)
	_restore_keep_setting(es, saved)
	host.free()

	assert_true(killed.is_empty(),
		"a backend with a live attach lease must survive normal editor exit")
	assert_eq(cleared, 1,
		"the plugin must drop its managed claim so the next editor adopts externally")
	assert_eq(pid_after, -1, "the detached PID must not stay tracked as killable")


func test_teardown_kills_when_no_leases_are_held() -> void:
	## The no-lease case is the overwhelmingly common one and must not change:
	## a backend nobody else is using still dies with the editor that spawned it.
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.listener_pids = [64444] as Array[int]
	host.alive_pids = [64444] as Array[int]
	host.branded_pids = [64444] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 0}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 64444

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	_restore_keep_setting(es, saved)
	host.free()

	assert_true(killed.has(64444),
		"a backend with no leases must still be stopped by the editor that spawned it")


func test_lease_count_reads_zero_for_a_backend_too_old_to_publish_it() -> void:
	## Staggered upgrade: plugin knows about leases, backend does not. Absent
	## field must read as "no information", which keeps that pairing on the
	## historical kill-on-exit behavior rather than stranding a process.
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(
		{"name": "godot-ai", "server_version": "3.0.7"}), 0)


func test_lease_count_ignores_a_process_that_is_not_godot_ai() -> void:
	## An unrelated process answering on the port must not be able to talk this
	## editor out of a clean stop by claiming leases.
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(
		{"name": "something-else", "active_lease_count": 9}), 0)
	assert_eq(McpServerLifecycleManagerScript.active_lease_count({}), 0,
		"a failed or timed-out probe returns {} and must read as no leases")


func test_lease_count_clamps_a_nonsense_value() -> void:
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(
		{"name": "godot-ai", "active_lease_count": -3}), 0)
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(
		{"name": "godot-ai", "active_lease_count": 4}), 4)


func test_lease_probe_skipped_when_no_managed_pid() -> void:
	## Nothing to hand over and nothing to kill: teardown must not pay for an
	## HTTP probe on the way out.
	var host := _ManagerHostStub.new()
	host.live_status = {"name": "godot-ai", "active_lease_count": 5}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 0

	var count := manager.active_lease_count_at_exit()
	var probes := host.probe_calls
	host.free()

	assert_eq(count, 0)
	assert_eq(probes, 0, "no managed PID must mean no status probe at exit")


func test_leases_ignored_when_the_managed_pid_cannot_be_proven_ours() -> void:
	## #824 instance-binding: the lease count comes from whoever answers on the
	## port, which is not proof that it is the process we are about to stop.
	## Another backend holding the port must not talk this editor out of
	## stopping its own server, so an unbranded PID falls back to stop_server
	## (whose own #686 gate then declines to kill a PID it cannot verify).
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.alive_pids = [65555] as Array[int]
	## Deliberately NOT branded: a recycled PID, or a stranger's process.
	host.branded_pids = [] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 3}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 65555

	var count := manager.active_lease_count_at_exit()
	var cleared := host.cleared_record_calls
	var probes := host.probe_calls
	_restore_keep_setting(es, saved)
	host.free()

	assert_eq(count, 0,
		"leases must not be honored for a PID we cannot prove is our server")
	assert_eq(probes, 0,
		"the proof gate must short-circuit before paying for the status probe")
	assert_eq(cleared, 0)


func test_leases_honored_only_for_a_live_branded_managed_pid() -> void:
	## The positive half of the same gate, so it cannot silently start
	## returning 0 for everything.
	var host := _ManagerHostStub.new()
	host.alive_pids = [66666] as Array[int]
	host.branded_pids = [66666] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 2}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 66666

	var count := manager.active_lease_count_at_exit()
	host.free()

	assert_eq(count, 2, "a proven-ours backend's leases must be honored")


func test_lease_count_gate_is_a_threshold_not_an_equality() -> void:
	## Multiple bridges: teardown must detach while ANY lease is held, not only
	## when exactly one is. Releasing one of several must keep the backend up.
	for held in [1, 2, 7]:
		assert_true(McpServerLifecycleManagerScript.active_lease_count(
			{"name": "godot-ai", "active_lease_count": held}) > 0,
			"%d held lease(s) must still count as occupied" % held)
	assert_false(McpServerLifecycleManagerScript.active_lease_count(
		{"name": "godot-ai", "active_lease_count": 0}) > 0,
		"only the last release may return the backend to kill-on-exit")


func test_teardown_routes_to_detach_for_more_than_one_lease() -> void:
	## Routing, not just the helper: the earlier case holds exactly one lease,
	## so a regression narrowing the gate to `== 1` would still pass it. Several
	## bridges must reach detach too. `finalize_calls` is the discriminator —
	## stop_server ends in _finalize_stop_if_port_free, detach_server never
	## touches it.
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.listener_pids = [67777] as Array[int]
	host.alive_pids = [67777] as Array[int]
	host.branded_pids = [67777] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 3}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 67777

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	var finalize_calls := host.finalize_calls
	var cleared := host.cleared_record_calls
	_restore_keep_setting(es, saved)
	host.free()

	assert_true(killed.is_empty(), "three held leases must still detach, not kill")
	assert_eq(finalize_calls, 0, "detach must not run the stop path's finalize")
	assert_eq(cleared, 1, "detach drops the managed claim")


func test_teardown_routes_to_stop_when_the_pid_cannot_be_proven() -> void:
	## The proof gate's routing half: a backend reporting leases must NOT keep
	## the editor from stopping when the PID we hold cannot be proven ours.
	## Teardown has to reach the stop path, and must not clear the managed
	## record on the way (stop_server preserves it when the port is still held,
	## so the next start_server's drift branch can retry the kill).
	var es := EditorInterface.get_editor_settings()
	var saved := _save_keep_setting(es)
	es.set_setting(McpClientConfigurator.SETTING_KEEP_SERVER_ON_EXIT, false)
	var host := _ManagerHostStub.new()
	host.alive_pids = [68888] as Array[int]
	host.branded_pids = [] as Array[int]
	host.live_status = {"name": "godot-ai", "active_lease_count": 4}
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 68888

	manager.teardown_for_editor_exit()
	var killed := host.killed_targets.duplicate()
	var finalize_calls := host.finalize_calls
	var cleared := host.cleared_record_calls
	_restore_keep_setting(es, saved)
	host.free()

	assert_eq(finalize_calls, 1,
		"an unprovable PID must reach the stop path despite reported leases")
	assert_eq(cleared, 0,
		"the lease detach's record clear must not fire on the stop path")
	assert_true(killed.is_empty(),
		"stop_server's own proof gate still declines to kill an unbranded PID")


# ----- #824 regression: the probe must PROJECT what teardown consumes -----

func test_status_projection_carries_the_lease_count_to_the_consumer() -> void:
	## The gap that shipped in #839 and was caught only by a Windows smoke:
	## teardown read `active_lease_count` off the probe result while
	## `_probe_live_server_status` never copied it out of the JSON, so the
	## lease branch was unreachable on every platform. The stubbed teardown
	## tests could not see it because they hand-built the probe's result dict.
	##
	## This drives a real `/godot-ai/status` body through the actual projection
	## and into the actual consumer, so the two halves cannot drift again.
	var server_payload := {
		"name": "godot-ai",
		"server_version": "3.0.7",
		"ws_port": 9500,
		"tool_surface": "rollup",
		"exclude_domains": [],
		"package_path": "/src/godot_ai",
		"instance_id": "e43bd1d9d15c418784676f87055d50b8",
		"owner_type": "plugin",
		"attach_protocol_version": 1,
		"tool_catalog_hash": "deadbeef",
		"active_lease_count": 2,
	}

	var projected := GodotAiPlugin._project_status_payload(server_payload)

	assert_true(projected.has("active_lease_count"),
		"the probe must project the field teardown reads, not drop it")
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(projected), 2,
		"a real status body with held leases must reach the teardown consumer")
	## The fields the projection already carried must survive the refactor.
	assert_eq(projected.get("name"), "godot-ai")
	assert_eq(projected.get("version"), "3.0.7")
	assert_eq(projected.get("ws_port"), 9500)
	assert_eq(projected.get("package_path"), "/src/godot_ai")
	assert_true(bool(projected.get("reachable")))


func test_status_projection_leaves_an_older_backends_field_absent() -> void:
	## "Too old to publish it" must stay distinguishable from "reports zero",
	## which is what the absent-stays-absent rule buys. Both stop the server.
	var projected := GodotAiPlugin._project_status_payload({
		"name": "godot-ai", "server_version": "3.0.6", "ws_port": 9500,
	})
	assert_false(projected.has("active_lease_count"),
		"a backend that never published the field must not gain a synthetic 0")
	assert_eq(McpServerLifecycleManagerScript.active_lease_count(projected), 0)


func test_status_projection_drops_a_non_numeric_lease_count() -> void:
	## A malformed value must not read as occupancy and keep a server alive.
	## 1.5 is the interesting one: Godot parses every JSON number as a float, so
	## a naive int() cast would truncate it to 1 and manufacture a held lease
	## out of a malformed payload. Infinities and NaN are junk for the same
	## reason. Whole floats (2.0) are the NORMAL case and must survive.
	for junk in ["3", [], {}, null, 1.5, 0.5, -2.5, INF, -INF, NAN]:
		var projected := GodotAiPlugin._project_status_payload({
			"name": "godot-ai", "active_lease_count": junk,
		})
		assert_eq(McpServerLifecycleManagerScript.active_lease_count(projected), 0,
			"non-numeric lease count must not read as leases held")


func test_status_projection_keeps_whole_number_lease_counts() -> void:
	## The other side of the fractional guard: JSON numbers arrive as floats, so
	## rejecting floats outright would drop every real count.
	for whole in [0.0, 1.0, 2.0, 9.0]:
		var projected := GodotAiPlugin._project_status_payload({
			"name": "godot-ai", "active_lease_count": whole,
		})
		assert_true(projected.has("active_lease_count"),
			"a whole-number count (%s) is the normal wire shape and must project" % whole)
		assert_eq(McpServerLifecycleManagerScript.active_lease_count(projected), int(whole))


# ----- #797 forensics: capture evidence at the moment of judgement -----

func test_forensics_names_the_handoff_shape() -> void:
	## The shape #797 hypothesised: watched PID gone, a different live PID in
	## the pid-file. Naming it in the line means a bug report answers the
	## question without the reporter knowing to look.
	var line := McpServerLifecycleManagerScript.format_spawn_exit_forensics({
		"os": "Windows", "launch_mode": "dev_venv",
		"elapsed_ms": 5146, "first_dead_ms": 5146,
		"spawn_pid": 30188, "spawn_alive": false,
		"pid_file_pid": 9360, "pid_file_alive": true,
	})
	assert_contains(line, "shape=handoff_child_alive")
	assert_contains(line, "spawn_pid=30188(alive=false)")
	assert_contains(line, "pid_file_pid=9360(alive=true)")
	assert_contains(line, "elapsed=5146ms")


func test_forensics_flags_a_watched_pid_that_is_actually_alive() -> void:
	## The case the 12-boot smoke found: the trampoline never dies. If a
	## fast-exit is ever diagnosed while the watched PID is alive here, the
	## death was transient — a different bug from a process that really exited,
	## and one nobody would guess from "server exited after Nms".
	var line := McpServerLifecycleManagerScript.format_spawn_exit_forensics({
		"os": "Windows", "launch_mode": "dev_venv",
		"elapsed_ms": 5200, "first_dead_ms": 5100,
		"spawn_pid": 30188, "spawn_alive": true,
		"pid_file_pid": 9360, "pid_file_alive": true,
	})
	assert_contains(line, "shape=watched_pid_still_alive")


func test_forensics_distinguishes_a_real_crash_from_a_missing_pid_file() -> void:
	var crashed := McpServerLifecycleManagerScript.format_spawn_exit_forensics({
		"spawn_pid": 111, "spawn_alive": false,
		"pid_file_pid": 111, "pid_file_alive": false,
	})
	assert_contains(crashed, "shape=all_dead")

	var never_published := McpServerLifecycleManagerScript.format_spawn_exit_forensics({
		"spawn_pid": 111, "spawn_alive": false,
		"pid_file_pid": 0, "pid_file_alive": false,
	})
	assert_contains(never_published, "shape=no_pid_file_published")


func test_forensics_wiring_reports_diagnosis_time_not_the_death_time() -> void:
	## Caught in review after the formatter-only version of this test passed
	## while production was broken: `check_server_health` calls
	## `_diagnose_spawn_fast_exit(_spawn_dead_since_ms)` (#837, so the
	## user-facing line dates the real exit), so forwarding that same value into
	## the forensics made elapsed_ms and first_dead_ms identical — collapsing
	## the one distinction they exist to record.
	##
	## Asserting on the ACTUAL logged line rather than on the formatter, because
	## a formatter test cannot see the two inputs converge upstream.
	var host := _ManagerHostStub.new()
	host._log_buffer = McpLogBuffer.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 4242
	## Spawned "a while ago", died early: a handoff wait between the two.
	manager._server_spawn_ms = Time.get_ticks_msec() - 9000
	manager._spawn_dead_since_ms = 300

	manager._log_spawn_exit_forensics()
	var lines: Array = host._log_buffer.get_recent(5)
	host.free()

	var found := ""
	for line in lines:
		if str(line).find("#797 spawn-exit forensics") >= 0:
			found = str(line)
	assert_false(found.is_empty(), "the forensics line must actually be logged")
	assert_contains(found, "first_dead=300ms")
	assert_false(found.contains("elapsed=300ms"),
		"elapsed must be the diagnosis time, not a copy of the death time")
	## Spawned ~9s ago, so the diagnosis timestamp is in that neighbourhood.
	## Asserting the magnitude rather than an exact tick keeps it non-flaky.
	var elapsed_at := found.find("elapsed=")
	var reported := found.substr(elapsed_at + 8).split("ms")[0].to_int()
	assert_true(reported >= 9000,
		"elapsed should measure from spawn (>=9000ms), got %d" % reported)


func test_forensics_is_a_single_line() -> void:
	## It has to survive being pasted into an issue with surrounding log noise.
	var line := McpServerLifecycleManagerScript.format_spawn_exit_forensics({
		"os": "Windows", "spawn_pid": 1, "pid_file_pid": 2,
	})
	assert_eq(line.count("\n"), 0, "forensics must stay one line")
	assert_true(line.begins_with("#797 "),
		"prefix the issue number so a future reporter can search for it")
