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


const TEST_PORT := 65431


func suite_name() -> String:
	return "server_lifecycle"


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

	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_false(ok)
	assert_true(killed.is_empty())


func test_recover_kills_and_clears_when_port_frees() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [22222] as Array[int]
	host.alive_pids = [22222] as Array[int]
	host.managed_record = {"pid": 22222, "version": "2.1.0", "ws_port": 9500}
	host.port_in_use_sequence = [false] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	host.free()

	assert_true(ok)


func test_recover_preserves_record_when_port_held() -> void:
	var host := _ManagerHostStub.new()
	host.listener_pids = [33333] as Array[int]
	host.alive_pids = [33333] as Array[int]
	host.managed_record = {"pid": 33333, "version": "2.1.0", "ws_port": 9500}
	host.port_in_use_sequence = [true] as Array[bool]
	var manager := McpServerLifecycleManagerScript.new(host)

	var ok := manager.recover_strong_port_occupant(TEST_PORT, 0.1)
	var cleared := host.cleared_record_calls
	host.free()

	assert_false(ok)
	assert_eq(cleared, 0)


# ----- adopt_compatible_server -----------------------------------------

func test_adopt_managed_when_versions_match() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)

	var label := manager.adopt_compatible_server("2.2.0", "2.2.0", 12121)
	var server_pid := int(manager._server_pid)
	host.free()

	assert_eq(label, McpAdoptionLabel.MANAGED)
	assert_eq(server_pid, 12121)


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
	host.branded_pids = [33333] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_eq(killed.size(), 3)
	assert_true(killed.has(11111))
	assert_true(killed.has(22222))
	assert_true(killed.has(33333))


func test_stop_does_not_kill_unbranded_port_listeners() -> void:
	## A POSIX IPv6 wildcard listener can show up in the same lsof query
	## as our managed IPv4 server. Stop must never sweep unrelated PIDs
	## just because they share the configured HTTP port.
	var host := _ManagerHostStub.new()
	host.listener_pids = [33333] as Array[int]
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 11111

	manager.stop_server()
	var killed := host.killed_targets.duplicate()
	host.free()

	assert_eq(killed.size(), 1)
	assert_true(killed.has(11111))
	assert_false(killed.has(33333))


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


# ----- check_server_health / start_server guards ----------------------

func test_check_server_health_short_circuits_when_pid_zero() -> void:
	var host := _ManagerHostStub.new()
	var manager := McpServerLifecycleManagerScript.new(host)
	manager._server_pid = 0

	manager.check_server_health()
	var stops := host.stop_watch_calls
	host.free()

	assert_eq(stops, 1)


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
