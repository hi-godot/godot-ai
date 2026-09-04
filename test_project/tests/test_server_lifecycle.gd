@tool
extends McpTestSuite

const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Authority := preload("res://addons/godot_ai/utils/server_authority.gd")

const VERSION := "4.0.0"
const HTTP := "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
const WS := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const INSTANCE := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


func suite_name() -> String:
	return "server_lifecycle"


func _manager(overrides: Dictionary = {}) -> McpServerLifecycleManager:
	var manager := Lifecycle.new()
	var plan := {
		"http_port": 8000,
		"ws_port": 9500,
		"expected_version": VERSION,
		"automatic_effects": false,
		"defer_effects": false,
		"keep_alive": false,
	}
	plan.merge(overrides, true)
	manager.configure(plan)
	return manager


func _transport(instance_id := INSTANCE):
	return Authority.TransportAuthority.new(8000, 9500, instance_id, HTTP, WS)


func _complete_adoption(manager: McpServerLifecycleManager) -> void:
	manager.start_server()
	var episode := manager.episode_snapshot()
	assert_true(manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "compatible",
		"version": VERSION,
		"transport": _transport(),
	}))


func _complete_owned_start(manager: McpServerLifecycleManager) -> void:
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "free", "baseline_instance_id": "",
	})
	episode = manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.LAUNCH, {
		"ok": true,
		"pid": 4242,
		"fingerprint": "process-start-fingerprint",
		"http_capability": HTTP,
		"ws_capability": WS,
		"baseline_instance_id": "",
	})
	episode = manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROVE, {
		"ok": true,
		"pid": 4242,
		"fingerprint": "process-start-fingerprint",
		"version": VERSION,
		"transport": _transport(),
	})


func _block_replaceable(manager: McpServerLifecycleManager) -> void:
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "blocked",
		"reason": "incompatible",
		"message": "stale server",
		"target": {
			"instance_id": INSTANCE,
			"version": "4.0.1",
			"port": 8000,
			"replaceable": true,
		},
	})


func test_construction_and_configuration_are_inert() -> void:
	var manager := Lifecycle.new()
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	manager.configure({"automatic_effects": false, "keep_alive": false})
	manager.configure({"automatic_effects": true, "keep_alive": true})
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_eq(manager.episode_snapshot().effect, "")
	assert_false(manager.get_status_dict().keep_alive)


func test_compatible_endpoint_is_adopted_without_process_grant() -> void:
	var manager := _manager()
	_complete_adoption(manager)
	var snapshot := manager.get_status_dict()
	assert_eq(snapshot.episode_state, Lifecycle.READY)
	assert_eq(snapshot.ready_kind, "adopted")
	assert_false(manager.has_managed_server())
	assert_eq(manager.get_server_pid(), -1)


func test_owned_launch_prove_and_stop_use_one_exact_grant() -> void:
	var manager := _manager()
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	_complete_owned_start(manager)
	assert_eq(manager.get_status_dict().ready_kind, "owned")
	assert_true(manager.has_managed_server())
	assert_eq(manager.get_server_pid(), 4242)
	manager.stop_server()
	var stop_effect: Dictionary = effects[effects.size() - 1]
	assert_eq(stop_effect.kind, Lifecycle.STOP)
	var grant = stop_effect.payload.grant
	assert_true(grant.matches(4242, "process-start-fingerprint"))
	assert_false(grant.matches(4242, "different-process"))
	assert_true(manager.complete_effect(stop_effect.id, Lifecycle.STOP, {"ok": true}))
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_false(manager.has_managed_server())


func test_episode_snapshot_never_exposes_transport_capabilities() -> void:
	var manager := _manager()
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free"})
	episode = manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.LAUNCH, {
		"ok": true, "pid": 4242, "fingerprint": "fingerprint",
		"http_capability": HTTP, "ws_capability": WS,
	})
	var launch: Dictionary = manager.episode_snapshot().launch
	assert_false(launch.has("http_capability"))
	assert_false(launch.has("ws_capability"))


func test_authenticated_endpoint_loss_blocks_without_recovery_loop() -> void:
	var manager := _manager()
	_complete_adoption(manager)
	manager.transport_lost("endpoint vanished")
	var snapshot := manager.get_status_dict()
	assert_eq(snapshot.episode_state, Lifecycle.BLOCKED)
	assert_eq(manager.episode_snapshot().reason, "endpoint_lost")
	assert_true(snapshot.connection_blocked)
	assert_false(snapshot.can_recover_incompatible)


func test_owned_endpoint_loss_stops_exact_grant_before_new_start() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	manager.transport_lost("endpoint vanished")
	manager.start_server()
	var snapshot := manager.episode_snapshot()
	assert_eq(snapshot.state, Lifecycle.STOPPING)
	assert_eq(snapshot.after_stop, "start")


func test_dead_owned_child_retires_grant_and_restart_continues() -> void:
	var manager := _manager()
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	_complete_owned_start(manager)
	manager.transport_lost("child exited")
	manager.start_server()
	var stop: Dictionary = effects[effects.size() - 1]
	assert_eq(
		Lifecycle._owned_process_disposition(stop.payload.grant, false, ""),
		"gone",
	)
	assert_true(manager.complete_effect(stop.id, Lifecycle.STOP, {"ok": true, "already_gone": true}))
	assert_eq(manager.episode_snapshot().state, Lifecycle.STARTING)
	assert_eq(manager.episode_snapshot().phase, Lifecycle.PROBE)
	assert_false(manager.has_managed_server())


func test_reused_pid_retires_grant_without_authorizing_a_kill() -> void:
	var grant = Authority.OwnedProcessGrant.new(4242, "original-start", 1)
	assert_eq(
		Lifecycle._owned_process_disposition(grant, true, "different-process-start"),
		"replaced",
	)
	assert_eq(Lifecycle._owned_process_disposition(grant, true, ""), "unproven")
	assert_eq(Lifecycle._owned_process_disposition(grant, true, "original-start"), "owned")


func test_result_from_stopped_episode_is_ignored() -> void:
	var manager := _manager()
	manager.start_server()
	var stale := manager.episode_snapshot()
	manager.stop_server()
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_false(manager.complete_effect(stale.id, Lifecycle.PROBE, {
		"outcome": "compatible", "version": VERSION, "transport": _transport(),
	}))
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)


func test_replacement_authorization_expires_and_requires_fresh_action() -> void:
	var manager := _manager()
	_block_replaceable(manager)
	assert_true(manager.authorize_replacement(100, 10))
	assert_false(manager.replace_authorized(111))
	assert_false(manager.replace_authorized(111))
	assert_true(manager.authorize_replacement(200, 10))
	assert_true(manager.replace_authorized(200))
	assert_false(manager.replace_authorized(200))
	assert_eq(manager.episode_snapshot().state, Lifecycle.RECOVERING)


func test_status_dict_names_the_conflicting_server_version() -> void:
	var manager := _manager()
	_block_replaceable(manager)
	var target: Dictionary = manager.episode_snapshot().blocked_target
	var status := manager.get_status_dict()
	assert_true(bool(status.can_recover_incompatible))
	assert_eq(str(status.conflict_version), str(target.version), "the plugin's post-update arm compares this")
	assert_false(str(status.conflict_version).is_empty())
	assert_eq(int(status.conflict_port), int(target.port))
	manager.stop_server()
	assert_eq(str(manager.get_status_dict().conflict_version), "", "cleared with the blocked target")


func test_generic_restart_never_escalates_to_unowned_replacement() -> void:
	var manager := _manager()
	var effects: Array[String] = []
	manager.effect_requested.connect(func(_id: int, kind: String, _payload: Dictionary):
		effects.append(kind)
	)
	_block_replaceable(manager)
	var before := manager.episode_snapshot()
	assert_false(manager.can_restart_managed_server())
	assert_false(manager.force_restart_server())
	assert_eq(manager.episode_snapshot(), before)
	assert_false(effects.has(Lifecycle.REPLACE))
	assert_true(manager.request_replacement())
	assert_eq(effects.count(Lifecycle.REPLACE), 1)
	assert_false(manager.request_replacement(), "explicit replacement authority is spend-once")


func test_successful_replacement_continues_same_episode_lineage() -> void:
	var manager := _manager()
	_block_replaceable(manager)
	var episode_id := int(manager.episode_snapshot().id)
	assert_true(manager.authorize_replacement(100, 10))
	assert_true(manager.replace_authorized(100))
	assert_true(manager.complete_effect(episode_id, Lifecycle.REPLACE, {"ok": true}))
	assert_eq(manager.episode_snapshot().id, episode_id)
	assert_eq(manager.episode_snapshot().state, Lifecycle.STARTING)
	assert_eq(manager.episode_snapshot().phase, Lifecycle.PROBE)


func test_foreign_occupant_never_mints_replacement_authority() -> void:
	var manager := _manager()
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "blocked",
		"reason": "occupied",
		"message": "foreign process",
		"target": {"instance_id": "", "version": "", "port": 8000, "replaceable": false},
	})
	assert_false(manager.authorize_replacement(100, 10))
	assert_false(manager.can_recover_incompatible_server())


func test_unbound_status_identity_never_mints_replacement_authority() -> void:
	var result := Lifecycle._blocked_probe_result("occupied", 8000, {
		"name": "godot-ai", "instance_id": INSTANCE, "version": "4.0.1",
	})
	assert_false(result.target.replaceable)


func test_stop_during_probe_invalidates_probe_result() -> void:
	var manager := _manager()
	manager.start_server()
	var stale := manager.episode_snapshot()
	manager.stop_server()
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_false(manager.complete_effect(stale.id, Lifecycle.PROBE, {"outcome": "free"}))


func test_stop_during_launch_invalidates_launch_result() -> void:
	var manager := _manager()
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free"})
	var stale := manager.episode_snapshot()
	manager.stop_server()
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_false(manager.complete_effect(stale.id, Lifecycle.LAUNCH, {"ok": true}))


func _install_held_launch_result(manager: McpServerLifecycleManager) -> Thread:
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free"})
	var worker := Thread.new()
	assert_eq(worker.start(func() -> Dictionary:
		OS.delay_msec(100)
		return {
			"ok": true,
			"pid": 4242,
			"fingerprint": "late-launch-fingerprint",
			"http_capability": HTTP,
			"ws_capability": WS,
			"baseline_instance_id": "",
		}
	), OK)
	manager._effect = {
		"thread": worker,
		"episode_id": int(manager.episode_snapshot().id),
		"kind": Lifecycle.LAUNCH,
	}
	return worker


func test_stop_joins_inflight_launch_and_stops_its_exact_grant() -> void:
	var manager := _manager()
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	var worker := _install_held_launch_result(manager)
	manager.stop_server()
	assert_false(worker.is_alive())
	assert_eq(manager.episode_snapshot().state, Lifecycle.STOPPING)
	var stop: Dictionary = effects[effects.size() - 1]
	assert_eq(stop.kind, Lifecycle.STOP)
	assert_true(stop.payload.grant.matches(4242, "late-launch-fingerprint"))
	assert_true(manager.complete_effect(stop.id, Lifecycle.STOP, {"ok": true}))
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)


func test_editor_exit_joins_inflight_launch_and_stops_its_exact_grant() -> void:
	var manager := _manager()
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	var worker := _install_held_launch_result(manager)
	manager.teardown_for_editor_exit({"name": "godot-ai", "active_lease_count": 0})
	assert_false(worker.is_alive())
	assert_eq(manager.episode_snapshot().state, Lifecycle.STOPPING)
	var stop: Dictionary = effects[effects.size() - 1]
	assert_eq(stop.kind, Lifecycle.STOP)
	assert_true(stop.payload.grant.matches(4242, "late-launch-fingerprint"))


func test_stop_during_prove_uses_launch_grant_and_rejects_proof_result() -> void:
	var manager := _manager()
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free"})
	episode = manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.LAUNCH, {
		"ok": true, "pid": 4242, "fingerprint": "fingerprint",
		"http_capability": HTTP,
		"ws_capability": WS, "baseline_instance_id": "",
	})
	var stale := manager.episode_snapshot()
	manager.stop_server()
	var stopping := manager.episode_snapshot()
	assert_eq(stopping.state, Lifecycle.STOPPING)
	var stop: Dictionary = effects[effects.size() - 1]
	assert_eq(stop.kind, Lifecycle.STOP)
	assert_eq(str(stop.payload.launch.http_capability), HTTP)
	assert_eq(str(stop.payload.launch.ws_capability), WS)
	assert_false(manager.complete_effect(stale.id, Lifecycle.PROVE, {"ok": true}))
	assert_true(manager.complete_effect(stopping.id, Lifecycle.STOP, {"ok": true}))
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)


func test_update_quiescence_reports_unfinished_owned_stop() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	var result := manager.prepare_for_update_reload()
	assert_false(bool(result.get("ok", false)))
	assert_eq(manager.episode_snapshot().state, Lifecycle.STOPPING)


func test_stop_cannot_report_success_while_listener_remains() -> void:
	var holder := TCPServer.new()
	var port := 51261
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for stop postcondition")
		return
	var gone_grant = Authority.OwnedProcessGrant.new(2147483000, "gone", 1)
	var result := Lifecycle.new()._effect_stop({
		"grant": gone_grant,
		"http_port": port,
		"launch": {},
	})
	holder.stop()
	assert_false(bool(result.get("ok", false)))
	assert_eq(str(result.get("reason", "")), "process_stop_failed")


func test_adopted_server_and_keep_alive_owned_server_detach_on_exit() -> void:
	var adopted := _manager()
	_complete_adoption(adopted)
	adopted.teardown_for_editor_exit()
	assert_eq(adopted.episode_snapshot().state, Lifecycle.DORMANT)

	var kept := _manager({"keep_alive": true})
	_complete_owned_start(kept)
	kept.teardown_for_editor_exit()
	assert_eq(kept.episode_snapshot().state, Lifecycle.DORMANT)
	assert_false(kept.has_managed_server())


func test_active_lease_detaches_owned_server_on_exit() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	manager.teardown_for_editor_exit({"name": "godot-ai", "active_lease_count": 2})
	assert_eq(manager.episode_snapshot().state, Lifecycle.DORMANT)
	assert_true(manager.get_status_dict().message.contains("lease"))


func test_no_lease_requests_owned_stop_on_exit() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	manager.teardown_for_editor_exit({"name": "godot-ai", "active_lease_count": 0})
	assert_eq(manager.episode_snapshot().state, Lifecycle.STOPPING)


func test_capability_pair_is_distinct_and_valid_for_managed_bootstrap() -> void:
	var pair := Lifecycle.generate_capability_pair()
	assert_eq(str(pair.http).length(), 64)
	assert_eq(str(pair.websocket).length(), 64)
	assert_ne(pair.http, pair.websocket)
	assert_eq(str(pair.websocket), str(pair.websocket).to_lower())


func test_status_projection_keeps_instance_and_whitelisted_values() -> void:
	var projected := Lifecycle.project_status_payload({
		"name": "godot-ai",
		"server_version": VERSION,
		"ws_port": 9500,
		"instance_id": INSTANCE,
		"active_lease_count": 2.0,
		"secret": "drop-me",
	})
	assert_eq(projected.instance_id, INSTANCE)
	assert_eq(projected.active_lease_count, 2)
	assert_false(projected.has("secret"))


func test_replacement_target_match_is_instance_and_version_bound() -> void:
	var target := {"instance_id": INSTANCE, "version": "4.0.1"}
	var live := {
		"reachable": true, "name": "godot-ai", "instance_id": INSTANCE,
		"version": "4.0.1",
	}
	var record := {"instance_nonce": INSTANCE}
	assert_true(Lifecycle._replacement_target_matches(target, live, record))
	live.instance_id = "c".repeat(32)
	assert_false(Lifecycle._replacement_target_matches(target, live, record))
