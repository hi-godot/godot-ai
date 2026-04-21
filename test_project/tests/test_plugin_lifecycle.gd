@tool
extends McpTestSuite

## Tests for the plugin's re-entrancy guard across disable/enable cycles.
## Regression coverage for the reload-plugin hang exposed by #159: once
## _stop_server became deterministic, the static _server_started_this_session
## flag persisted across disable/enable and made the re-enabled plugin's
## _start_server short-circuit with no server to adopt.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")

## Test port high enough to almost never collide with real services and
## distinct from the plugin's SERVER_HTTP_PORT so the stop-finalize tests
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
