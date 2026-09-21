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


class EndpointActivationPlugin extends Plugin:
	var resolved_ports: Array[int] = []
	var forced_ws := -1
	var configured_policies: Array[Dictionary] = []
	var normal_starts := 0

	func _resolve_ws_port(configured_port: int) -> int:
		resolved_ports.append(configured_port)
		return configured_port if forced_ws < 0 else forced_ws

	func _capture_lifecycle_plan() -> Dictionary:
		configured_policies.append(_endpoint_policy.duplicate(true))
		return _endpoint_policy.merged({"automatic_effects": false})

	func _release_normal_startup() -> void:
		normal_starts += 1


class HandoffPresentationPlugin extends Plugin:
	func _enter_tree() -> void:
		pass

	func _exit_tree() -> void:
		pass


class EndpointJobs extends FakeClientJobs:
	var lifecycle
	var activation_seen := {}

	func begin_post_update_repin(from_version: String, to_version: String, replace_owned_mismatches := false) -> Dictionary:
		activation_seen = {
			"context": McpClientConfigurator.capture_launch_context(),
			"plan": lifecycle._plan.duplicate(true),
		}
		return super.begin_post_update_repin(from_version, to_version, replace_owned_mismatches)


class EndpointDock:
	var states: Array[Dictionary] = []

	func present_update_state(state: Dictionary) -> void:
		states.append(state.duplicate(true))


var _endpoint_test_settings := {}
var _endpoint_test_context := {}


func suite_setup(_ctx: Dictionary) -> void:
	var settings := EditorInterface.get_editor_settings()
	for key in [McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS, McpSettings.SETTING_HTTP_PORT, McpClientConfigurator.SETTING_WS_PORT]:
		_endpoint_test_settings[key] = {"present": settings.has_setting(key), "value": settings.get_setting(key) if settings.has_setting(key) else null}
	_endpoint_test_context = McpClientConfigurator.capture_launch_context()


func suite_teardown() -> void:
	_restore_endpoint_test_settings()


func _restore_endpoint_test_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	for key in _endpoint_test_settings:
		var saved: Dictionary = _endpoint_test_settings[key]
		if bool(saved.present):
			settings.set_setting(key, saved.value)
		else:
			settings.erase(key)
	McpClientConfigurator.capture_launch_context(_endpoint_test_context)


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


func test_post_update_replaces_only_older_servers_of_our_major() -> void:
	## The arm existed for exactly the version the update replaced; a client
	## pinned further back leaves an even older server, which is just as much
	## ours to replace. A newer server or another major never is.
	var plugin := Plugin.new()
	var lifecycle := FakeLifecycleActions.new()
	plugin._lifecycle = lifecycle
	plugin._post_update_replaced_version = "4.0.2"
	plugin._post_update_replacements_left = 3
	var blocked := {
		"connection_blocked": true, "can_recover_incompatible": true,
		"episode_state": "BLOCKED", "conflict_port": 8000,
	}
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "4.0.2"}))
	assert_eq(lifecycle.recover_calls, 1, "the version the update replaced")
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "4.0.0"}))
	assert_eq(lifecycle.recover_calls, 2, "an older server of our major")
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "9.9.9"}))
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "3.2.5"}))
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": ""}))
	assert_eq(lifecycle.recover_calls, 2, "never a newer server, another major, or an unnamed one")
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "4.0.1"}))
	plugin._replace_server_left_by_update(blocked.merged({"conflict_version": "4.0.1"}))
	assert_eq(lifecycle.recover_calls, 3, "bounded by the replacement limit")
	plugin._lifecycle = null
	plugin.free()


func test_post_update_handoff_retry_is_amber_only_while_scheduled() -> void:
	var plugin := HandoffPresentationPlugin.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(plugin)
	var manager := _manual_lifecycle()
	plugin._lifecycle = manager
	plugin._normal_start_released = true
	plugin._post_update_replaced_version = "4.0.4"
	plugin._post_update_reprobes_left = 1
	var dock := Dock.new()
	dock._build_ui()
	plugin._dock = dock
	manager.snapshot_changed.connect(plugin._on_lifecycle_snapshot_changed)
	manager.start_server()
	assert_false(plugin._lifecycle_snapshot_for_dock().get("handoff_retry_pending", false))
	manager._episode["proof_pending_reason"] = "capability_pair"
	manager._block("launch_gone", "HTTP port already claimed")
	dock._update_status()
	assert_true(plugin._post_update_retry_episode > 0)
	assert_true(dock._lifecycle_snapshot.get("handoff_retry_pending", false))
	assert_eq(dock._status_label.text, "Recovering after update…")
	assert_eq(dock._status_icon.color, Dock.COLOR_AMBER)
	assert_true(manager.is_connection_blocked(), "presentation cannot authorize transport")
	assert_eq(manager.get_status_dict().episode_state, "BLOCKED")
	assert_eq(manager.authority_snapshot().transport, {})
	await tree.create_timer(1.1).timeout
	assert_eq(plugin._post_update_retry_episode, 0, "the actual timer consumed its episode")
	assert_eq(manager.get_status_dict().phase, "PROBE", "the timer really requested a fresh probe")
	manager._episode["proof_pending_reason"] = "capability_pair"
	manager._block("launch_gone", "HTTP port still claimed")
	dock._update_status()
	assert_false(dock._lifecycle_snapshot.get("handoff_retry_pending", false), "exhaustion is terminal")
	assert_eq(dock._status_icon.color, Color.RED)
	plugin._post_update_reprobes_left = 1
	manager._block_without_effect("listener_tools_missing", "Install lsof or iproute2")
	dock._update_status()
	assert_false(dock._lifecycle_snapshot.get("handoff_retry_pending", false), "a genuine failure stays red even with a retry scheduled")
	assert_eq(dock._status_icon.color, Color.RED)
	manager.stop_server()
	var stopped := manager.episode_snapshot()
	await tree.create_timer(1.1).timeout
	assert_eq(manager.episode_snapshot(), stopped, "Stop supersedes the pending retry")
	plugin._dock = null
	dock.free()
	plugin._lifecycle = null
	plugin.free()


func test_post_update_banner_depends_on_whether_bridges_can_follow() -> void:
	var plugin := Plugin.new()
	plugin._post_update_outcome = {"outcome": "success", "from_version": "4.0.3", "to_version": "4.1.0"}
	var label := plugin._post_update_complete_label()
	assert_true(label.begins_with("Refresh the Godot AI MCP connection and reload its configuration once"), label)
	plugin._post_update_outcome = {"outcome": "success", "from_version": "4.1.0", "to_version": "4.1.1"}
	label = plugin._post_update_complete_label()
	assert_true(label.begins_with("AI clients already using v4.1.0 can reconnect to v4.1.1 without restarting."), label)
	assert_true(label.contains("Refresh older MCP connections and reload their configuration"), label)
	assert_true(McpServerVersionCheck.attached_bridges_follow("4.1.0", "4.2.0"))
	assert_true(McpServerVersionCheck.attached_bridges_follow("4.1.0", "4.1.0"))
	assert_true(McpServerVersionCheck.attached_bridges_follow("4.0.4", "4.0.5"), "the tolerant bridge shipped in 4.0.4")
	assert_false(McpServerVersionCheck.attached_bridges_follow("4.1.0", "5.0.0"), "a major change needs new bridges")
	assert_false(McpServerVersionCheck.attached_bridges_follow("4.0.3", "4.1.0"), "an older bridge refuses the new server")
	assert_false(McpServerVersionCheck.attached_bridges_follow("3.2.5", "4.1.0"))
	assert_false(McpServerVersionCheck.attached_bridges_follow("", "4.1.0"))
	plugin._lifecycle = null
	plugin.free()


func test_normal_and_post_update_starts_share_the_status_probe_window() -> void:
	## A healthy delayed status must get the same three-second window during
	## ordinary startup as after an update, before any launch decision.
	var plugin := Plugin.new()
	for outcome in [{}, {"outcome": "success"}, {"outcome": "failed"}]:
		plugin._post_update_outcome = outcome
		var plan: Dictionary = plugin._capture_lifecycle_plan()
		plan["automatic_effects"] = false
		var manager := Lifecycle.new()
		manager.configure(plan)
		var effects: Array[Dictionary] = []
		manager.effect_requested.connect(func(_id: int, kind: String, payload: Dictionary):
			effects.append({"kind": kind, "payload": payload})
		)
		manager.start_server()
		assert_eq(effects.size(), 1)
		assert_eq(effects[0].kind, Lifecycle.PROBE)
		assert_eq(int(effects[0].payload.timeout_ms), 3000)
	plugin._lifecycle = null
	plugin.free()


class _DeferralRecordingPlugin extends Plugin:
	var finished := 0

	func _finish_post_update() -> void:
		finished += 1


func test_deferred_clients_do_not_block_startup_and_are_named_for_configure() -> void:
	var plugin := _DeferralRecordingPlugin.new()
	plugin._post_update_outcome = {
		"outcome": "success",
		"from_version": "3.2.4",
		"to_version": VERSION,
	}
	plugin._on_post_update_repin_completed({
		"ok": true,
		"configured_ids": ["codex"],
		"repinned_ids": ["codex"],
		"foreign_ids": [],
		"deferred": [
			{"id": "pi", "reason": "its godot-ai entry differs from what Configure wrote before the update"},
			{"id": "cursor", "reason": "its configuration could not be read: unexpected token"},
		],
	})
	assert_eq(plugin.finished, 1, "a deferred client must not turn success into a barrier failure")
	assert_eq(plugin._post_update_deferred.size(), 2)
	var label := plugin._post_update_complete_label()
	assert_true(label.begins_with("Refresh the Godot AI MCP connection and reload its configuration once"), label)
	## Each client carries its own reason: an unreadable file is not drift.
	assert_true(
		label.contains("Pi Agent (its godot-ai entry differs from what Configure wrote before the update)"),
		label
	)
	assert_true(label.contains("Cursor (its configuration could not be read: unexpected token)"), label)
	assert_true(label.contains("Configure"), label)
	var dock := Dock.new()
	dock._build_ui()
	plugin._dock = dock
	plugin._present_post_update_complete()
	assert_eq(dock._update_status_label.text, "Installed — client setup needed")
	assert_eq(dock._update_label.text, label, "the client-specific failure remains visible")
	assert_true(dock._update_label.has_theme_color_override("font_color"))
	assert_eq(dock._update_label.get_theme_color("font_color"), Dock._UPDATE_LABEL_COLOR,
		"deferred migrations must not display green success")
	plugin._post_update_deferred = []
	assert_false(plugin._post_update_complete_label().contains("Not migrated"))
	plugin._present_post_update_complete()
	assert_eq(dock._update_status_label.text, "Godot AI installed",
		"installation alone does not claim the server or clients are ready")
	plugin._dock = null
	dock.free()
	plugin._lifecycle = null
	plugin.free()


func test_major_endpoint_activation_publishes_one_pair_before_repin() -> void:
	var settings := EditorInterface.get_editor_settings()
	var pair := {"http_port": 28111, "ws_port": 28112}
	settings.set_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS, pair)
	var plugin := EndpointActivationPlugin.new()
	var jobs := EndpointJobs.new()
	jobs.lifecycle = plugin._lifecycle
	var connection := FakeConnection.new()
	plugin._client_jobs = jobs
	plugin._connection = connection
	plugin._post_update_outcome = {"outcome": "success", "from_version": "3.2.5", "to_version": "4.0.5"}
	plugin._activate_startup_endpoints()
	assert_eq(plugin.resolved_ports, [28112] as Array[int])
	assert_eq(plugin.configured_policies.size(), 1)
	assert_eq(plugin._lifecycle._plan.http_port, 28111)
	assert_eq(plugin._lifecycle._plan.ws_port, 28112)
	assert_eq(plugin._lifecycle._plan.capability_path, McpTransportCapability.path_for_http_port(28111))
	assert_eq(connection.ws_port, 28112)
	var context := McpClientConfigurator.capture_launch_context()
	assert_eq(context.http_port, 28111)
	assert_eq(context.ws_port, 28112)
	assert_eq(jobs.repin_versions.size(), 1)
	assert_eq(jobs.activation_seen.context.http_port, 28111, "repin sees only the published new endpoint")
	assert_eq(jobs.activation_seen.context.ws_port, 28112)
	assert_eq(jobs.activation_seen.plan.capability_path, McpTransportCapability.path_for_http_port(28111), "lifecycle is frozen before the first migration worker")
	assert_eq(jobs.repin_versions[0].from, "3.2.5")
	assert_eq(settings.get_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS), pair)
	assert_false(plugin._normal_start_released)
	assert_eq(plugin.normal_starts, 0)
	plugin._connection = null
	plugin._client_jobs = null
	connection.free()
	jobs.free()
	plugin._lifecycle = null
	plugin.free()
	_restore_endpoint_test_settings()


func test_invalid_endpoint_pair_blocks_before_effects_and_retry_precedes_repin() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS, {})
	var previous := McpClientConfigurator.capture_launch_context()
	var plugin := EndpointActivationPlugin.new()
	var jobs := FakeClientJobs.new()
	var dock := EndpointDock.new()
	plugin._client_jobs = jobs
	plugin._dock = dock
	plugin._post_update_outcome = {"outcome": "success", "from_version": "3.2.5", "to_version": "4.0.5"}
	plugin._activate_startup_endpoints()
	assert_true(plugin.resolved_ports.is_empty(), "malformed override is rejected before port reservation")
	assert_true(plugin.configured_policies.is_empty())
	assert_true(plugin._lifecycle._plan.is_empty(), "retry must not encounter an already frozen wrong plan")
	assert_true(jobs.repin_versions.is_empty())
	assert_eq(McpClientConfigurator.capture_launch_context(), previous)
	assert_eq(plugin._lifecycle.episode_snapshot().reason, "endpoint_setup_failed")
	assert_eq(dock.states.back().post_update_action, "retry_endpoints")
	assert_eq(dock.states.back().button_text, "Retry endpoint setup")
	assert_contains(str(dock.states.back().label_text), McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS)
	assert_false(plugin._update_barrier_blocked, "a settings error does not disable the plugin")
	plugin._on_dock_post_update_action_requested("retry")
	assert_true(jobs.repin_versions.is_empty(), "client migration retry cannot bypass endpoint selection")
	settings.set_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS, {"http_port": 28113, "ws_port": 28114})
	plugin._on_dock_post_update_action_requested("retry_endpoints")
	assert_eq(plugin._lifecycle._plan.http_port, 28113)
	assert_eq(plugin._lifecycle._plan.ws_port, 28114)
	assert_eq(jobs.repin_versions.size(), 1)
	assert_eq(plugin._post_update_action, "")
	assert_eq(plugin.normal_starts, 0)
	plugin._dock = null
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()
	_restore_endpoint_test_settings()


func test_persisted_endpoint_pair_cannot_silently_change_during_ws_resolution() -> void:
	var settings := EditorInterface.get_editor_settings()
	var pair := {"http_port": 28115, "ws_port": 28116}
	settings.set_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS, pair)
	var plugin := EndpointActivationPlugin.new()
	plugin.forced_ws = 28117
	plugin._activate_startup_endpoints()
	assert_eq(plugin.resolved_ports, [28116] as Array[int])
	assert_true(plugin.configured_policies.is_empty())
	assert_true(plugin._lifecycle._plan.is_empty())
	assert_eq(plugin._lifecycle.episode_snapshot().reason, "endpoint_setup_failed")
	assert_eq(plugin.normal_starts, 0)
	assert_eq(settings.get_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS), pair)
	plugin._lifecycle = null
	plugin.free()
	_restore_endpoint_test_settings()


func test_non_major_activation_without_override_keeps_legacy_custom_ports() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.erase(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS)
	settings.set_setting(McpSettings.SETTING_HTTP_PORT, 28118)
	settings.set_setting(McpClientConfigurator.SETTING_WS_PORT, 28119)
	var plugin := EndpointActivationPlugin.new()
	var jobs := FakeClientJobs.new()
	plugin._client_jobs = jobs
	plugin._post_update_outcome = {"outcome": "success", "from_version": "4.0.4", "to_version": "4.0.5"}
	plugin._activate_startup_endpoints()
	assert_false(settings.has_setting(McpClientConfigurator.SETTING_V4_ENDPOINT_PORTS))
	assert_eq(plugin._lifecycle._plan.http_port, 28118)
	assert_eq(plugin._lifecycle._plan.ws_port, 28119)
	assert_eq(jobs.repin_versions.size(), 1)
	assert_eq(jobs.repin_versions[0].from, "4.0.4")
	plugin._client_jobs = null
	jobs.free()
	plugin._lifecycle = null
	plugin.free()
	_restore_endpoint_test_settings()
