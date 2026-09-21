@tool
extends McpTestSuite

const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Authority := preload("res://addons/godot_ai/utils/server_authority.gd")

const VERSION := "4.0.0"
const HTTP := "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
const WS := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const INSTANCE := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"


class _StaleCapabilityLifecycle extends Lifecycle:
	func _read_capability(_port: int) -> Dictionary:
		return {"http": HTTP, "websocket": WS, "instance_nonce": INSTANCE}


class _PortWaitWarnings extends Logger:
	var waits: Array[String] = []

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
		if error_type == ERROR_TYPE_WARNING and (code + rationale).contains("still in use after"):
			waits.append(code + rationale)


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


func test_authenticated_endpoint_loss_blocks_then_schedules_a_bounded_reprobe() -> void:
	var manager := _manager()
	_complete_adoption(manager)
	manager.transport_lost("endpoint vanished")
	var snapshot := manager.get_status_dict()
	assert_eq(snapshot.episode_state, Lifecycle.BLOCKED)
	assert_eq(manager.episode_snapshot().reason, "endpoint_lost")
	assert_true(snapshot.connection_blocked, "the connection is revoked until the server re-proves itself")
	assert_false(snapshot.can_recover_incompatible)
	assert_eq(int(snapshot.recovery_attempt), 1)
	assert_contains(str(snapshot.message), "attempt 1 of 5")
	## The scheduled attempt runs the ordinary start path: probe first.
	var episode_id := int(manager.episode_snapshot().id)
	assert_true(manager.recover_lost_endpoint(episode_id))
	var episode := manager.episode_snapshot()
	assert_eq(episode.state, Lifecycle.STARTING)
	assert_eq(episode.phase, Lifecycle.PROBE)
	## A stale timer (older episode) never disturbs a newer start.
	assert_false(manager.recover_lost_endpoint(episode_id))


func test_endpoint_reprobe_preserves_the_healthy_owned_server_and_stop_grant() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	var grant = manager._process_grant
	var effects: Array[Dictionary] = []
	manager.effect_requested.connect(func(id: int, kind: String, payload: Dictionary):
		effects.append({"id": id, "kind": kind, "payload": payload})
	)
	manager.transport_lost("socket closed")
	assert_true(manager.recover_lost_endpoint(int(manager.episode_snapshot().id)))
	var episode := manager.episode_snapshot()
	assert_eq(episode.state, Lifecycle.STARTING)
	assert_eq(episode.phase, Lifecycle.PROBE)
	assert_eq(effects.size(), 1)
	assert_eq(effects[0].kind, Lifecycle.PROBE)
	assert_true(effects[0].payload.grant == grant)
	assert_true(manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "compatible", "version": VERSION, "transport": _transport(),
		"owned_disposition": "owned",
	}))
	assert_eq(manager.get_status_dict().ready_kind, "owned")
	assert_true(manager._process_grant == grant, "recovery preserves the original exact grant")
	assert_eq(manager.get_server_pid(), 4242)
	assert_eq(effects.size(), 1, "healthy recovery neither stops nor launches a backend")
	manager.stop_server()
	assert_eq(effects[1].kind, Lifecycle.STOP)
	assert_true(effects[1].payload.grant == grant, "explicit teardown keeps its original authority")
	assert_true(manager.complete_effect(effects[1].id, Lifecycle.STOP, {"ok": true}))
	assert_false(manager.has_managed_server())


func test_endpoint_reprobe_of_dead_or_reused_owned_pid_launches_without_killing() -> void:
	for disposition in ["gone", "replaced"]:
		var manager := _manager()
		_complete_owned_start(manager)
		var effects: Array[String] = []
		manager.effect_requested.connect(func(_id: int, kind: String, _payload: Dictionary):
			effects.append(kind)
		)
		manager.transport_lost("backend disappeared")
		assert_true(manager.recover_lost_endpoint(int(manager.episode_snapshot().id)))
		assert_true(manager.complete_effect(manager.episode_snapshot().id, Lifecycle.PROBE, {
			"outcome": "free", "owned_disposition": disposition,
		}))
		assert_eq(manager.episode_snapshot().phase, Lifecycle.LAUNCH)
		assert_false(manager.has_managed_server(), "the dead or reused PID loses its old grant")
		assert_eq(effects, [Lifecycle.PROBE, Lifecycle.LAUNCH], "no STOP is needed for a gone process")


func test_endpoint_reprobe_adopts_replacement_without_transferring_old_grant() -> void:
	var manager := _manager()
	_complete_owned_start(manager)
	manager.transport_lost("backend replaced")
	assert_true(manager.recover_lost_endpoint(int(manager.episode_snapshot().id)))
	assert_true(manager.complete_effect(manager.episode_snapshot().id, Lifecycle.PROBE, {
		"outcome": "compatible", "version": VERSION,
		"transport": _transport("cccccccccccccccccccccccccccccccc"),
		"owned_disposition": "gone",
	}))
	assert_eq(manager.get_status_dict().ready_kind, "adopted")
	assert_false(manager.has_managed_server(), "authenticated replacement does not inherit kill authority")
	assert_eq(manager.get_server_pid(), -1)


func test_endpoint_reprobe_failure_keeps_grant_without_stopping_or_launching() -> void:
	for result in [
		{"outcome": "blocked", "reason": "occupied", "message": "probe timed out"},
		{"outcome": "blocked", "reason": "process_authority_mismatch", "message": "identity unproven"},
		{"outcome": "free", "owned_disposition": "owned"},
		{"outcome": "compatible", "version": VERSION, "transport": _transport()},
	]:
		var manager := _manager()
		_complete_owned_start(manager)
		var grant = manager._process_grant
		var effects: Array[String] = []
		manager.effect_requested.connect(func(_id: int, kind: String, _payload: Dictionary):
			effects.append(kind)
		)
		manager.transport_lost("endpoint lost")
		assert_true(manager.recover_lost_endpoint(int(manager.episode_snapshot().id)))
		assert_true(manager.complete_effect(manager.episode_snapshot().id, Lifecycle.PROBE, result))
		assert_eq(manager.episode_snapshot().state, Lifecycle.BLOCKED)
		assert_true(manager._process_grant == grant)
		assert_eq(effects, [Lifecycle.PROBE], "inconclusive probes never kill or duplicate a live backend")


func test_endpoint_reprobe_gives_up_after_its_budget() -> void:
	var manager := _manager()
	manager._endpoint_recovery_attempts = Lifecycle.ENDPOINT_RECOVERY_DELAYS_SECONDS.size()
	_complete_adoption(manager)
	## Lost again well inside the stability minute: the budget carries over.
	manager.transport_lost("endpoint vanished")
	var snapshot := manager.get_status_dict()
	assert_eq(snapshot.episode_state, Lifecycle.BLOCKED)
	assert_contains(str(snapshot.message), "gave up after 5 attempts")
	assert_eq(int(snapshot.recovery_attempt), 5)
	assert_false(manager.recover_lost_endpoint(int(manager.episode_snapshot().id)),
		"no attempt is left; the dock's Restart is the route")
	assert_eq(manager.episode_snapshot().state, Lifecycle.BLOCKED)


func test_endpoint_reprobe_budget_resets_once_the_server_holds() -> void:
	var manager := _manager()
	manager._endpoint_recovery_attempts = 3
	_complete_adoption(manager)
	assert_eq(int(manager.get_status_dict().recovery_attempt), 3, "reaching READY alone keeps the spent budget")
	## The server then holds for the stability minute before the next loss.
	manager._ready_since_msec = Time.get_ticks_msec() - Lifecycle.ENDPOINT_RECOVERY_STABLE_MS
	manager.transport_lost("endpoint vanished")
	assert_eq(int(manager.get_status_dict().recovery_attempt), 1, "a server that held for a minute earns a fresh budget")


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


func test_replacement_effect_carries_a_launch_plan_that_waits_for_the_port() -> void:
	var manager := _manager()
	var payloads: Array[Dictionary] = []
	manager.effect_requested.connect(func(_id: int, kind: String, payload: Dictionary) -> void:
		if kind == Lifecycle.REPLACE:
			payloads.append(payload)
	)
	_block_replaceable(manager)
	assert_true(manager.request_replacement())
	assert_eq(payloads.size(), 1)
	var launch: Dictionary = payloads[0].get("launch", {})
	assert_eq(int(launch.get("wait_for_port_ms", 0)), Lifecycle.REPLACEMENT_WAIT_FOR_PORT_MS)
	assert_eq(str(launch.get("expected_version", "")), VERSION)


func test_replacement_that_launched_first_continues_at_the_proof() -> void:
	var manager := _manager()
	var effects: Array[String] = []
	manager.effect_requested.connect(func(_id: int, kind: String, _payload: Dictionary) -> void:
		effects.append(kind)
	)
	_block_replaceable(manager)
	var episode_id := int(manager.episode_snapshot().id)
	assert_true(manager.request_replacement())
	assert_true(manager.complete_effect(episode_id, Lifecycle.REPLACE, {
		"ok": true,
		"launch": {
			"ok": true,
			"pid": 4242,
			"fingerprint": "process-start-fingerprint",
			"http_capability": HTTP,
			"ws_capability": WS,
			"baseline_instance_id": "old-record",
		},
	}))
	assert_eq(manager.episode_snapshot().id, episode_id)
	assert_eq(manager.episode_snapshot().state, Lifecycle.STARTING)
	assert_eq(manager.episode_snapshot().phase, Lifecycle.PROVE, "no probe: our server is taking the port")
	assert_false(effects.slice(effects.find(Lifecycle.REPLACE) + 1).has(Lifecycle.PROBE))
	assert_true(effects.has(Lifecycle.PROVE))
	assert_eq(str(manager.episode_snapshot().launch.get("baseline_instance_id", "")), "old-record")


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


func test_stop_of_a_gone_process_succeeds_even_while_a_foreign_listener_remains() -> void:
	## Nothing of ours is left to kill, so whoever holds the port now is not
	## ours to prove stopped: the next start's probe deals with that occupant
	## (an attach bridge's backend, after an update). Refusing here left the
	## lifecycle looping between a failed stop and a block.
	var holder := TCPServer.new()
	var port := 51261
	if holder.listen(port, "127.0.0.1") != OK:
		skip("could not seize port for stop postcondition")
		return
	var gone_pid := OS.create_process(OS.get_executable_path(), ["--headless", "--version"])
	assert_true(gone_pid > 1, "create our short-lived child")
	var deadline := Time.get_ticks_msec() + 5000
	while gone_pid > 1 and OS.is_process_running(gone_pid) and Time.get_ticks_msec() < deadline:
		await (Engine.get_main_loop() as SceneTree).create_timer(0.05).timeout
	assert_false(OS.is_process_running(gone_pid), "our child must have exited before stop")
	var gone_grant = Authority.OwnedProcessGrant.new(gone_pid, "gone", 1)
	var warnings := _PortWaitWarnings.new()
	OS.add_logger(warnings)
	var result := Lifecycle.new()._effect_stop({
		"grant": gone_grant,
		"http_port": port,
		"launch": {},
	})
	OS.remove_logger(warnings)
	assert_eq(warnings.waits, [], "do not wait for an unrelated listener to exit")
	assert_true(holder.is_listening(), "the unrelated listener survives")
	var client := StreamPeerTCP.new()
	assert_eq(client.connect_to_host("127.0.0.1", port), OK)
	client.poll()
	assert_true(client.get_status() in [StreamPeerTCP.STATUS_CONNECTING, StreamPeerTCP.STATUS_CONNECTED])
	client.disconnect_from_host()
	holder.stop()
	assert_true(bool(result.get("ok", false)), str(result))
	assert_false(bool(result.get("already_gone", true)), "the port was not free, so nothing is 'already gone'")
	assert_eq(str(result.get("reason", "")), "")


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


func test_status_projection_surfaces_telemetry_enabled() -> void:
	## #913: the tooltip reads the live server's state from this projection,
	## never from EditorSettings — that is what stops the two disagreeing.
	var off := Lifecycle.project_status_payload({
		"name": "godot-ai", "telemetry_enabled": false,
	})
	assert_true(off.has("telemetry_enabled"))
	assert_eq(off.get("telemetry_enabled"), false)
	var on := Lifecycle.project_status_payload({
		"name": "godot-ai", "telemetry_enabled": true,
	})
	assert_eq(on.get("telemetry_enabled"), true)


func test_status_projection_leaves_telemetry_enabled_absent_on_old_backend() -> void:
	## Same absent-stays-absent rule the lease count follows: "too old to
	## publish it" must stay distinguishable from an explicit false, so the
	## dock shows nothing rather than a state it cannot know.
	var projected := Lifecycle.project_status_payload({
		"name": "godot-ai", "server_version": "3.0.6",
	})
	assert_false(projected.has("telemetry_enabled"))


func test_status_projection_rejects_a_non_bool_telemetry_value() -> void:
	## A garbled backend must not push a truthy string into the field the
	## dock renders a privacy claim from.
	var projected := Lifecycle.project_status_payload({
		"name": "godot-ai", "telemetry_enabled": "true",
	})
	assert_false(projected.has("telemetry_enabled"))


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


func test_unwritable_capability_directory_blocks_the_launch_with_its_repair() -> void:
	var manager := _manager()
	manager.start_server()
	var episode := manager.episode_snapshot()
	manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free", "baseline_instance_id": ""})
	episode = manager.episode_snapshot()
	var repair := "Godot AI cannot use its private directory C:/x; run Remove-Item"
	assert_true(manager.complete_effect(episode.id, Lifecycle.LAUNCH, {
		"ok": false, "reason": "capability_dir_unwritable", "message": repair,
	}))
	var snapshot := manager.episode_snapshot()
	assert_eq(snapshot.state, Lifecycle.BLOCKED)
	assert_eq(snapshot.reason, "capability_dir_unwritable")
	assert_eq(snapshot.message, repair)
	assert_eq(manager.get_server_pid(), -1, "nothing was spawned")


func test_server_flags_carry_the_startup_report_path() -> void:
	var flags := Lifecycle._server_flags({
		"http_port": 8000, "ws_port": 9500, "pid_file": "/tmp/p.pid", "startup_report": "/tmp/r.json",
	})
	var index := flags.find("--startup-report")
	assert_true(index >= 0, "flag present: %s" % str(flags))
	assert_eq(flags[index + 1], "/tmp/r.json")
	var without := Lifecycle._server_flags({"http_port": 8000, "ws_port": 9500, "pid_file": "/tmp/p.pid"})
	assert_false(without.has("--startup-report"))


func test_launch_failure_carries_the_startup_report() -> void:
	## A server that refused to start dies before its identity is captured;
	## the launch-unproven block must still quote why (the WebSocket port
	## conflict behind two 4.0.3 reports showed only "identity could not be
	## captured" while the report on disk named the port).
	var path := OS.get_user_data_dir().path_join("lifecycle_launch_report_test.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"pid": 1, "error": "OSError",
		"message": "WebSocket port 9500 is already in use by another process.", "hint": "",
	}))
	file.close()
	var manager := _manager({"startup_report": path})
	manager.start_server()
	var episode := manager.episode_snapshot()
	assert_true(manager.complete_effect(episode.id, Lifecycle.PROBE, {"outcome": "free", "baseline_instance_id": ""}))
	episode = manager.episode_snapshot()
	assert_true(manager.complete_effect(episode.id, Lifecycle.LAUNCH, {
		"ok": false, "reason": "launch_unproven",
		"message": "The launched process identity could not be captured in 58 attempts over 15.0 s.",
	}))
	var message := str(manager.get_status_dict().message)
	assert_true(message.contains("could not be captured"), message)
	assert_true(message.contains("Server reported: OSError: WebSocket port 9500"), message)
	DirAccess.remove_absolute(path)


func test_windows_unbound_status_probe_retains_missing_capability_priority() -> void:
	if OS.get_name() != "Windows":
		skip("Windows positive-bind shortcut")
		return
	var port := McpClientConfigurator.suggest_free_port(41000)
	var listener := TCPServer.new()
	var bound := listener.listen(port, "127.0.0.1")
	listener.stop()
	assert_eq(bound, OK, "the test owns and releases an actual loopback port")
	if bound != OK:
		return
	var missing := Lifecycle._probe_with_capability(port, {}, 3000)
	assert_eq(str(missing.error), "missing_capability")
	var result := Lifecycle._probe_with_capability(port, {
		"http": HTTP, "websocket": WS, "instance_nonce": INSTANCE,
	}, 3000)
	assert_false(bool(result.reachable))
	assert_eq(str(result.error), "port_unbound")
	assert_eq(str(result.instance_id), "", "free-port evidence cannot authenticate an instance")
	assert_eq(int(result.status_code), 0, "no HTTP response was claimed")


func test_probe_blocks_on_a_held_websocket_port_before_launch() -> void:
	## Both ports bind together; a held WebSocket port would kill the launch at
	## the server's preflight. The probe names it and the setting instead.
	var ws_port := McpClientConfigurator.suggest_free_port(41000)
	var listener := TCPServer.new()
	assert_eq(listener.listen(ws_port, "127.0.0.1"), OK)
	var http_port := McpClientConfigurator.suggest_free_port(ws_port + 1)
	## A stale record must exercise the HTTP probe rather than bypass it for
	## missing credentials. The held socket remains the real refusal boundary.
	var manager := _StaleCapabilityLifecycle.new()
	manager.configure({"automatic_effects": false})
	var result := manager._effect_probe({
		"http_port": http_port, "expected_version": VERSION,
		"expected_ws_port": ws_port, "timeout_ms": 200,
	})
	listener.stop()
	assert_eq(str(result.outcome), "blocked")
	assert_eq(str(result.reason), "ws_occupied")
	assert_true(str(result.message).contains("WebSocket port %d" % ws_port), result.message)
	assert_true(str(result.message).contains("godot_ai/ws_port"), result.message)
	assert_eq(int(result.target.port), ws_port)
	assert_false(bool(result.target.replaceable))
	assert_false(result.has("transport"), "a held WS port grants no transport")
	## With the WebSocket port free again the same probe reports free.
	var free_result := manager._effect_probe({
		"http_port": http_port, "expected_version": VERSION,
		"expected_ws_port": ws_port, "timeout_ms": 200,
	})
	assert_eq(str(free_result.outcome), "free")
	assert_false(free_result.has("transport"))


func test_occupied_block_names_why_the_record_did_not_authenticate() -> void:
	## "Held by another process" hid the interesting fact: a godot-ai record
	## existed for the port and its authenticated probe failed. Say why.
	var record := {"http": "token", "websocket": "ws", "instance_nonce": "abc"}
	assert_eq(
		Lifecycle._record_probe_failure_detail(record, {"reachable": false, "error": "connect_timeout"}),
		"a godot-ai record for this port exists, but its status probe failed: connect_timeout"
	)
	assert_eq(
		Lifecycle._record_probe_failure_detail(record, {"reachable": true, "name": "godot-ai", "instance_id": "other", "error": ""}),
		"a godot-ai record for this port exists, but it belongs to a different server instance"
	)
	assert_eq(Lifecycle._record_probe_failure_detail({}, {"error": "connect_timeout"}), "", "no record, nothing to explain")
	var result := Lifecycle._blocked_probe_result(
		"occupied", 8000, {"error": "connect_timeout"}, false,
		"a godot-ai record for this port exists, but its status probe failed: connect_timeout"
	)
	assert_true(str(result.message).begins_with("Port 8000 is occupied by another process (a godot-ai record"), result.message)
	assert_false(bool(result.target.replaceable))
	var plain := Lifecycle._blocked_probe_result("occupied", 8000, {})
	assert_eq(str(plain.message), "Port 8000 is occupied by another process.")


func test_startup_report_summary_quotes_the_server_failure() -> void:
	var path := OS.get_user_data_dir().path_join("lifecycle_startup_report_test.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(
		'{"pid": 1, "error": "PermissionError", "message": "denied\\nsecond", "hint": "run Remove-Item"}'
	)
	file.close()
	assert_eq(
		Lifecycle.startup_report_summary(path),
		" Server reported: PermissionError: denied second run Remove-Item"
	)
	assert_true(Lifecycle.startup_report_summary(path, 30).length() <= 30, "bounded")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not json")
	file.close()
	assert_eq(Lifecycle.startup_report_summary(path), "")
	DirAccess.remove_absolute(path)
	assert_eq(Lifecycle.startup_report_summary(path), "")
	assert_eq(Lifecycle.startup_report_summary(""), "")


func test_launch_unproven_message_summarises_the_refusals() -> void:
	var manager := Lifecycle.new()
	var message := manager._launch_unproven_message(
		2147480000, ["not_alive", "not_alive", "unbranded"], 15200
	)
	assert_true(message.contains("3 attempts over 15.2 s"), message)
	assert_true(message.contains("pid 2147480000"), message)
	assert_true(message.contains("now alive=no"), message)
	assert_true(message.contains("not_alive×2, unbranded×1"), message)
	var empty := manager._launch_unproven_message(2147480000, [], 0)
	assert_true(empty.contains("none recorded"), empty)
func test_pre_v4_version_is_read_only_from_a_godot_ai_3x_claim() -> void:
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "godot-ai", "server_version": "3.2.4"}), "3.2.4")
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "godot-ai", "server_version": "4.0.2"}), "")
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "other", "server_version": "3.2.4"}), "")
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "godot-ai", "server_version": "3.2.4 <b>x</b>"}), "")
	for malformed in ["3.", "3..2", "3.2.", "3.2.4.", "3.-1", "3"]:
		assert_eq(
			Lifecycle.pre_v4_version_from_status({"name": "godot-ai", "server_version": malformed}),
			"",
			"malformed version must not be trusted: %s" % malformed
		)
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "godot-ai", "server_version": "3.10.12"}), "3.10.12")
	assert_eq(Lifecycle.pre_v4_version_from_status({"name": "godot-ai"}), "")
	assert_eq(Lifecycle.pre_v4_version_from_status("not a dictionary"), "")
	assert_eq(Lifecycle.pre_v4_version_from_status(null), "")


func test_stale_pre_v4_block_is_worded_but_never_replaceable() -> void:
	var manager := _manager()
	manager.start_server()
	var episode := manager.episode_snapshot()
	var message := Lifecycle.stale_pre_v4_message(8000, "3.2.4")
	assert_true(message.contains("Godot AI 3.2.4 server"), message)
	assert_true(message.contains("Quit and relaunch"), message)
	assert_true(manager.complete_effect(episode.id, Lifecycle.PROBE, {
		"outcome": "blocked",
		"reason": "occupied",
		"message": message,
		"target": {
			"instance_id": "",
			"version": "",
			"port": 8000,
			"replaceable": false,
			"hint": Lifecycle.STALE_PRE_V4_HINT,
		},
	}))
	var status := manager.get_status_dict()
	assert_eq(status.state, McpServerState.FOREIGN_PORT)
	assert_eq(status.blocked_hint, Lifecycle.STALE_PRE_V4_HINT)
	assert_eq(status.message, message)
	assert_false(bool(status.can_recover_incompatible), "an unauthenticated occupant is never recoverable")
	assert_false(manager.request_replacement(), "the untrusted peek must never mint replacement authority")
	assert_eq(manager.get_status_dict().blocked_hint, Lifecycle.STALE_PRE_V4_HINT)


func test_launch_reached_port_wait_reads_only_this_launch_s_wait_phase() -> void:
	var path := OS.get_user_data_dir().path_join("lifecycle_port_wait_phase_test.json")
	assert_false(Lifecycle.launch_reached_port_wait(path, "launch-1"), "no report yet")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string('{"pid": 4242, "phase": "waiting_for_port", "port": 8000, "label": "HTTP", "launch_id": "launch-1"}')
	file.close()
	assert_true(Lifecycle.launch_reached_port_wait(path, "launch-1"))
	assert_false(
		Lifecycle.launch_reached_port_wait(path, "launch-2"),
		"a stale report from an earlier launch must never pass for this one"
	)
	assert_false(Lifecycle.launch_reached_port_wait(path, ""), "an unnamed launch matches nothing")
	assert_eq(Lifecycle.startup_report_summary(path), "", "a phase is not a failure to quote")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string('{"pid": 4242, "phase": "waiting_for_port", "port": 8000}')
	file.close()
	assert_false(Lifecycle.launch_reached_port_wait(path, "launch-1"), "a report without a launch id")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string('{"pid": 4242, "error": "OSError", "message": "port 8000 is already in use", "launch_id": "launch-1"}')
	file.close()
	assert_false(Lifecycle.launch_reached_port_wait(path, "launch-1"), "the failure that replaced the phase")
	assert_true(Lifecycle.startup_report_summary(path).contains("already in use"))
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("not json")
	file.close()
	assert_false(Lifecycle.launch_reached_port_wait(path, "launch-1"))
	DirAccess.remove_absolute(path)
	assert_false(Lifecycle.launch_reached_port_wait("", "launch-1"))
