@tool
extends McpTestSuite

## Unit tests for McpServerLifecycleManager — the spawn / stop /
## adopt / recover orchestration extracted from plugin.gd in
## #297 / PR 5.
##
## The manager is a method bag that operates against a `_host` reference
## (the GodotAiPlugin instance). The end-to-end behavior — drift kills,
## strong-proof recoveries, watch-loop crash detection — is covered by
## the PR 4 characterization suite in `test_plugin_lifecycle.gd`, which
## still drives plugin.gd's public methods. This suite locks in the
## *seam* contract: that plugin.gd genuinely delegates to the manager,
## that the manager respects test overrides on the host, and that
## constructing the manager without an editor session is safe.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")
const McpServerLifecycleManagerScript := preload(
	"res://addons/godot_ai/utils/server_lifecycle.gd"
)


## Mirrors the `_ProofPlugin` shape from test_plugin_lifecycle.gd but
## scoped down to the surface the manager actually touches. Overrides
## the same hooks the manager calls through `_host.<method>`, so a test
## can drive the manager's branches without spawning a real server.
class _ManagerHostStub extends GodotAiPlugin:
	var listener_pids: Array[int] = []
	var managed_record := {"pid": 0, "version": "", "ws_port": 0}
	var live_status := {"name": "", "version": "", "ws_port": 0, "status_code": 0}
	var alive_pids: Array[int] = []
	var pid_file_pid := 0
	var port_in_use := false
	var port_in_use_sequence: Array[bool] = []
	var killed_targets: Array[int] = []
	var cleared_record_calls := 0
	var waited_calls := 0
	var stop_watch_calls := 0
	var finalize_calls := 0
	var purged := false  # not used; UvCacheCleanup is static, kept for parity

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

	func _probe_live_server_status_for_port(_port: int) -> Dictionary:
		return live_status.duplicate()

	func _is_port_in_use(_port: int) -> bool:
		if not port_in_use_sequence.is_empty():
			return bool(port_in_use_sequence.pop_front())
		return port_in_use

	func _kill_processes_and_windows_spawn_children(pids: Array[int]) -> Array[int]:
		for pid in pids:
			if not killed_targets.has(pid):
				killed_targets.append(pid)
		var killed: Array[int] = []
		killed.assign(pids)
		return killed

	func _wait_for_port_free(_port: int, _timeout_s: float) -> void:
		waited_calls += 1

	func _clear_managed_server_record() -> void:
		cleared_record_calls += 1

	func _stop_server_watch() -> void:
		stop_watch_calls += 1

	func _finalize_stop_if_port_free(_port: int) -> bool:
		finalize_calls += 1
		return not _is_port_in_use(_port)


const TEST_PORT := 65431


func suite_name() -> String:
	return "server_lifecycle"


# ----- seam wiring -----------------------------------------------------

func test_plugin_constructs_lifecycle_manager_in_init() -> void:
	## Without entering the tree, `_init` must produce a live manager so
	## test fixtures can drive `_start_server` / `prepare_for_update_reload`
	## without an editor session attached. Required by the PR 4
	## characterization suite, which calls `plugin._start_server()` on
	## fresh `_ProofPlugin.new()` instances.
	var plugin := GodotAiPlugin.new()
	assert_true(plugin._lifecycle != null, "_init must allocate the lifecycle manager")
	assert_true(
		plugin._lifecycle is McpServerLifecycleManager,
		"the lifecycle field must hold an McpServerLifecycleManager"
	)
	plugin.free()


func test_lifecycle_manager_holds_host_reference() -> void:
	var plugin := GodotAiPlugin.new()
	var manager: McpServerLifecycleManager = plugin._lifecycle
	assert_true(manager._host == plugin, "manager must point at the constructing plugin")
	plugin.free()


# ----- recover_strong_port_occupant (seam under test) ------------------

func test_recover_strong_port_occupant_returns_false_with_no_proof() -> void:
	## No listener PIDs, no record, no live status — the manager must
	## refuse to kill anything and report failure. plugin.gd's existing
	## test of the same path (test_plugin_lifecycle.gd) exercises the
	## delegation through `_recover_strong_port_occupant`; here we hit
	## the manager method directly to prove the seam preserves the
	## "no proof => no kill" invariant.
	var host := _ManagerHostStub.new()
	host.listener_pids = []
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_false(ok, "no port owner => no kill, no recovery")
	assert_true(killed.is_empty(), "no proof must produce no kill targets")


func test_recover_strong_port_occupant_kills_and_clears_when_port_frees() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [22222] as Array[int]
	host.pid_file_pid = 22222
	host.alive_pids = [22222] as Array[int]
	## Make the cmdline check pass by overriding the brand-cmdline hook
	## inherited from plugin.gd to a fixed-true on this PID only.
	host.set_meta("brand_pid", 22222)
	var manager := McpServerLifecycleManagerScript.new(host)
	host.port_in_use_sequence = [false] as Array[bool]

	## Without overriding the cmdline check the legacy-pidfile branch
	## bails — we only care here that the managed-record-empty + alive
	## listener pidfile path produces SOME proof. Plant a managed record
	## that owns the listener so the strong-proof helper uses
	## `managed_record` proof instead of the cmdline-gated `pidfile_listener` one.
	host.managed_record = {"pid": 22222, "version": "2.1.0", "ws_port": 9500}
	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	host.free()

	assert_true(ok, "strong managed-record proof + freed port must succeed")
	assert_eq(killed, [22222] as Array[int])
	assert_eq(cleared, 1, "successful recovery must clear the stale managed record")


func test_recover_strong_port_occupant_preserves_record_when_port_held() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [33333] as Array[int]
	host.alive_pids = [33333] as Array[int]
	host.managed_record = {"pid": 33333, "version": "2.1.0", "ws_port": 9500}
	host.port_in_use_sequence = [true] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	host.free()

	assert_false(ok, "kill that didn't free the port must not report success")
	assert_eq(killed, [33333] as Array[int])
	assert_eq(cleared, 0, "failed recovery must preserve the managed record")


# ----- adopt_compatible_server (seam under test) -----------------------

func test_adopt_compatible_server_managed_when_versions_match() -> void:
	## The manager must record the owner PID + version when the live
	## server's version matches what the plugin recorded — the "this is
	## still ours" path. State writes go straight to plugin fields the
	## dock watches.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 12121)
	var server_pid := int(host._server_pid)
	host.free()

	assert_eq(label, "managed")
	assert_eq(server_pid, 12121, "managed adoption keeps the owner PID")


func test_adopt_compatible_server_external_when_record_drifts() -> void:
	## Stale record version + live current-compatible server: must adopt
	## as external (no managed PID, clears stale state). Mirrors
	## test_plugin_lifecycle.gd::test_external_compatible_adoption_clears_stale_managed_record.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.1.0", "2.2.0", 22222)
	var server_pid := int(host._server_pid)
	var cleared := host.cleared_record_calls
	host.free()

	assert_eq(label, "external")
	assert_eq(server_pid, -1, "external adoption must not record a managed PID")
	assert_eq(cleared, 1, "stale managed record must be cleared on external adoption")


func test_adopt_compatible_server_external_when_owner_unknown() -> void:
	## Even with a matching record version, an unknown owner (PID 0)
	## means the plugin can't prove what to manage — fall through to
	## external adoption.
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 0)
	host.free()

	assert_eq(label, "external", "no owner PID => can't claim managed ownership")


# ----- prepare_for_update_reload (seam under test) ---------------------

func test_prepare_for_update_reload_clears_spawn_guard() -> void:
	## The hard constraint from #297 PR 5: the static spawn-guard must
	## reset when `prepare_for_update_reload` runs so the re-enabled
	## plugin re-spawns. plugin.gd has its own test for this via the
	## delegating `prepare_for_update_reload` shim; here we hit the
	## manager directly, bypassing the shim, to lock in the seam's
	## responsibility.
	GodotAiPlugin._server_started_this_session = true
	var host := _ManagerHostStub.new()
	host._server_pid = -1  # nothing to stop
	host.port_in_use = false
	var manager := McpServerLifecycleManagerScript.new(host)

	manager.prepare_for_update_reload()
	var guard_after := GodotAiPlugin._server_started_this_session
	host.free()
	GodotAiPlugin._server_started_this_session = false

	assert_false(
		guard_after,
		"prepare_for_update_reload must reset the static spawn guard"
	)


# ----- start_server guard (seam under test) ----------------------------

func test_start_server_short_circuits_on_static_guard() -> void:
	## When the static guard is set (re-entrant spawn after disable / enable
	## in the same editor session), `start_server` must early-return without
	## touching ports, processes, or state. The path label "guarded" tells
	## the dock how to render the diagnostic.
	GodotAiPlugin._server_started_this_session = true
	var host := _ManagerHostStub.new()
	## If the guard fails, this poisoned port_in_use=true would route us
	## into the adopt / drift branches and fire a probe — which would set
	## `port_in_use_sequence`-relevant counters. Asserting they stayed at
	## defaults proves we never entered the body.
	host.port_in_use = true
	host.listener_pids = [99999] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)

	manager.start_server()
	var killed := host.killed_targets.duplicate()
	var cleared := host.cleared_record_calls
	var path := str(host._startup_path)
	host.free()
	GodotAiPlugin._server_started_this_session = false

	assert_eq(path, "guarded", "guarded path must be reported")
	assert_true(killed.is_empty(), "guarded path must not produce kills")
	assert_eq(cleared, 0, "guarded path must not touch the managed record")
