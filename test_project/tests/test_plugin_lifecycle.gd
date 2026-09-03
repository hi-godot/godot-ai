@tool
extends McpTestSuite

const Plugin := preload("res://addons/godot_ai/plugin.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Authority := preload("res://addons/godot_ai/utils/server_authority.gd")

const VERSION := "4.0.0"
const HTTP := "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
const WS := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const INSTANCE := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


class FakeConnection:
	extends Node
	var ws_port := 0
	var auth_token := ""
	var connect_blocked := true
	var connect_block_reason := ""
	var server_version := ""
	var revoked_reasons: Array[String] = []
	var authorize_calls := 0

	func authorize_transport(p_ws_port: int, p_auth_token: String) -> void:
		authorize_calls += 1
		ws_port = p_ws_port
		auth_token = p_auth_token
		connect_blocked = false
		connect_block_reason = ""
		server_version = ""

	func revoke_transport(reason: String) -> void:
		revoked_reasons.append(reason)
		auth_token = ""
		connect_blocked = true
		connect_block_reason = reason


class FakeClientJobs:
	extends Node
	var blocked := false
	var repin_versions: Array[Dictionary] = []
	var refresh_requests := 0

	func set_client_health_blocked(value: bool) -> void:
		blocked = value

	func begin_post_update_repin(
		from_version: String, to_version: String, replace_owned_mismatches := false
	) -> Dictionary:
		repin_versions.append({
			"from": from_version,
			"to": to_version,
			"replace_owned_mismatches": replace_owned_mismatches,
		})
		return {"ok": true}

	func request_status_refresh(_ids: Array[String], _force := false) -> bool:
		refresh_requests += 1
		return true


class FakeTelemetry:
	var updates: Array[Dictionary] = []

	func record_self_update(status: String, from_version: String, to_version: String, error: String) -> void:
		updates.append({
			"status": status,
			"from": from_version,
			"to": to_version,
			"error": error,
		})


class FakeLifecycleActions:
	extends RefCounted
	var start_calls := 0
	var restart_calls := 0
	var recover_calls := 0
	var stop_calls := 0

	func start_server() -> void:
		start_calls += 1

	func force_restart_server() -> bool:
		restart_calls += 1
		return true

	func request_replacement() -> bool:
		recover_calls += 1
		return true

	func has_managed_server() -> bool:
		return true

	func stop_server(_force_inline := false) -> void:
		stop_calls += 1

	func can_restart_managed_server() -> bool:
		return true

	func can_recover_incompatible_server() -> bool:
		return true


func suite_name() -> String:
	return "plugin_lifecycle"


func _manual_lifecycle() -> McpServerLifecycleManager:
	var manager := Lifecycle.new()
	manager.configure({
		"http_port": 8000,
		"ws_port": 9500,
		"expected_version": VERSION,
		"automatic_effects": false,
		"defer_effects": false,
	})
	return manager


func _ready_adopted(manager: McpServerLifecycleManager) -> void:
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "compatible",
		"version": VERSION,
		"transport": Authority.TransportAuthority.new(
			8000, 9500, INSTANCE, HTTP, WS
		),
	})


func test_plugin_construction_is_inert_and_has_no_host_cycle() -> void:
	var plugin := Plugin.new()
	assert_true(plugin._lifecycle is McpServerLifecycleManager)
	assert_eq(plugin._lifecycle.episode_snapshot().state, Lifecycle.DORMANT)
	var properties: Array[String] = []
	for property in plugin._lifecycle.get_property_list():
		properties.append(str(property.name))
	assert_false(properties.has("_host"))
	plugin._lifecycle = null
	plugin.free()


func test_update_busy_probe_does_not_stop_the_live_composition() -> void:
	var plugin := Plugin.new()
	var lifecycle := _manual_lifecycle()
	_ready_adopted(lifecycle)
	plugin._lifecycle = lifecycle
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	plugin._dispatcher = dispatcher
	dispatcher._pending_deferred["still-running"] = {"command": "run_project"}
	var before := lifecycle.episode_snapshot()
	var result := plugin.prepare_for_update_reload()
	assert_false(result.ok)
	assert_false(result.get("reload_required", false))
	assert_eq(lifecycle.episode_snapshot(), before)
	assert_true(dispatcher._pending_deferred.has("still-running"))
	dispatcher.release_after_teardown()
	plugin._dispatcher = null
	plugin._lifecycle = null
	plugin.free()


func test_root_applies_transport_values_without_retaining_connection_in_manager() -> void:
	var plugin := Plugin.new()
	var connection := FakeConnection.new()
	plugin._endpoint_policy = {"http_port": 8000, "ws_port": 9501}
	plugin._connection = connection
	plugin._on_lifecycle_transport_ready(9555, WS)
	assert_eq(connection.ws_port, 9555)
	assert_eq(connection.auth_token, WS)
	assert_false(connection.connect_blocked)
	assert_eq(connection.authorize_calls, 1)
	assert_eq(plugin.get_resolved_ws_port(), 9555)
	assert_eq(plugin._endpoint_policy.ws_port, 9555)
	assert_eq(McpClientConfigurator.capture_launch_context().ws_port, 9555,
		"the proven lifecycle transport must republish the one client launch policy")
	assert_false(plugin._lifecycle.authority_snapshot().has("connection"))
	plugin._connection = null
	connection.free()
	plugin._lifecycle = null
	plugin.free()


func test_root_blocks_connection_from_copied_lifecycle_result() -> void:
	var plugin := Plugin.new()
	var connection := FakeConnection.new()
	plugin._connection = connection
	plugin._on_lifecycle_transport_cleared("endpoint lost")
	assert_true(connection.connect_blocked)
	assert_eq(connection.connect_block_reason, "endpoint lost")
	assert_eq(connection.auth_token, "")
	assert_eq(connection.revoked_reasons, ["endpoint lost"] as Array[String])
	plugin._connection = null
	connection.free()
	plugin._lifecycle = null
	plugin.free()


func test_snapshot_route_updates_client_health_from_value_only() -> void:
	var plugin := Plugin.new()
	var jobs := FakeClientJobs.new()
	plugin._client_jobs = jobs
	plugin._on_lifecycle_snapshot_changed({
		"state": McpServerState.INCOMPATIBLE,
		"connection_blocked": true,
		"message": "version mismatch",
	})
	assert_true(jobs.blocked)
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()


func test_successful_update_begins_repin_before_normal_start_or_telemetry() -> void:
	var plugin := Plugin.new()
	var jobs := FakeClientJobs.new()
	plugin._client_jobs = jobs
	plugin._post_update_outcome = {
		"outcome": "success",
		"from_version": "3.2.4",
		"to_version": VERSION,
	}
	plugin._begin_startup_release()
	assert_eq(jobs.repin_versions, [{
		"from": "3.2.4",
		"to": VERSION,
		"replace_owned_mismatches": false,
	}])
	assert_false(plugin._normal_start_released)
	assert_false(plugin._post_update_outcome.is_empty(), "success is not declared before restart")
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()


func test_pending_m6_denies_every_start_authority_but_keeps_stop_available() -> void:
	var plugin := Plugin.new()
	var lifecycle := FakeLifecycleActions.new()
	plugin._lifecycle = lifecycle
	plugin._normal_start_released = false

	plugin._on_dock_dev_server_action_requested(Dock.DevServerAction.START_OR_RESTART)
	plugin._on_dock_lifecycle_action_requested(Dock.LifecycleAction.RESTART_SERVER)
	plugin._on_dock_lifecycle_action_requested(Dock.LifecycleAction.RECOVER_INCOMPATIBLE)
	assert_false(plugin.restart_or_start_managed_server())
	assert_false(plugin.force_restart_server())
	assert_false(plugin.recover_incompatible_server())
	assert_false(plugin.can_restart_managed_server())
	assert_false(plugin.can_recover_incompatible_server())
	assert_eq(lifecycle.start_calls, 0)
	assert_eq(lifecycle.restart_calls, 0)
	assert_eq(lifecycle.recover_calls, 0)

	plugin._on_dock_dev_server_action_requested(Dock.DevServerAction.STOP)
	assert_eq(lifecycle.stop_calls, 1,
		"Pending migration blocks process creation/replacement, not safe shutdown")
	plugin._lifecycle = null
	plugin.free()


func test_manual_major_migration_allows_replacing_owned_mismatches() -> void:
	var plugin := Plugin.new()
	var jobs := FakeClientJobs.new()
	plugin._client_jobs = jobs
	plugin._post_update_outcome = {
		"outcome": "success",
		"from_version": "3.2.4",
		"to_version": VERSION,
		"manual_migration": true,
	}
	plugin._begin_startup_release()
	assert_eq(jobs.repin_versions, [{
		"from": "3.2.4",
		"to": VERSION,
		"replace_owned_mismatches": true,
	}])
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()


func test_transactional_major_bridge_replaces_mismatches_without_manual_completion() -> void:
	var plugin := Plugin.new()
	var jobs := FakeClientJobs.new()
	plugin._client_jobs = jobs
	plugin._post_update_outcome = {
		"outcome": "success",
		"from_version": "3.2.4",
		"to_version": VERSION,
		"replace_owned_mismatches": true,
	}
	plugin._begin_startup_release()
	assert_eq(jobs.repin_versions, [{
		"from": "3.2.4",
		"to": VERSION,
		"replace_owned_mismatches": true,
	}])
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()


func test_rollback_telemetry_uses_the_supported_clean_failure_vocabulary() -> void:
	var plugin := Plugin.new()
	var telemetry := FakeTelemetry.new()
	plugin._telemetry = telemetry
	plugin._post_update_outcome = {
		"outcome": "rolled_back",
		"from_version": "4.0.0",
		"to_version": "4.0.1",
	}
	plugin._fan_post_update_outcome()
	assert_eq(telemetry.updates[0].status, "failed_clean")
	assert_true(plugin._post_update_outcome.is_empty())
	plugin._telemetry = null
	plugin._lifecycle = null
	plugin.free()


func test_manual_migration_does_not_masquerade_as_hot_update_telemetry() -> void:
	var plugin := Plugin.new()
	var telemetry := FakeTelemetry.new()
	plugin._telemetry = telemetry
	plugin._post_update_outcome = {
		"outcome": "success",
		"from_version": "3.2.4",
		"to_version": VERSION,
		"manual_migration": true,
	}
	plugin._fan_post_update_outcome()
	assert_true(telemetry.updates.is_empty())
	plugin._telemetry = null
	plugin._lifecycle = null
	plugin.free()


func test_authenticated_connection_reports_version_to_episode_owner() -> void:
	var plugin := Plugin.new()
	var manager := _manual_lifecycle()
	_ready_adopted(manager)
	var connection := FakeConnection.new()
	connection.server_version = VERSION
	plugin._lifecycle = manager
	plugin._connection = connection
	plugin._on_connection_state_changed(true)
	assert_eq(manager.get_status_dict().actual_version, VERSION)
	plugin._connection = null
	plugin._lifecycle = null
	connection.free()
	plugin.free()


func test_authenticated_disconnect_becomes_blocked_episode() -> void:
	var plugin := Plugin.new()
	var manager := _manual_lifecycle()
	_ready_adopted(manager)
	var connection := FakeConnection.new()
	plugin._lifecycle = manager
	plugin._connection = connection
	plugin._on_connection_state_changed(false)
	assert_eq(manager.episode_snapshot().state, Lifecycle.BLOCKED)
	assert_eq(manager.episode_snapshot().reason, "endpoint_lost")
	plugin._connection = null
	plugin._lifecycle = null
	connection.free()
	plugin.free()


func test_status_projection_keeps_instance_binding_and_drops_unknowns() -> void:
	var projected := Lifecycle.project_status_payload({
		"name": "godot-ai",
		"server_version": VERSION,
		"ws_port": 9500,
		"instance_id": INSTANCE,
		"active_lease_count": 1.0,
		"not_public": "drop",
	})
	assert_eq(projected.instance_id, INSTANCE)
	assert_eq(projected.active_lease_count, 1)
	assert_false(projected.has("not_public"))


func test_capability_pair_is_distinct_for_dev_and_managed_spawns() -> void:
	var pair := Lifecycle.generate_capability_pair()
	assert_eq(str(pair.http).length(), 64)
	assert_eq(str(pair.websocket).length(), 64)
	assert_ne(pair.http, pair.websocket)


func test_update_actor_command_value_has_a_real_wall_clock_deadline() -> void:
	## Exercise the exact helper used by both the interactive startup worker and
	## the synchronous export/import lease. A wedged actor must be killed rather
	## than turning either path into an unbounded wait.
	if OS.get_name() == "Windows":
		skip("Windows lacks a standalone sleep executable; covered by the Unix path")
		return
	var sleep_exe := "/bin/sleep"
	if not FileAccess.file_exists(sleep_exe):
		sleep_exe = "/usr/bin/sleep"
	if not FileAccess.file_exists(sleep_exe):
		skip("No /bin/sleep or /usr/bin/sleep on this host")
		return
	var command: Array[String] = [sleep_exe]
	var started_msec := Time.get_ticks_msec()
	var result := Plugin._execute_update_command_value(
		command,
		["5"] as Array[String],
		VERSION,
		200,
		Callable(),
	)
	var elapsed_msec := Time.get_ticks_msec() - started_msec
	assert_false(bool(result.get("ok", true)))
	assert_eq(
		str(result.get("error", "")),
		"transaction actor exceeded its deadline and could not be stopped safely",
	)
	assert_true(bool(result.get("termination_unproven", false)),
		"POSIX actor termination cannot prove that no descendant retained authority")
	assert_true(
		elapsed_msec < 3000,
		"Actor timeout must return near its deadline, not after sleep exits (%dms)" % elapsed_msec,
	)


func test_update_actor_refusal_never_reflects_arbitrary_resolver_stderr() -> void:
	var secret := "https://user:secret@example.invalid/simple"
	var generic := Plugin._update_actor_refusal_message(
		"error: failed to resolve from %s" % secret
	)
	assert_eq(generic, "transaction actor or exact-package resolver refused")
	assert_false(generic.contains("secret"))
	assert_eq(
		Plugin._update_actor_refusal_message(
			"uvx preface\nupdate transaction refused: activation lock already exists\n"
		),
		"update transaction refused: activation lock already exists",
	)
	assert_eq(
		Plugin._update_actor_refusal_message(
			"update transaction refused: bad\u0001control"
		),
		"transaction actor or exact-package resolver refused",
	)
