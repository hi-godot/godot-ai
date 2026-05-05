@tool
extends McpTestSuite

## Tests for the plugin's re-entrancy guard across disable/enable cycles.
## Regression coverage for the reload-plugin hang exposed by #159: once
## _stop_server became deterministic, the static _server_started_this_session
## flag persisted across disable/enable and made the re-enabled plugin's
## _start_server short-circuit with no server to adopt.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")

class _RefreshDock extends McpDock:
	var refresh_calls := 0
	func _refresh_all_client_statuses() -> void:
		refresh_calls += 1


class _ProofPlugin extends GodotAiPlugin:
	var listener_pids: Array[int] = []
	var managed_record := {"pid": 0, "version": "", "ws_port": 0}
	var live_status := {"name": "", "version": "", "ws_port": 0, "status_code": 0}
	var alive_pids: Array[int] = []
	var pid_file_pid := 0
	var branded_pids: Array[int] = []
	var port_in_use := false
	var port_in_use_sequence: Array[bool] = []
	var killed_targets: Array[int] = []
	var cleared_record_calls := 0
	var waited_calls := 0
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

	func _pid_cmdline_is_godot_ai(pid: int) -> bool:
		return branded_pids.has(pid)

	func _probe_live_server_status_for_port(_port: int) -> Dictionary:
		probe_calls += 1
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


## Test port high enough to almost never collide with real services and
## distinct from the plugin's configured http_port() so the stop-finalize tests
## don't interact with a developer's running managed server.
const TEST_PORT := 65432


func suite_name() -> String:
	return "plugin_lifecycle"


func setup() -> void:
	## The flag is a class-level static; leave it in a known state between
	## tests so ordering can't mask a regression.
	GodotAiPlugin._server_started_this_session = false


func teardown() -> void:
	GodotAiPlugin._server_started_this_session = false
	## Stop-finalize tests write to EditorSettings + the pid-file on disk;
	## scrub both so state doesn't leak across tests or outlast the suite.
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if es.has_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING):
			es.set_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING, 0)
		if es.has_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING):
			es.set_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING, "")
		if es.has_setting(GodotAiPlugin.MANAGED_SERVER_WS_PORT_SETTING):
			es.set_setting(GodotAiPlugin.MANAGED_SERVER_WS_PORT_SETTING, 0)
	if FileAccess.file_exists(GodotAiPlugin.SERVER_PID_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GodotAiPlugin.SERVER_PID_FILE))


func test_exit_tree_resets_spawn_guard() -> void:
	## The bug: after a successful spawn, the static flag stays true across
	## a plugin disable/enable cycle (same editor session). When the new
	## plugin instance's _enter_tree calls _start_server, the guard fires
	## and no respawn happens — the dock sits in "reconnecting…" forever.
	## Fix: _exit_tree must reset the flag so the next enable starts clean.
	GodotAiPlugin._server_started_this_session = true
	var plugin := GodotAiPlugin.new()
	## _stop_server early-returns on the default _server_pid (-1), and every
	## teardown branch in _exit_tree is null-guarded — so calling it on a
	## freshly constructed (never-entered-tree) instance is safe and does
	## not touch the editor or spawn processes.
	plugin._exit_tree()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"_exit_tree must clear the re-entrancy guard so the re-enabled plugin respawns"
	)


func test_prepare_for_update_reload_resets_spawn_guard() -> void:
	## Companion path used by the dock's Update button flow. Kept distinct
	## from _exit_tree because the update sequence calls this *before* the
	## disable/enable toggle, whereas _exit_tree runs *during* teardown.
	GodotAiPlugin._server_started_this_session = true
	var plugin := GodotAiPlugin.new()
	plugin.prepare_for_update_reload()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"prepare_for_update_reload must clear the re-entrancy guard before the toggle"
	)


func test_exit_tree_is_idempotent_when_guard_already_false() -> void:
	## If the plugin is disabled twice in a row (or disabled without ever
	## having spawned), the second _exit_tree must still leave the flag
	## false. Guards against accidental inversion of the reset.
	GodotAiPlugin._server_started_this_session = false
	var plugin := GodotAiPlugin.new()
	plugin._exit_tree()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"_exit_tree must not flip the guard back to true"
	)


func test_finalize_stop_clears_state_when_port_is_free() -> void:
	## When the kill succeeded and nothing holds the port anymore,
	## _stop_server's cleanup should drop the managed-server record and
	## the pid-file. Standard happy path.
	_seed_managed_record(12345, "1.2.9")
	_seed_pid_file(12345)
	var plugin := GodotAiPlugin.new()

	var cleared := plugin._finalize_stop_if_port_free(TEST_PORT)
	plugin.free()

	assert_true(cleared, "expected _finalize_stop_if_port_free to return true when port free")
	assert_eq(
		_read_record_version(),
		"",
		"managed-server record must be cleared when port is free"
	)
	assert_true(
		not FileAccess.file_exists(GodotAiPlugin.SERVER_PID_FILE),
		"pid-file must be cleared when port is free"
	)


func test_finalize_stop_preserves_state_when_port_still_in_use() -> void:
	## The regression the fix prevents: a failed kill leaves the port
	## occupied. If state were cleared anyway, the next _start_server
	## would see no record and take the "foreign server" branch, leaving
	## the zombie alive and the new plugin adopting an outdated server.
	## Preserving record + pid-file routes the next start through the
	## drift branch where the current (fixed) kill code gets a second
	## shot. See the v1.2.8 → v1.2.9 Update flow regression.
	var listener := TCPServer.new()
	var listen_err := listener.listen(TEST_PORT, "127.0.0.1")
	assert_eq(listen_err, OK, "test setup: must be able to bind TEST_PORT")

	_seed_managed_record(54321, "1.2.9")
	_seed_pid_file(54321)
	var plugin := GodotAiPlugin.new()

	var cleared := plugin._finalize_stop_if_port_free(TEST_PORT)
	plugin.free()
	listener.stop()

	assert_false(cleared, "expected _finalize_stop_if_port_free to return false when port busy")
	assert_eq(
		_read_record_version(),
		"1.2.9",
		"managed-server record must be preserved so drift branch can retry the kill"
	)
	assert_true(
		FileAccess.file_exists(GodotAiPlugin.SERVER_PID_FILE),
		"pid-file must be preserved so next _find_managed_pid has the deterministic hint"
	)


func test_stop_dev_server_only_kills_godot_ai_listeners() -> void:
	## `stop_dev_server` used to shell out to `lsof | xargs kill`, which
	## swept unrelated listeners that happened to share the configured HTTP
	## port. It must filter by the same godot-ai command-line proof used by
	## the managed lifecycle stop path.
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [11111, 22222] as Array[int]
	plugin.branded_pids = [22222] as Array[int]

	plugin.stop_dev_server()
	var killed := plugin.killed_targets.duplicate()
	plugin.free()

	assert_eq(killed.size(), 1)
	assert_eq(killed[0], 22222)


# ----- spawn state machine -----
#
# `get_server_status()` is the dock's single source of truth for what
# went wrong during startup. These tests pin down the contract: default
# state UNINITIALIZED, `_set_spawn_state` records the first specific
# terminal diagnosis and refuses later overwrites (so a PORT_EXCLUDED
# proactive hit can't be clobbered by a follow-up CRASHED signal from
# the watch loop).


func test_spawn_state_defaults_to_uninitialized() -> void:
	var plugin := GodotAiPlugin.new()
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(
		int(status.get("state", -1)),
		McpServerState.UNINITIALIZED,
		"fresh plugin must report UNINITIALIZED"
	)


func test_set_spawn_state_records_first_diagnosis() -> void:
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpServerState.FOREIGN_PORT)
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(int(status.get("state", -1)), McpServerState.FOREIGN_PORT)


func test_set_spawn_state_does_not_overwrite_specific_diagnosis() -> void:
	## The watch loop's CRASHED path fires late (up to SPAWN_GRACE_MS after
	## spawn). If a more specific diagnosis already landed earlier — e.g.
	## PORT_EXCLUDED from the proactive `netsh` check — the CRASHED code
	## would overwrite it with a less actionable state. `_set_spawn_state`
	## is first-writer-wins so the dock keeps showing the pointed message.
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpServerState.PORT_EXCLUDED)
	plugin._set_spawn_state(McpServerState.CRASHED)
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(
		int(status.get("state", -1)),
		McpServerState.PORT_EXCLUDED,
		"first diagnosis must win"
	)


func test_get_server_status_shape_is_stable() -> void:
	## Dock reads these keys; missing any is a render bug. Locked so a
	## future refactor of the plugin-side dict can't silently drop one.
	var plugin := GodotAiPlugin.new()
	var status := plugin.get_server_status()
	plugin.free()
	assert_has_key(status, "state")
	assert_has_key(status, "exit_ms")
	assert_has_key(status, "actual_name")
	assert_has_key(status, "actual_version")
	assert_has_key(status, "expected_version")
	assert_has_key(status, "message")
	assert_has_key(status, "can_recover_incompatible")
	assert_has_key(status, "connection_blocked")


func test_server_status_compatibility_requires_matching_ws_port() -> void:
	var ok := GodotAiPlugin._server_status_compatibility("2.2.0", "2.2.0", 9500, 9500, false)
	var wrong_ws := GodotAiPlugin._server_status_compatibility("2.2.0", "2.2.0", 9600, 9500, false)
	assert_true(bool(ok.get("compatible", false)), "matching version + WS port must be compatible")
	assert_false(
		bool(wrong_ws.get("compatible", true)),
		"same-version server on the wrong WS port must not be adopted"
	)
	assert_eq(wrong_ws.get("reason", ""), "ws_port_mismatch")


func test_managed_record_restart_requires_recorded_version_drift() -> void:
	assert_true(
		GodotAiPlugin._managed_record_has_version_drift("2.1.0", "2.2.0"),
		"older managed record must still authorize update restart"
	)
	assert_false(
		GodotAiPlugin._managed_record_has_version_drift("2.2.0", "2.2.0"),
		"matching managed record must not authorize killing an unverified port owner"
	)
	assert_false(
		GodotAiPlugin._managed_record_has_version_drift("", "2.2.0"),
		"missing managed record must not authorize restart"
	)


func test_commandline_fingerprint_is_case_insensitive_and_requires_flag() -> void:
	assert_true(
		GodotAiPlugin._commandline_is_godot_ai_server(
			"C:/Python/python.exe -m GODOT_AI --TRANSPORT streamable-http"
		),
		"brand and management flag should match case-insensitively"
	)
	assert_true(
		GodotAiPlugin._commandline_is_godot_ai_server(
			"C:/Python/python.exe -m godot-ai --pid-file C:/tmp/godot_ai_server.pid"
		),
		"hyphenated brand plus pid-file flag should identify the server"
	)
	assert_false(
		GodotAiPlugin._commandline_is_godot_ai_server("C:/Python/python.exe -m godot_ai"),
		"brand alone is not enough ownership proof"
	)
	assert_false(
		GodotAiPlugin._commandline_is_godot_ai_server(""),
		"empty cmdline (lookup failure) must never be accepted as proof"
	)


func test_commandline_fingerprint_ignores_brand_in_pidfile_path() -> void:
	## Regression: the pidfile path itself is `<user>/godot_ai_server.pid`,
	## so a substring brand search would falsely match an unrelated process
	## that happens to reference a similarly-named pidfile. The brand must
	## come from somewhere outside the --pid-file value.
	assert_false(
		GodotAiPlugin._commandline_is_godot_ai_server(
			"someprogram --pid-file /var/run/godot_ai_server.pid --transport tcp"
		),
		"brand in pidfile path alone must not satisfy ownership proof"
	)
	assert_false(
		GodotAiPlugin._commandline_is_godot_ai_server(
			"someprogram --pid-file=/var/run/godot_ai_server.pid --transport tcp"
		),
		"--pid-file=<value> form must also strip the path before brand search"
	)
	assert_true(
		GodotAiPlugin._commandline_is_godot_ai_server(
			"/usr/bin/python -m godot_ai --transport streamable-http --pid-file /tmp/godot_ai_server.pid"
		),
		"real server invocation has brand outside the pidfile value, must still match"
	)


func test_strip_pidfile_value_handles_space_and_equals_forms() -> void:
	## Whitespace form: keep the bare flag, drop the value.
	assert_eq(
		GodotAiPlugin._strip_pidfile_value("foo --pid-file /tmp/x.pid bar"),
		"foo --pid-file  bar"
	)
	## Equals form: same outcome.
	assert_eq(
		GodotAiPlugin._strip_pidfile_value("foo --pid-file=/tmp/x.pid bar"),
		"foo --pid-file  bar"
	)
	## No --pid-file flag: returned unchanged.
	assert_eq(
		GodotAiPlugin._strip_pidfile_value("foo --transport tcp"),
		"foo --transport tcp"
	)


func test_pid_cmdline_rejects_sentinel_pids() -> void:
	## Init/PID 1 and pid 0 must never be considered candidates for kill.
	## A stale pidfile that somehow contains 0 or 1 has to bail before any
	## OS lookup, otherwise we'd risk targeting init on POSIX.
	var plugin := GodotAiPlugin.new()
	assert_false(plugin._pid_cmdline_is_godot_ai(0), "pid 0 must never match")
	assert_false(plugin._pid_cmdline_is_godot_ai(1), "pid 1 (init) must never match")
	plugin.free()


func test_posix_pid_commandline_reads_procfs_despite_zero_length() -> void:
	## procfs pseudo-files (/proc/<pid>/cmdline) report length 0 even though
	## they have content. If we sized the read by `get_length()` we'd get
	## an empty string back and the legacy pidfile proof would silently
	## fail on Linux. Verify the chunked-read path actually returns data
	## for a known-live PID (the editor itself).
	if not FileAccess.file_exists("/proc/self/cmdline"):
		skip("/proc not available — Linux-only test")
		return
	var plugin := GodotAiPlugin.new()
	var cmd := plugin._posix_pid_commandline(OS.get_process_id())
	plugin.free()
	assert_false(
		cmd.is_empty(),
		"chunked read must return non-empty cmdline for the editor's own PID"
	)
	## The editor cmdline must contain the Godot binary path; this also
	## confirms NUL-to-space conversion produced a usable string.
	assert_true(
		cmd.to_lower().find("godot") >= 0,
		"editor cmdline should contain 'godot' substring, got: %s" % cmd
	)


func test_pid_cmdline_rejects_unrelated_local_pid() -> void:
	## Regression for the cross-platform pidfile-proof bug: previously the
	## non-Windows path returned true unconditionally, so a stale pidfile
	## whose PID had been recycled by an unrelated listener could be accepted
	## as a kill target. Now the function must actually inspect the cmdline.
	## The current Godot editor process is a convenient stand-in for an
	## "unrelated" PID — its cmdline contains no `--pid-file` / `--transport`
	## flags, so the brand+flag fingerprint must reject it.
	if OS.get_name() == "Windows":
		skip("POSIX-only path: Windows uses PowerShell, exercised elsewhere")
		return
	var plugin := GodotAiPlugin.new()
	var godot_pid := OS.get_process_id()
	var matches := plugin._pid_cmdline_is_godot_ai(godot_pid)
	plugin.free()
	assert_false(
		matches,
		"editor PID's cmdline lacks --pid-file/--transport, must not match godot-ai server fingerprint"
	)


class _RealCmdlinePlugin extends GodotAiPlugin:
	## Exercises the real `_pid_cmdline_is_godot_ai` inside the kill-target
	## path. Mocks the pidfile / liveness lookups but lets the cmdline
	## fingerprint flow through to the OS-specific reader (`/proc` on Linux,
	## `ps` on macOS/*BSD, PowerShell on Windows). Regression coverage for
	## the bug where the POSIX path returned true unconditionally.
	var listener_pids: Array[int] = []
	var pid_file_pid := 0
	var alive_pids: Array[int] = []

	func _read_pid_file_for_proof() -> int:
		return pid_file_pid

	func _pid_alive_for_proof(pid: int) -> bool:
		return alive_pids.has(pid)


func test_legacy_pidfile_kill_targets_requires_real_brand_proof() -> void:
	## Spawn a benign child (`sleep`) so we have an unrelated live PID we
	## can plant in the pidfile slot. Without the fix, `_legacy_pidfile_kill_targets`
	## would return [child_pid] on POSIX because the cmdline check returned
	## true unconditionally. With the fix, the child's cmdline (no
	## --pid-file / --transport) is rejected and no kill targets are produced.
	if OS.get_name() == "Windows":
		skip("POSIX-only regression: Windows path covered by netstat parser tests")
		return
	var sleep_path := "/bin/sleep"
	if not FileAccess.file_exists(sleep_path):
		sleep_path = "/usr/bin/sleep"
		if not FileAccess.file_exists(sleep_path):
			skip("sleep(1) not available on this host")
			return
	var child_pid := OS.create_process(sleep_path, ["30"])
	if child_pid <= 0:
		skip("OS.create_process unavailable in this test environment")
		return
	var plugin := _RealCmdlinePlugin.new()
	plugin.listener_pids = [child_pid] as Array[int]
	plugin.pid_file_pid = child_pid
	plugin.alive_pids = [child_pid] as Array[int]

	var targets := plugin._legacy_pidfile_kill_targets(TEST_PORT, plugin.listener_pids)
	plugin.free()
	OS.kill(child_pid)

	assert_true(
		targets.is_empty(),
		"unrelated live PID in pidfile must not produce kill targets without brand+flag cmdline proof"
	)


func test_strong_proof_accepts_live_managed_record_pid() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [24680] as Array[int]
	plugin.managed_record = {"pid": 24680, "version": "2.1.0", "ws_port": 9500}
	plugin.alive_pids = [24680] as Array[int]

	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT)
	plugin.free()

	assert_eq(proof.get("proof", ""), "managed_record")
	var pids: Array[int] = []
	pids.assign(proof.get("pids", []))
	assert_eq(pids, [24680] as Array[int])


func test_legacy_pidfile_proof_returns_all_branded_listener_pids() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [11111, 22222, 33333] as Array[int]
	plugin.pid_file_pid = 11111
	plugin.alive_pids = [11111] as Array[int]
	plugin.branded_pids = [11111, 22222] as Array[int]

	var targets := plugin._legacy_pidfile_kill_targets(TEST_PORT, plugin.listener_pids)
	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT)
	plugin.free()

	assert_eq(targets, [11111, 22222] as Array[int])
	assert_eq(proof.get("proof", ""), "pidfile_listener")
	var pids: Array[int] = []
	pids.assign(proof.get("pids", []))
	assert_eq(pids, [11111, 22222] as Array[int])


func test_strong_proof_accepts_status_matching_managed_record_version() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "2.1.0", "ws_port": 9500}
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT)
	plugin.free()

	assert_eq(proof.get("proof", ""), "status_matches_record")
	var pids: Array[int] = []
	pids.assign(proof.get("pids", []))
	assert_eq(pids, [13579] as Array[int])


func test_strong_proof_rejects_status_name_only() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "", "ws_port": 0}
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT)
	plugin.free()

	assert_eq(proof.get("proof", ""), "")
	var pids: Array[int] = []
	pids.assign(proof.get("pids", []))
	assert_true(pids.is_empty())


func test_recovery_proof_accepts_status_name_only() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_recovery_port_occupant_proof(TEST_PORT)
	plugin.free()

	assert_eq(proof.get("proof", ""), "status_name")
	var pids: Array[int] = []
	pids.assign(proof.get("pids", []))
	assert_eq(pids, [13579] as Array[int])


func test_strong_recovery_kills_pidfile_listener_when_port_frees() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [11111] as Array[int]
	plugin.pid_file_pid = 11111
	plugin.alive_pids = [11111] as Array[int]
	plugin.branded_pids = [11111] as Array[int]
	plugin.port_in_use_sequence = [false] as Array[bool]

	var ok := plugin._recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := plugin.killed_targets.duplicate()
	var waited_calls := plugin.waited_calls
	var clear_calls := plugin.cleared_record_calls
	plugin.free()

	assert_true(ok, "strong pidfile proof should recover when the port frees")
	assert_eq(killed, [11111] as Array[int])
	assert_eq(waited_calls, 1)
	assert_eq(clear_calls, 1, "successful recovery must clear stale managed state")


func test_strong_recovery_preserves_state_when_port_stays_held() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [11111] as Array[int]
	plugin.pid_file_pid = 11111
	plugin.alive_pids = [11111] as Array[int]
	plugin.branded_pids = [11111] as Array[int]
	plugin.port_in_use_sequence = [true] as Array[bool]

	var ok := plugin._recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := plugin.killed_targets.duplicate()
	var waited_calls := plugin.waited_calls
	var clear_calls := plugin.cleared_record_calls
	plugin.free()

	assert_false(ok, "recovery must fail when the port stays held")
	assert_eq(killed, [11111] as Array[int])
	assert_eq(waited_calls, 1)
	assert_eq(clear_calls, 0, "failed recovery must preserve stale ownership state")


func test_strong_recovery_rejects_status_name_only() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var ok := plugin._recover_strong_port_occupant(TEST_PORT, 0.1)
	var killed := plugin.killed_targets.duplicate()
	var waited_calls := plugin.waited_calls
	var clear_calls := plugin.cleared_record_calls
	plugin.free()

	assert_false(ok, "status_name proof is recoverable by click, not by automatic startup kill")
	assert_true(killed.is_empty())
	assert_eq(waited_calls, 0)
	assert_eq(clear_calls, 0)


func test_can_recover_incompatible_server_requires_state_and_recovery_proof() -> void:
	var plugin := _ProofPlugin.new()
	plugin.port_in_use = true
	plugin.listener_pids = [13579] as Array[int]
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	assert_false(plugin.can_recover_incompatible_server(), "OK state must not expose recovery")
	plugin._lifecycle._server_state = McpServerState.INCOMPATIBLE
	assert_true(plugin.can_recover_incompatible_server(), "status-name proof should allow clicked recovery")
	plugin.free()


func test_external_compatible_adoption_clears_stale_managed_record() -> void:
	## If a live compatible server is verified but its managed record does
	## not match the current plugin version, the plugin treats it as external.
	## That must also clear the stale record; otherwise later restart paths
	## would treat the old record as ownership proof and kill the external
	## process.
	_seed_managed_record(11111, "2.1.0")
	_seed_pid_file(11111)
	var plugin := GodotAiPlugin.new()

	var owner_label := plugin._adopt_compatible_server("2.1.0", "2.2.0", 22222)
	var can_restart := plugin.can_restart_managed_server()
	var server_pid: int = int(plugin._lifecycle._server_pid)
	plugin.free()

	assert_eq(owner_label, "external")
	assert_eq(server_pid, -1, "external adoption must not keep a managed PID")
	assert_eq(_read_record_version(), "", "stale managed record must be cleared")
	assert_false(
		FileAccess.file_exists(GodotAiPlugin.SERVER_PID_FILE),
		"stale pid-file must be cleared with the stale record"
	)
	assert_false(can_restart, "external adoption must not authorize managed restart")


func test_external_compatible_adoption_log_reports_observed_owner() -> void:
	var message := GodotAiPlugin._compatible_adoption_log_message(
		"external",
		-1,
		22222,
		"2.2.3",
		9500,
		"2.2.3"
	)
	assert_contains(message, "adopted external server owner_pid=22222")
	assert_false(
		message.find("PID -1") >= 0,
		"external adoption log must not report the intentionally unowned _server_pid"
	)


func test_managed_compatible_adoption_log_reports_owned_pid() -> void:
	var message := GodotAiPlugin._compatible_adoption_log_message(
		"managed",
		22222,
		22222,
		"2.2.3",
		9500,
		"2.2.3"
	)
	assert_contains(message, "adopted managed server (PID 22222")


func test_resolved_ws_port_drops_stale_record_value() -> void:
	## Regression for the cached-ws-port + stale-ownership interaction.
	## Setup mirrors the bad shape from the field:
	##
	##   - managed record carries an old plugin version (`2.1.0`) and the
	##     resolved WS port that older install picked (`9500`)
	##   - the live server on the same HTTP port speaks the *current* plugin
	##     version on a *different* current WS port (`10500`, e.g. because
	##     the user upgraded the plugin and Windows started reserving 9500)
	##
	## Before the gate: `_start_server` would seed `_resolved_ws_port` with
	## the stale `9500` from the record, the compatibility check would then
	## report a WS-mismatch against the live `10500`, the version-drift
	## branch would treat the matching-but-stale-version record as
	## ownership proof, and we'd kill an unrelated external process.
	##
	## After the gate: a stale record has its `ws_port` discarded, the
	## fresh-resolved value is used instead, the compatibility check
	## succeeds against the live current server, and adoption flows through
	## the external path (which then clears the stale record). End-to-end
	## tested below by composing this helper with `_adopt_compatible_server`.
	var stale_record_ws := 9500
	var fresh_resolved := 10500
	var stale := GodotAiPlugin._resolved_ws_port_for_existing_server(
		stale_record_ws, "2.1.0", "2.2.0", fresh_resolved
	)
	assert_eq(stale, fresh_resolved, "stale record version must drop the cached ws_port")

	var matching := GodotAiPlugin._resolved_ws_port_for_existing_server(
		stale_record_ws, "2.2.0", "2.2.0", fresh_resolved
	)
	assert_eq(
		matching,
		stale_record_ws,
		"matching record version is current ownership proof — keep the cached ws_port"
	)

	var missing := GodotAiPlugin._resolved_ws_port_for_existing_server(
		0, "2.2.0", "2.2.0", fresh_resolved
	)
	assert_eq(missing, fresh_resolved, "no cached ws_port -> use fresh-resolved")

	var no_record := GodotAiPlugin._resolved_ws_port_for_existing_server(
		stale_record_ws, "", "2.2.0", fresh_resolved
	)
	assert_eq(no_record, fresh_resolved, "empty record version is not ownership proof")

	## Defensive: an empty `current_version` (handler not initialised yet)
	## must not collapse to `record_version == current_version == ""` and
	## start treating any record as ownership proof.
	var empty_current := GodotAiPlugin._resolved_ws_port_for_existing_server(
		stale_record_ws, "", "", fresh_resolved
	)
	assert_eq(empty_current, fresh_resolved, "empty current version cannot be ownership proof")


func test_stale_ws_port_does_not_authorize_killing_external_server() -> void:
	## End-to-end shape of the regression: a stale managed record (old
	## version, old cached `ws_port`) sitting in EditorSettings, and a
	## live current-version server bound to a different current WS port.
	## Composed from the two units the live `_start_server` runs in
	## sequence: drop the stale cached ws_port, then route the matching
	## live server through the external-adoption path which clears the
	## stale record. If either step regresses, the version-drift branch
	## could re-acquire ownership and kill the external process.
	const STALE_RECORD_WS := 9500
	const LIVE_CURRENT_WS := 10500
	const CURRENT := "2.2.0"
	const STALE := "2.1.0"
	_seed_managed_record(11111, STALE)
	_seed_pid_file(11111)

	## Step 1: WS-port resolver must drop the stale cached value, otherwise
	## the compatibility check below would falsely report ws_port_mismatch.
	var resolved := GodotAiPlugin._resolved_ws_port_for_existing_server(
		STALE_RECORD_WS, STALE, CURRENT, LIVE_CURRENT_WS
	)
	assert_eq(resolved, LIVE_CURRENT_WS, "stale ws_port must be ignored before the compatibility probe")

	## Step 2: with the freshly-resolved expected port, a live current
	## server passes compatibility — the precondition for adoption.
	var compatibility := GodotAiPlugin._server_status_compatibility(
		CURRENT, CURRENT, LIVE_CURRENT_WS, resolved, false
	)
	assert_true(
		bool(compatibility.get("compatible", false)),
		"live current server on the actual current WS port must be compatible"
	)

	## Step 3: adoption with a stale record version routes through the
	## external path and clears the stale record — same contract #259
	## locked in for PID + version, now extended to ws_port.
	var plugin := GodotAiPlugin.new()
	var owner_label := plugin._adopt_compatible_server(STALE, CURRENT, 22222)
	var server_pid: int = int(plugin._lifecycle._server_pid)
	var can_restart := plugin.can_restart_managed_server()
	plugin.free()

	assert_eq(owner_label, "external", "stale-version live server must adopt as external")
	assert_eq(server_pid, -1, "external adoption must not record a managed PID we could later kill")
	assert_eq(_read_record_version(), "", "stale record must be cleared on external adoption")
	assert_false(can_restart, "external adoption must not authorize managed restart")


func test_matching_compatible_adoption_keeps_managed_ownership() -> void:
	_seed_managed_record(11111, "2.2.0")
	var plugin := GodotAiPlugin.new()

	var owner_label := plugin._adopt_compatible_server("2.2.0", "2.2.0", 22222)
	var can_restart := plugin.can_restart_managed_server()
	var server_pid: int = int(plugin._lifecycle._server_pid)
	plugin.free()

	assert_eq(owner_label, "managed")
	assert_eq(server_pid, 22222)
	assert_eq(_read_record_version(), "2.2.0")
	assert_true(can_restart, "managed adoption must keep restart authorization")


func test_server_version_compatibility_requires_exact_match_in_release_mode() -> void:
	var exact := GodotAiPlugin._server_version_compatibility("2.2.0", "2.2.0", false)
	var old := GodotAiPlugin._server_version_compatibility("1.2.10", "2.2.0", false)
	var unknown := GodotAiPlugin._server_version_compatibility("", "2.2.0", false)
	assert_true(bool(exact.get("compatible", false)), "exact release version must be compatible")
	assert_false(bool(old.get("compatible", true)), "old release server must be incompatible")
	assert_false(bool(unknown.get("compatible", true)), "unknown live version must be incompatible")


func test_server_version_compatibility_allows_visible_dev_mismatch() -> void:
	var result := GodotAiPlugin._server_version_compatibility("2.2.0-dev", "2.2.0", true)
	assert_true(bool(result.get("compatible", false)), "dev checkout may reuse a mismatched dev server")
	assert_true(
		bool(result.get("dev_mismatch_allowed", false)),
		"dev mismatch must be flagged so the dock can render it visibly"
	)


func test_incompatible_server_message_names_actual_version_when_discoverable() -> void:
	var message := GodotAiPlugin._incompatible_server_message(
		{"version": "1.2.10"},
		"2.2.0",
		8000,
		McpClientConfigurator.ws_port(),
	)
	assert_contains(message, "Port 8000 is occupied by godot-ai server v1.2.10")
	assert_contains(message, "plugin expects v2.2.0")
	assert_contains(message, "change both HTTP and WS ports")


func test_incompatible_server_message_names_ws_port_mismatch() -> void:
	var message := GodotAiPlugin._incompatible_server_message(
		{"name": "godot-ai", "version": "2.2.0", "ws_port": 9600},
		"2.2.0",
		8000,
		McpClientConfigurator.ws_port(),
	)
	assert_contains(message, "using WS port 9600")
	assert_contains(message, "with WS port %d" % McpClientConfigurator.ws_port())
	assert_contains(message, "change both HTTP and WS ports")


func test_incompatible_transition_refreshes_dock_client_statuses() -> void:
	var plugin := _ProofPlugin.new()
	var dock := _RefreshDock.new()
	plugin._dock = dock
	plugin._set_incompatible_server({"version": "1.2.10"}, "2.2.0", 8000)
	var calls := dock.refresh_calls
	dock.free()
	plugin.free()

	assert_eq(calls, 1, "late incompatible transition must resweep dock client status")


func test_incompatible_status_exposes_actual_name_and_recovery_flag() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [24680] as Array[int]
	plugin.live_status = {"name": "godot-ai", "version": "1.2.10", "ws_port": 9500, "status_code": 200}
	plugin._set_incompatible_server(plugin.live_status, "2.2.0", TEST_PORT)
	var status := plugin.get_server_status()
	plugin.free()

	assert_eq(status.get("actual_name", ""), "godot-ai")
	assert_true(bool(status.get("can_recover_incompatible", false)))


func test_drift_kill_without_strong_targets_sets_incompatible_and_preserves_record() -> void:
	var plugin := _ProofPlugin.new()
	plugin.port_in_use_sequence = [true] as Array[bool]
	plugin.listener_pids = [24680] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "old-managed-for-test", "ws_port": 9500}
	plugin.live_status = {"name": "other-server", "version": "old-managed-for-test", "ws_port": 9500, "status_code": 200}

	plugin._start_server()
	var status := plugin.get_server_status()
	var killed := plugin.killed_targets.duplicate()
	var clear_calls := plugin.cleared_record_calls
	var server_pid: int = int(plugin._lifecycle._server_pid)
	plugin.free()

	assert_eq(int(status.get("state", -1)), McpServerState.INCOMPATIBLE)
	assert_true(killed.is_empty(), "drift branch must not kill without strong proof")
	assert_eq(clear_calls, 0, "failed drift proof must preserve the managed record")
	assert_eq(server_pid, -1, "drift branch must not spawn into a port with no strong kill target")


func test_drift_kill_preserves_record_and_does_not_spawn_when_port_stays_held() -> void:
	var plugin := _ProofPlugin.new()
	plugin.port_in_use_sequence = [true, true] as Array[bool]
	plugin.listener_pids = [24680] as Array[int]
	plugin.managed_record = {"pid": 24680, "version": "old-managed-for-test", "ws_port": 9500}
	plugin.alive_pids = [24680] as Array[int]
	plugin.live_status = {"name": "other-server", "version": "old-managed-for-test", "ws_port": 9500, "status_code": 200}

	plugin._start_server()
	var status := plugin.get_server_status()
	var killed := plugin.killed_targets.duplicate()
	var clear_calls := plugin.cleared_record_calls
	var server_pid: int = int(plugin._lifecycle._server_pid)
	plugin.free()

	assert_eq(int(status.get("state", -1)), McpServerState.INCOMPATIBLE)
	assert_eq(killed, [24680] as Array[int])
	assert_eq(clear_calls, 0, "held port after kill must preserve the managed record")
	assert_eq(server_pid, -1, "drift branch must not spawn while the port is still held")


func test_force_restart_preserves_record_when_port_remains_held() -> void:
	var plugin := _ProofPlugin.new()
	plugin.port_in_use = true
	plugin.listener_pids = [24680] as Array[int]
	plugin.managed_record = {"pid": 24680, "version": "old-managed-for-test", "ws_port": 9500}
	plugin.live_status = {"name": "other-server", "version": "old-managed-for-test", "ws_port": 9500, "status_code": 200}

	plugin.force_restart_server()
	var status := plugin.get_server_status()
	var killed := plugin.killed_targets.duplicate()
	var clear_calls := plugin.cleared_record_calls
	plugin.free()

	assert_eq(int(status.get("state", -1)), McpServerState.INCOMPATIBLE)
	assert_eq(killed, [24680] as Array[int])
	assert_eq(clear_calls, 0, "force restart must not clear ownership while the port is still held")


func test_recover_incompatible_returns_false_and_leaves_state_when_port_remains_held() -> void:
	var plugin := _ProofPlugin.new()
	plugin._lifecycle._server_state = McpServerState.INCOMPATIBLE
	plugin._lifecycle._connection_blocked = true
	plugin.port_in_use = true
	plugin.listener_pids = [24680] as Array[int]
	plugin.live_status = {"name": "godot-ai", "version": "1.2.10", "ws_port": 9500, "status_code": 200}

	var ok := plugin.recover_incompatible_server()
	var status := plugin.get_server_status()
	var killed := plugin.killed_targets.duplicate()
	var clear_calls := plugin.cleared_record_calls
	plugin.free()

	assert_false(ok, "recovery click must report failure when the kill did not free the port")
	assert_eq(int(status.get("state", -1)), McpServerState.INCOMPATIBLE)
	assert_true(bool(status.get("connection_blocked", false)))
	assert_eq(killed, [24680] as Array[int])
	assert_eq(clear_calls, 0, "failed recovery must preserve record/pid-file state")


func test_recovery_resume_unblocks_connection_while_spawn_is_in_flight() -> void:
	## Recovery click kills the incompatible occupant and starts a fresh
	## server, leaving lifecycle state at SPAWNING until the WebSocket
	## handshake verifies the version. The connection must be unblocked
	## during SPAWNING, otherwise the dock sits forever at "Restarting".
	var plugin := GodotAiPlugin.new()
	var conn := McpConnection.new()
	conn.connect_blocked = true
	conn.connect_block_reason = "incompatible"
	conn.server_version = "1.2.10"
	plugin._connection = conn
	plugin._lifecycle._server_state = McpServerState.SPAWNING
	plugin._lifecycle._connection_blocked = false

	plugin._resume_connection_after_recovery()
	var blocked := conn.connect_blocked
	var reason := conn.connect_block_reason
	var version := conn.server_version
	var awaiting: bool = plugin._lifecycle.is_awaiting_server_version()
	conn.free()
	plugin.free()

	assert_false(blocked)
	assert_eq(reason, "")
	assert_eq(version, "")
	assert_true(awaiting)


func test_connection_established_waits_for_version_before_clearing_foreign_port() -> void:
	## A WebSocket opening is not enough proof anymore: old pre-rollup
	## servers accept the plugin session while still exposing an incompatible
	## HTTP/MCP tool surface. FOREIGN_PORT only clears after the live server
	## version is verified.
	_seed_managed_record(99999, "other-version")
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpServerState.FOREIGN_PORT)
	assert_eq(
		plugin.get_server_status().get("state", ""),
		McpServerState.FOREIGN_PORT,
		"precondition: FOREIGN_PORT must be set before adoption-confirmation fires"
	)

	plugin._on_connection_established()
	var state: int = int(plugin.get_server_status().get("state", -1))
	var awaiting: bool = bool(plugin._lifecycle.is_awaiting_server_version())
	plugin.free()

	assert_eq(
		state,
		McpServerState.FOREIGN_PORT,
		"opening the WebSocket must not clear FOREIGN_PORT before version verification"
	)
	assert_true(awaiting, "connection establishment must arm the server-version check")


func test_verified_matching_server_clears_foreign_port() -> void:
	var plugin := GodotAiPlugin.new()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	plugin._lifecycle._server_expected_version = plugin_ver
	plugin._set_spawn_state(McpServerState.FOREIGN_PORT)
	plugin._on_server_version_verified(plugin_ver)
	var status := plugin.get_server_status()
	plugin.free()

	assert_eq(int(status.get("state", -1)), McpServerState.READY)
	assert_eq(status.get("actual_version", ""), plugin_ver)
	assert_false(bool(status.get("connection_blocked", true)))


func test_verified_old_server_becomes_incompatible_and_blocks_connection() -> void:
	## Force user-mode for the duration of this test so the dev-checkout
	## heuristic — which silently treats any version mismatch as compatible
	## when run from a `.venv`-adjacent worktree — can't make 1.2.10 look
	## OK against an expected 2.2.0. Without this the test is non-
	## deterministic across CI runners and dev machines.
	var prior_setting: Variant = null
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING):
		prior_setting = es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING)
	var prior_env := OS.get_environment("GODOT_AI_MODE")
	if es != null:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, "user")
	OS.set_environment("GODOT_AI_MODE", "user")

	var plugin := GodotAiPlugin.new()
	plugin._lifecycle._server_expected_version = "2.2.0"
	plugin._on_server_version_verified("1.2.10")
	var status := plugin.get_server_status()
	plugin.free()

	if es != null:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, prior_setting if prior_setting != null else "")
	if prior_env.is_empty():
		OS.unset_environment("GODOT_AI_MODE")
	else:
		OS.set_environment("GODOT_AI_MODE", prior_env)

	assert_eq(int(status.get("state", -1)), McpServerState.INCOMPATIBLE)
	assert_eq(status.get("actual_version", ""), "1.2.10")
	assert_true(bool(status.get("connection_blocked", false)))
	assert_contains(
		str(status.get("message", "")),
		"Port %d is occupied by godot-ai server v1.2.10; plugin expects v2.2.0"
			% McpClientConfigurator.http_port(),
	)


func test_connection_established_preserves_crashed_state() -> void:
	## Sanity check for the guard: only FOREIGN_PORT is preemptive enough
	## to need post-hoc clearing. Other diagnoses (CRASHED, PORT_EXCLUDED,
	## NO_COMMAND) are terminal — the server never came up, so no
	## WebSocket can open and `_on_connection_established` should never
	## fire in those states in the real flow. But if it ever does, don't
	## paper over a real failure.
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpServerState.CRASHED)
	plugin._on_connection_established()
	var state: int = int(plugin.get_server_status().get("state", -1))
	plugin.free()
	assert_eq(
		state,
		McpServerState.CRASHED,
		"_on_connection_established must only clear FOREIGN_PORT, not other diagnoses"
	)


func test_watch_for_adoption_confirmation_arms_bounded_deadline() -> void:
	## `_start_server`'s FOREIGN_PORT branch arms the adoption watcher
	## instead of passively waiting. The watcher must be bounded — an
	## un-bounded `set_process(true)` would poll every frame forever if
	## the foreign occupant never opens a WebSocket, so we latch a
	## deadline SPAWN_GRACE_MS in the future. `_process` self-disarms on
	## first successful connect OR on deadline expiry, whichever comes
	## first. This test just pins the deadline-arming half of the contract.
	var plugin := GodotAiPlugin.new()
	assert_eq(plugin._lifecycle._adoption_watch_deadline_ms, 0, "precondition: deadline disarmed")
	var before_ms := Time.get_ticks_msec()
	plugin._watch_for_adoption_confirmation()
	var deadline: int = int(plugin._lifecycle._adoption_watch_deadline_ms)
	plugin.free()
	assert_true(deadline >= before_ms, "deadline must be set into the future")
	## Lower bound: SPAWN_GRACE_MS minus a generous 100ms slack for any
	## scheduler jitter between `before_ms` and the latching call.
	assert_true(
		deadline - before_ms >= GodotAiPlugin.SPAWN_GRACE_MS - 100,
		"deadline must be ~SPAWN_GRACE_MS (%dms) into the future" % GodotAiPlugin.SPAWN_GRACE_MS
	)


func test_process_clears_foreign_port_after_matching_version_ack() -> void:
	## Integration test for the full adoption-confirm loop:
	## `_watch_for_adoption_confirmation` arms the deadline + `_process`,
	## then `_process` waits for McpConnection.server_version. Mere connection
	## is insufficient; a matching ack is what authorizes adoption.
	var plugin := GodotAiPlugin.new()
	var conn := McpConnection.new()
	plugin._connection = conn
	plugin._lifecycle._server_expected_version = McpClientConfigurator.get_plugin_version()
	plugin._set_spawn_state(McpServerState.FOREIGN_PORT)
	plugin._watch_for_adoption_confirmation()
	plugin._arm_server_version_check()
	assert_true(plugin._lifecycle._adoption_watch_deadline_ms > 0, "precondition: watcher armed")

	conn._connected = true  # simulate WebSocket STATE_OPEN transition
	conn.server_version = plugin._lifecycle._server_expected_version
	plugin._process(0.0)
	var state: int = int(plugin.get_server_status().get("state", -1))
	var deadline: int = int(plugin._lifecycle._adoption_watch_deadline_ms)
	conn.free()
	plugin.free()

	assert_eq(state, McpServerState.READY, "_process must clear FOREIGN_PORT after version match")
	assert_true(deadline > 0, "adoption deadline is independent of version verification")


func test_process_self_disarms_after_deadline_without_connect() -> void:
	## If the foreign occupant never opens a WebSocket (e.g. it's a
	## genuine non-MCP process), the watcher must give up after
	## SPAWN_GRACE_MS so `_process` stops running every frame. The deadline
	## stays zero afterwards, serving as the "disarmed" sentinel.
	var plugin := GodotAiPlugin.new()
	var conn := McpConnection.new()
	plugin._connection = conn
	plugin._set_spawn_state(McpServerState.FOREIGN_PORT)
	plugin._lifecycle._adoption_watch_deadline_ms = Time.get_ticks_msec() - 1  # already expired
	plugin.set_process(true)
	plugin._process(0.0)
	var state: int = int(plugin.get_server_status().get("state", -1))
	var deadline: int = int(plugin._lifecycle._adoption_watch_deadline_ms)
	conn.free()
	plugin.free()

	assert_eq(state, McpServerState.FOREIGN_PORT, "deadline expiry must leave FOREIGN_PORT set")
	assert_eq(deadline, 0, "_process must zero the deadline on timeout")


# ----- lsof multi-pid parsing -----
#
# `_find_pid_on_port` / `_find_all_pids_on_port` drive the `force_restart_server`
# kill path. Before this test, the parser collapsed "32696\n39824" (uvicorn's
# reloader parent + worker both bound to the same port) into an invalid-int
# check and returned 0 — so `OS.kill(0)` silently no-oped and the Restart
# button went through the motions without actually killing anything.


func test_parse_lsof_pids_single_line() -> void:
	var pids := GodotAiPlugin._parse_lsof_pids("32696")
	assert_eq(pids.size(), 1)
	assert_eq(pids[0], 32696)


func test_parse_lsof_pids_multi_line() -> void:
	## The regression: uvicorn --reload binds both a reloader parent and
	## a worker to port 8000. lsof -ti returns them newline-separated.
	## Parser must yield both so `force_restart_server` can kill both.
	var pids := GodotAiPlugin._parse_lsof_pids("32696\n39824")
	assert_eq(pids.size(), 2)
	assert_eq(pids[0], 32696)
	assert_eq(pids[1], 39824)


func test_parse_lsof_pids_trailing_newline() -> void:
	## lsof output typically ends in \n; `split("\n", false)` drops the
	## empty trailing segment, but we also guard via `is_valid_int` so
	## any stray whitespace doesn't slip through as a fake pid.
	var pids := GodotAiPlugin._parse_lsof_pids("32696\n39824\n")
	assert_eq(pids.size(), 2)


func test_parse_lsof_pids_empty_input() -> void:
	var pids := GodotAiPlugin._parse_lsof_pids("")
	assert_eq(pids.size(), 0)


func test_parse_lsof_pids_ignores_non_numeric_lines() -> void:
	## Defensive against lsof emitting a warning header on stderr that
	## bleeds into stdout under rare conditions — the parser must drop
	## non-numeric lines rather than returning a bogus pid.
	var pids := GodotAiPlugin._parse_lsof_pids("lsof: WARNING\n32696\n")
	assert_eq(pids.size(), 1)
	assert_eq(pids[0], 32696)


func test_dev_server_detection_ignores_unbranded_port_listener() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [24680] as Array[int]
	plugin.port_in_use = true

	var detected := plugin.is_dev_server_running()
	plugin.free()

	assert_false(detected)


func test_dev_server_detection_accepts_branded_port_listener() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [24680] as Array[int]
	plugin.branded_pids = [24680] as Array[int]
	plugin.port_in_use = true

	var detected := plugin.is_dev_server_running()
	plugin.free()

	assert_true(detected)


## --- Live-status threading ------------------------------------------
##
## `_start_server` probes once at the top of the spawn body and threads
## that snapshot through `_recover_strong_port_occupant`,
## `_evaluate_*_port_occupant_proof`, and `_set_incompatible_server` so
## downstream decision points reuse the result instead of re-probing.
## Each probe costs a ~500 ms localhost HTTPClient poll loop, so a user-
## reported occupied-port trace measured five back-to-back probes
## dominating the dock's first-paint window.

func test_strong_proof_uses_provided_live_without_probing() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "2.1.0", "ws_port": 9500}
	var caller_live := {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT, caller_live)
	var probe_calls := plugin.probe_calls
	plugin.free()

	assert_eq(str(proof.get("proof", "")), "status_matches_record")
	assert_eq(probe_calls, 0, "passing live must skip the internal probe")


func test_strong_proof_probes_when_live_omitted() -> void:
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "2.1.0", "ws_port": 9500}
	plugin.live_status = {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_strong_port_occupant_proof(TEST_PORT)
	var probe_calls := plugin.probe_calls
	plugin.free()

	assert_eq(str(proof.get("proof", "")), "status_matches_record")
	assert_eq(probe_calls, 1, "omitting live must trigger the internal probe (preserves historical behavior)")


func test_recovery_proof_threads_live_through_strong_call() -> void:
	## `_evaluate_recovery_port_occupant_proof` first delegates to
	## `_evaluate_strong_port_occupant_proof` (one probe site) and on
	## empty proof probes again itself (second probe site). Passing
	## `live` must skip both.
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "", "ws_port": 0}
	var caller_live := {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var proof := plugin._evaluate_recovery_port_occupant_proof(TEST_PORT, caller_live)
	var probe_calls := plugin.probe_calls
	plugin.free()

	assert_eq(str(proof.get("proof", "")), "status_name", "fall-through path uses status name proof")
	assert_eq(probe_calls, 0, "threading live must skip both internal probes")


func test_recover_strong_port_occupant_threads_live_to_proof() -> void:
	## `_recover_strong_port_occupant` uses `pre_kill_live` for the
	## ownership-proof determination only. Anything after the kill must
	## re-probe at the caller; the function itself never reuses
	## `pre_kill_live` past `_kill_processes_and_windows_spawn_children`.
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 13579, "version": "2.1.0", "ws_port": 9500}
	plugin.alive_pids = [13579] as Array[int]
	plugin.port_in_use_sequence = [false] as Array[bool]
	var caller_live := {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	var ok := plugin._recover_strong_port_occupant(TEST_PORT, 0.1, caller_live)
	var probe_calls := plugin.probe_calls
	plugin.free()

	assert_true(ok, "managed-record proof should recover when the port frees")
	assert_eq(probe_calls, 0, "_recover_strong_port_occupant must thread live to its proof helper")


func test_set_incompatible_server_threads_live_to_recovery_proof() -> void:
	## `_set_incompatible_server` already accepts `live`; with the
	## refactor it forwards that snapshot to its internal recovery-proof
	## call so the proof helper doesn't re-probe.
	var plugin := _ProofPlugin.new()
	plugin.listener_pids = [13579] as Array[int]
	plugin.managed_record = {"pid": 0, "version": "", "ws_port": 0}
	var caller_live := {"name": "godot-ai", "version": "2.1.0", "ws_port": 9500, "status_code": 200}

	plugin._set_incompatible_server(caller_live, "2.3.1", TEST_PORT)
	var probe_calls := plugin.probe_calls
	plugin.free()

	assert_eq(probe_calls, 0, "_set_incompatible_server must reuse the caller's live for its proof determination")


func _seed_managed_record(pid: int, version: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(GodotAiPlugin.MANAGED_SERVER_PID_SETTING, pid)
	es.set_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING, version)


func _seed_pid_file(pid: int) -> void:
	var f := FileAccess.open(GodotAiPlugin.SERVER_PID_FILE, FileAccess.WRITE)
	assert_true(f != null, "test setup: must be able to write pid-file")
	f.store_string(str(pid))
	f.close()


func _read_record_version() -> String:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING):
		return ""
	return str(es.get_setting(GodotAiPlugin.MANAGED_SERVER_VERSION_SETTING))
