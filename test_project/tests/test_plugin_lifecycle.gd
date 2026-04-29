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


# ----- spawn state machine -----
#
# `get_server_status()` is the dock's single source of truth for what
# went wrong during startup. These tests pin down the contract: default
# state OK, `_set_spawn_state` records the first specific diagnosis and
# refuses later overwrites (so a PORT_EXCLUDED proactive hit can't be
# clobbered by a follow-up CRASHED signal from the watch loop).


func test_spawn_state_defaults_to_ok() -> void:
	var plugin := GodotAiPlugin.new()
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(status.get("state", ""), McpSpawnState.OK, "fresh plugin must report OK")


func test_set_spawn_state_records_first_diagnosis() -> void:
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpSpawnState.FOREIGN_PORT)
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(status.get("state", ""), McpSpawnState.FOREIGN_PORT)


func test_set_spawn_state_does_not_overwrite_specific_diagnosis() -> void:
	## The watch loop's CRASHED path fires late (up to SPAWN_GRACE_MS after
	## spawn). If a more specific diagnosis already landed earlier — e.g.
	## PORT_EXCLUDED from the proactive `netsh` check — the CRASHED code
	## would overwrite it with a less actionable state. `_set_spawn_state`
	## is first-writer-wins so the dock keeps showing the pointed message.
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpSpawnState.PORT_EXCLUDED)
	plugin._set_spawn_state(McpSpawnState.CRASHED)
	var status := plugin.get_server_status()
	plugin.free()
	assert_eq(status.get("state", ""), McpSpawnState.PORT_EXCLUDED, "first diagnosis must win")


func test_get_server_status_shape_is_stable() -> void:
	## Dock reads these keys; missing any is a render bug. Locked so a
	## future refactor of the plugin-side dict can't silently drop one.
	var plugin := GodotAiPlugin.new()
	var status := plugin.get_server_status()
	plugin.free()
	assert_has_key(status, "state")
	assert_has_key(status, "exit_ms")
	assert_has_key(status, "actual_version")
	assert_has_key(status, "expected_version")
	assert_has_key(status, "message")
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
	)
	assert_contains(message, "Port 8000 is occupied by godot-ai server v1.2.10")
	assert_contains(message, "plugin expects v2.2.0")
	assert_contains(message, "change both HTTP and WS ports")


func test_incompatible_server_message_names_ws_port_mismatch() -> void:
	var message := GodotAiPlugin._incompatible_server_message(
		{"name": "godot-ai", "version": "2.2.0", "ws_port": 9600},
		"2.2.0",
		8000,
	)
	assert_contains(message, "using WS port 9600")
	assert_contains(message, "with WS port %d" % McpClientConfigurator.ws_port())
	assert_contains(message, "change both HTTP and WS ports")


func test_incompatible_transition_refreshes_dock_client_statuses() -> void:
	var plugin := GodotAiPlugin.new()
	var dock := _RefreshDock.new()
	plugin._dock = dock
	plugin._set_incompatible_server({"version": "1.2.10"}, "2.2.0", 8000)
	var calls := dock.refresh_calls
	dock.free()
	plugin.free()

	assert_eq(calls, 1, "late incompatible transition must resweep dock client status")


func test_connection_established_waits_for_version_before_clearing_foreign_port() -> void:
	## A WebSocket opening is not enough proof anymore: old pre-rollup
	## servers accept the plugin session while still exposing an incompatible
	## HTTP/MCP tool surface. FOREIGN_PORT only clears after the live server
	## version is verified.
	_seed_managed_record(99999, "other-version")
	var plugin := GodotAiPlugin.new()
	plugin._set_spawn_state(McpSpawnState.FOREIGN_PORT)
	assert_eq(
		plugin.get_server_status().get("state", ""),
		McpSpawnState.FOREIGN_PORT,
		"precondition: FOREIGN_PORT must be set before adoption-confirmation fires"
	)

	plugin._on_connection_established()
	var state: String = plugin.get_server_status().get("state", "")
	var awaiting := plugin._awaiting_server_version
	plugin.free()

	assert_eq(
		state,
		McpSpawnState.FOREIGN_PORT,
		"opening the WebSocket must not clear FOREIGN_PORT before version verification"
	)
	assert_true(awaiting, "connection establishment must arm the server-version check")


func test_verified_matching_server_clears_foreign_port() -> void:
	var plugin := GodotAiPlugin.new()
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	plugin._server_expected_version = plugin_ver
	plugin._set_spawn_state(McpSpawnState.FOREIGN_PORT)
	plugin._on_server_version_verified(plugin_ver)
	var status := plugin.get_server_status()
	plugin.free()

	assert_eq(status.get("state", ""), McpSpawnState.OK)
	assert_eq(status.get("actual_version", ""), plugin_ver)
	assert_false(bool(status.get("connection_blocked", true)))


func test_verified_old_server_becomes_incompatible_and_blocks_connection() -> void:
	var plugin := GodotAiPlugin.new()
	plugin._server_expected_version = "2.2.0"
	plugin._on_server_version_verified("1.2.10")
	var status := plugin.get_server_status()
	plugin.free()

	assert_eq(status.get("state", ""), McpSpawnState.INCOMPATIBLE_SERVER)
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
	plugin._set_spawn_state(McpSpawnState.CRASHED)
	plugin._on_connection_established()
	var state: String = plugin.get_server_status().get("state", "")
	plugin.free()
	assert_eq(
		state,
		McpSpawnState.CRASHED,
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
	assert_eq(plugin._adoption_watch_deadline_ms, 0, "precondition: deadline disarmed")
	var before_ms := Time.get_ticks_msec()
	plugin._watch_for_adoption_confirmation()
	var deadline := plugin._adoption_watch_deadline_ms
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
	plugin._server_expected_version = McpClientConfigurator.get_plugin_version()
	plugin._set_spawn_state(McpSpawnState.FOREIGN_PORT)
	plugin._watch_for_adoption_confirmation()
	plugin._arm_server_version_check()
	assert_true(plugin._adoption_watch_deadline_ms > 0, "precondition: watcher armed")

	conn._connected = true  # simulate WebSocket STATE_OPEN transition
	conn.server_version = plugin._server_expected_version
	plugin._process(0.0)
	var state: String = plugin.get_server_status().get("state", "")
	var deadline := plugin._adoption_watch_deadline_ms
	conn.free()
	plugin.free()

	assert_eq(state, McpSpawnState.OK, "_process must clear FOREIGN_PORT after version match")
	assert_true(deadline > 0, "adoption deadline is independent of version verification")


func test_process_self_disarms_after_deadline_without_connect() -> void:
	## If the foreign occupant never opens a WebSocket (e.g. it's a
	## genuine non-MCP process), the watcher must give up after
	## SPAWN_GRACE_MS so `_process` stops running every frame. The deadline
	## stays zero afterwards, serving as the "disarmed" sentinel.
	var plugin := GodotAiPlugin.new()
	var conn := McpConnection.new()
	plugin._connection = conn
	plugin._set_spawn_state(McpSpawnState.FOREIGN_PORT)
	plugin._adoption_watch_deadline_ms = Time.get_ticks_msec() - 1  # already expired
	plugin.set_process(true)
	plugin._process(0.0)
	var state: String = plugin.get_server_status().get("state", "")
	var deadline := plugin._adoption_watch_deadline_ms
	conn.free()
	plugin.free()

	assert_eq(state, McpSpawnState.FOREIGN_PORT, "deadline expiry must leave FOREIGN_PORT set")
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
