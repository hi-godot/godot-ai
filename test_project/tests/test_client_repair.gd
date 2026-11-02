@tool
extends McpTestSuite

const Ownership := preload("res://addons/godot_ai/utils/client_repair_ownership.gd")
const Lock := preload("res://addons/godot_ai/utils/client_mutation_lock.gd")
const Jobs := preload("res://addons/godot_ai/utils/client_job_owner.gd")
var _client: McpClient
var _context: Dictionary
var _target: Dictionary
var _path: String


func suite_name() -> String:
	return "client_repair"


func setup() -> void:
	_path = OS.get_user_data_dir().path_join("repair-%d.json" % Time.get_ticks_usec())
	_client = McpClient.new()
	_client.id = "repair_fixture"
	_client.display_name = "Repair fixture"
	_client.config_type = "json"
	_client.path_template = {"unix": _path, "windows": _path}
	_client.server_key_path = PackedStringArray(["mcpServers"])
	_client.command_shape = McpClient.CommandShape.FLAT
	McpClientRegistry.all()
	McpClientRegistry._by_id[_client.id] = _client
	_context = McpClientConfigurator.capture_launch_context()
	_context["owner_project"] = "fixture-project-A"
	_target = Ownership.target(_client, "godot-ai", PackedStringArray())


func teardown() -> void:
	McpClientRegistry._by_id.erase(_client.id)
	DirAccess.remove_absolute(_path)
	DirAccess.remove_absolute(Ownership.record_path(_target))


func _launch(port: int) -> Dictionary:
	return {"ok": true, "command": "uvx", "args": ["godot-ai==4.0.0", "attach", "--port", str(port)]}


func _enroll(launch: Dictionary) -> void:
	var claim := Lock.acquire(_client.id, "test-enroll")
	assert_true(bool(claim.get("ok", false)))
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", launch).get("status"), "ok")
	assert_true(Ownership.record(_target, "fixture-project-A", launch))
	assert_true(Lock.release(claim))


func _repair(launch: Dictionary, cancelled: Callable = Callable()) -> Dictionary:
	var claim := Lock.acquire(_client.id, "test-repair")
	assert_true(bool(claim.get("ok", false)))
	var result := McpClientConfigurator._repair_locked(_client, _context, launch, cancelled)
	assert_true(Lock.release(claim))
	return result


func test_repair_preserves_preferences_and_updates_baseline() -> void:
	_enroll(_launch(8000))
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_path))
	config.mcpServers["godot-ai"]["env"] = {"CUSTOM": "keep"}
	config.mcpServers["godot-ai"]["autoApprove"] = ["scene_open"]
	config.mcpServers["other"] = {"command": "other-tool"}
	assert_true(McpAtomicWrite.write(_path, JSON.stringify(config)))
	var result := _repair(_launch(8123))
	assert_eq(result.get("status"), "ok")
	var stored: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_path))
	assert_eq(stored.mcpServers["godot-ai"].env, {"CUSTOM": "keep"})
	assert_eq(stored.mcpServers["godot-ai"].autoApprove, ["scene_open"])
	assert_eq(stored.mcpServers.other.command, "other-tool")
	assert_eq(stored.mcpServers["godot-ai"].args, _launch(8123).args)
	assert_eq(Ownership.read(_target).launch.args, _launch(8123).args)
	assert_eq(_repair(_launch(8123)).get("status"), "unchanged")


func test_unowned_foreign_owner_and_external_launch_edits_are_unchanged() -> void:
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", _launch(8000)).get("status"), "ok")
	var original := FileAccess.get_file_as_string(_path)
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), original)
	_enroll(_launch(8000))
	_context.owner_project = "fixture-project-B"
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	_context.owner_project = "fixture-project-A"
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", _launch(8999)).get("status"), "ok")
	original = FileAccess.get_file_as_string(_path)
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), original)


func test_disabled_missing_corrupt_and_cancelled_entries_are_unchanged() -> void:
	_enroll(_launch(8000))
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_path))
	config.mcpServers["godot-ai"].disabled = true
	assert_true(McpAtomicWrite.write(_path, JSON.stringify(config)))
	var original := FileAccess.get_file_as_string(_path)
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), original)
	_enroll(_launch(8000))
	config.mcpServers["godot-ai"].disabled = false
	assert_true(McpAtomicWrite.write(_path, JSON.stringify(config)))
	original = FileAccess.get_file_as_string(_path)
	assert_eq(_repair(_launch(8123), func() -> bool: return true).get("status"), "cancelled")
	assert_eq(FileAccess.get_file_as_string(_path), original)
	assert_true(McpAtomicWrite.write(_path, "{broken"))
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), "{broken")
	assert_eq(DirAccess.remove_absolute(_path), OK)
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_false(FileAccess.file_exists(_path))


func test_configure_enrolls_and_post_update_does_not_transfer_ownership() -> void:
	var result := McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context)
	assert_eq(result.get("status"), "ok")
	assert_true(bool(result.get("repair_enrolled", false)))
	assert_eq(Ownership.read(_target).project, "fixture-project-A")
	_context.owner_project = "fixture-project-B"
	result = McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context, false)
	assert_eq(result.get("status"), "ok")
	assert_eq(Ownership.read(_target).project, "fixture-project-A")
	result = McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context)
	assert_eq(result.get("status"), "ok")
	assert_eq(Ownership.read(_target).project, "fixture-project-B")


func test_toml_disabled_entry_and_unknown_scope_are_refused() -> void:
	_client.config_type = "toml"
	_client.command_shape = McpClient.CommandShape.COMMAND_ARRAY
	_client.toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	assert_true(McpAtomicWrite.write(_path, '[mcp_servers.godot-ai]\ncommand = "uvx"\nargs = []\nenabled = false\n'))
	assert_false(Ownership.enabled(_client, _target))
	_client.config_type = "cli"
	_client.server_key_path = PackedStringArray()
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray()).is_empty())
	_client.config_type = "dsh"
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray()).is_empty())


func test_job_gate_cancels_queued_repairs_without_cancelling_explicit_configure() -> void:
	var jobs := Jobs.new()
	jobs._repair_allowed = true
	jobs._pending_actions = [
		{"client_id": "repair_fixture", "action": "repair"},
		{"client_id": "other", "action": "configure"},
	]
	jobs.set_repair_allowed(false)
	assert_eq(jobs._pending_actions.size(), 1)
	assert_eq(jobs._pending_actions[0].action, "configure")
	assert_false(jobs.request_action("repair_fixture", "repair"))
	jobs._pending_actions.clear()
	jobs.free()


func test_cancelled_queued_repair_can_retry_after_reconnect() -> void:
	var jobs := Jobs.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	jobs._action_threads["occupied"] = null
	var results := {_client.id: {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "queued-key", "repair_generation": jobs._repair_generation}}
	jobs._queue_repairs(results)
	assert_eq(jobs._pending_actions.size(), 1)
	jobs.set_repair_allowed(false)
	assert_true(jobs._pending_actions.is_empty())
	jobs._client_health_blocked = true
	jobs.set_repair_allowed(true)
	jobs._client_health_blocked = false
	results[_client.id].repair_generation = jobs._repair_generation
	jobs._queue_repairs(results)
	assert_eq(jobs._pending_actions.size(), 1, "disconnect before execution must not consume this target forever")
	jobs._action_threads.clear()
	jobs.quiesce()
	jobs.free()


class PausedRepairOwner:
	extends "res://addons/godot_ai/utils/client_job_owner.gd"
	var release := Semaphore.new()
	var refresh_requests: Array = []
	func request_status_refresh(ids: Array[String], force := false) -> bool:
		refresh_requests.append({"ids": ids.duplicate(), "force": force})
		return true
	func _run_action(client_id: String, action: String, url: String, context: Dictionary, prewarm: bool) -> Dictionary:
		release.wait()
		return super._run_action(client_id, action, url, context, prewarm)


func _join_repair(jobs: Node, completed: Array, expected: int) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while completed.size() < expected and Time.get_ticks_msec() < deadline:
		jobs._poll_actions()
		OS.delay_msec(10)
	assert_eq(completed.size(), expected)


func test_running_repair_cancelled_before_write_retries_and_then_stays_consumed() -> void:
	_check_running_cancelled_repair(false)


func test_reconnect_before_cancelled_worker_joins_requests_a_fresh_status() -> void:
	_check_running_cancelled_repair(true)


func _check_running_cancelled_repair(early_reconnect: bool) -> void:
	_context = McpClientConfigurator.capture_launch_context()
	var claim := Lock.acquire(_client.id, "test-cancel-worker-enroll")
	assert_true(bool(claim.get("ok", false)))
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", _launch(8000)).get("status"), "ok")
	assert_true(Ownership.record(_target, str(_context.owner_project), _launch(8000)))
	assert_true(Lock.release(claim))
	var original := FileAccess.get_file_as_string(_path)
	var original_owner := FileAccess.get_file_as_string(Ownership.record_path(_target))
	var jobs := PausedRepairOwner.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	var completed: Array = []
	jobs.action_completed.connect(func(_id: String, _action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		completed.append(result)
	)
	var key := McpClientConfigurator.repair_attempt_key(_client.id, _context, McpClientConfigurator.resolve_attach_launch(_context))
	assert_false(key.is_empty())
	var results := {_client.id: {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": key, "repair_generation": jobs._repair_generation}}
	jobs._queue_repairs(results)
	assert_eq(jobs._action_threads.size(), 1)
	jobs.set_repair_allowed(false)
	assert_true(jobs._repair_attempts.has(key), "unjoined cancellation must not release the key")
	if early_reconnect:
		jobs.set_repair_allowed(true)
		results[_client.id].repair_generation = jobs._repair_generation
		jobs._queue_repairs(results)
		assert_eq(jobs._action_threads.size(), 1, "reconnect must not overlap an unjoined worker")
		assert_eq(jobs.refresh_requests.size(), 1)
	jobs.release.post()
	_join_repair(jobs, completed, 1)
	assert_eq(completed[0].get("status"), "cancelled")
	assert_eq(completed[0].get("mutation_started"), false)
	assert_eq(FileAccess.get_file_as_string(_path), original)
	assert_eq(FileAccess.get_file_as_string(Ownership.record_path(_target)), original_owner)
	if early_reconnect:
		assert_eq(jobs.refresh_requests.size(), 2, "reconnect's earlier status may have skipped the still-owned key")
		assert_eq(jobs.refresh_requests[1], jobs.refresh_requests[0], "retry preserves the reconnect refresh scope")
	else:
		assert_true(jobs.refresh_requests.is_empty(), "cancellation while disconnected does not start another probe")
		jobs.set_repair_allowed(true)
	results[_client.id].repair_generation = jobs._repair_generation
	jobs._queue_repairs(results)
	assert_eq(jobs._action_threads.size(), 1, "reconnect can retry the safely cancelled write")
	jobs.release.post()
	_join_repair(jobs, completed, 2)
	assert_eq(completed[1].get("status"), "ok")
	assert_ne(FileAccess.get_file_as_string(_path), original)
	jobs._queue_repairs(results)
	assert_true(jobs._action_threads.is_empty(), "completed repair remains at most once")
	jobs.quiesce()
	jobs.free()


class DeferredRepairOwner:
	extends "res://addons/godot_ai/utils/client_job_owner.gd"
	var filesystem_busy := true
	func _filesystem_busy() -> bool:
		return filesystem_busy
	func _run_status_refresh(probes: Array[Dictionary], _url: String, _context: Dictionary, generation: int) -> Dictionary:
		var results := {}
		for probe in probes:
			results[str(probe.id)] = {"status": McpClient.Status.CONFIGURED}
		return {"results": results, "generation": generation}


func test_cancelled_repair_preserves_other_clients_in_deferred_reconnect_refresh() -> void:
	var jobs := DeferredRepairOwner.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	jobs._action_threads["occupied"] = null
	jobs._queue_repairs({"codex": {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "deferred-key", "repair_generation": jobs._repair_generation}})
	jobs._pending_actions.clear()
	jobs._action_threads.clear()
	jobs._action_threads["codex"] = null
	jobs._action_names["codex"] = "repair"
	jobs.set_repair_allowed(false)
	jobs.set_repair_allowed(true)
	assert_eq(jobs._refresh_state, McpClientRefreshState.DEFERRED_FOR_FILESYSTEM)
	var completed: Array = []
	jobs.status_refresh_completed.connect(func(results: Dictionary) -> void: completed.append(results))
	jobs._finalize_action("codex", "repair", {"status": "cancelled", "mutation_started": false}, {})
	jobs.filesystem_busy = false
	jobs._retry_deferred_refresh()
	var deadline := Time.get_ticks_msec() + 5000
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		jobs._poll_refresh()
		OS.delay_msec(10)
	assert_eq(completed.size(), 1)
	if not completed.is_empty():
		assert_true(completed[0].has("codex"))
		assert_true(completed[0].has("cursor"), "retry must not displace another client's deferred reconnect status")
	jobs.quiesce()
	jobs.free()


func test_completed_or_ambiguous_repairs_keep_their_attempt_key() -> void:
	for result in [
		{"status": "ok"}, {"status": "unchanged"}, {"status": "skipped"}, {"status": "error"},
		{"status": "cancelled"}, {"status": "cancelled", "mutation_started": true},
		{"status": "cancelled", "mutation_started": false, "termination_failed": true},
		{"status": "cancelled", "mutation_started": false, "mutation_lock_release_failed": true},
	]:
		var jobs := Jobs.new()
		jobs._accepting_work = true
		jobs._repair_allowed = true
		jobs._action_threads["occupied"] = null
		var results := {_client.id: {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "retained-key", "repair_generation": jobs._repair_generation}}
		jobs._queue_repairs(results)
		jobs._pending_actions.clear()
		jobs._finish_repair_attempt(_client.id, "repair", result)
		jobs._queue_repairs(results)
		assert_true(jobs._pending_actions.is_empty(), str(result))
		assert_true(jobs._repair_keys_in_flight.is_empty())
		jobs._action_threads.clear()
		jobs.quiesce()
		jobs.free()


func test_cancelled_repair_retries_remain_bounded_and_target_specific() -> void:
	var jobs := Jobs.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	jobs._action_threads["occupied"] = null
	var other := {"codex": {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "other-key", "repair_generation": jobs._repair_generation}}
	jobs._queue_repairs(other)
	var results := {_client.id: {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "retry-key", "repair_generation": jobs._repair_generation}}
	for index in range(Jobs.MAX_REPAIR_ATTEMPTS - 1):
		jobs._queue_repairs(results)
		assert_eq(jobs._pending_actions.size(), 2, "retry %d is admitted" % index)
		assert_true(jobs.cancel_pending_action(_client.id))
		assert_true(jobs._repair_attempts.has("other-key"))
	jobs._queue_repairs(results)
	assert_eq(jobs._pending_actions.size(), 1, "cancellations cannot evade the session admission limit")
	assert_eq(jobs._repair_admissions, Jobs.MAX_REPAIR_ATTEMPTS)
	jobs._action_threads.clear()
	jobs.quiesce()
	jobs.free()


func test_rejected_repair_does_not_reserve_an_attempt() -> void:
	var jobs := Jobs.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	jobs._queue_repairs({"missing-fixture-client": {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": "missing-key", "repair_generation": jobs._repair_generation}})
	assert_true(jobs._repair_attempts.is_empty())
	assert_true(jobs._repair_keys_in_flight.is_empty())
	assert_eq(jobs._repair_admissions, 0)
	jobs.quiesce()
	jobs.free()


func test_project_override_and_corrupt_ownership_refuse_without_write() -> void:
	_enroll(_launch(8000))
	var original := FileAccess.get_file_as_string(_path)
	assert_true(McpAtomicWrite.write(Ownership.record_path(_target), "{broken"))
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), original)
	_enroll(_launch(8000))
	_client.config_merge_path_templates = {"unix": PackedStringArray([_path]), "windows": PackedStringArray([_path])}
	_client.config_merge_project_paths = PackedStringArray([_path.get_file()])
	_context.project_roots = PackedStringArray([_path.get_base_dir()])
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
	assert_eq(FileAccess.get_file_as_string(_path), original)


func test_attempt_identity_changes_with_target_or_desired_launch() -> void:
	_enroll(_launch(8000))
	var first := McpClientConfigurator.repair_attempt_key(_client.id, _context, _launch(8123))
	assert_false(first.is_empty())
	assert_ne(first, McpClientConfigurator.repair_attempt_key(_client.id, _context, _launch(8999)))
	_context.owner_project = "foreign"
	assert_eq(McpClientConfigurator.repair_attempt_key(_client.id, _context, _launch(8123)), "")


func test_remove_revokes_repair_ownership() -> void:
	_enroll(_launch(8000))
	var result := McpClientConfigurator.remove(_client.id, "http://localhost/mcp", _context)
	assert_eq(result.get("status"), "ok")
	assert_true(Ownership.read(_target).is_empty())


func test_worker_repairs_owned_entry_once_and_joins_before_completion() -> void:
	_context = McpClientConfigurator.capture_launch_context()
	var claim := Lock.acquire(_client.id, "test-worker-enroll")
	assert_true(bool(claim.get("ok", false)))
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", _launch(8000)).get("status"), "ok")
	assert_true(Ownership.record(_target, str(_context.owner_project), _launch(8000)))
	assert_true(Lock.release(claim))
	var jobs := Jobs.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	var completed: Array = []
	jobs.action_completed.connect(func(_id: String, action: String, result: Dictionary, _prewarm: Dictionary) -> void:
		completed.append({"action": action, "result": result})
	)
	var key := McpClientConfigurator.repair_attempt_key(_client.id, _context, _launch(8123))
	var results := {_client.id: {"status": McpClient.Status.CONFIGURED_MISMATCH, "repair_attempt_key": key, "repair_generation": jobs._repair_generation}}
	jobs._queue_repairs(results)
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		jobs._poll_actions()
		if not completed.is_empty():
			break
		OS.delay_msec(10)
	assert_eq(completed.size(), 1)
	if not completed.is_empty():
		assert_eq(completed[0].action, "repair")
		assert_eq(completed[0].result.get("status"), "ok")
	assert_true(jobs._action_threads.is_empty())
	assert_eq(McpClientConfigurator.check_status_details_for_url_with_cli_path(_client.id, McpClientConfigurator.server_url_from(_context), "", _context).get("status"), McpClient.Status.CONFIGURED)
	jobs._queue_repairs(results)
	assert_true(jobs._action_threads.is_empty(), "same target and desired launch is attempted only once")
	assert_eq(completed.size(), 1)
	jobs.quiesce()
	jobs.free()


func test_toml_repair_preserves_timeout_environment_and_comments() -> void:
	_client.config_type = "toml"
	_client.command_shape = McpClient.CommandShape.COMMAND_ARRAY
	_client.toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	var claim := Lock.acquire(_client.id, "test-toml-enroll")
	assert_true(bool(claim.get("ok", false)))
	assert_eq(McpTomlStrategy.configure(_client, "godot-ai", "", _launch(8000)).get("status"), "ok")
	assert_true(Ownership.record(_target, "fixture-project-A", _launch(8000)))
	assert_true(Lock.release(claim))
	var text := FileAccess.get_file_as_string(_path) + '# personal timeout\ntool_timeout_sec = 17\nenabled = true\n[mcp_servers.godot-ai.env]\nKEEP = "value"\n'
	assert_true(McpAtomicWrite.write(_path, text))
	var repair_result := _repair(_launch(8123))
	assert_eq(repair_result.get("status"), "ok", str(repair_result))
	var written := FileAccess.get_file_as_string(_path)
	assert_true(written.contains('tool_timeout_sec = 17'))
	assert_true(written.contains('# personal timeout'))
	assert_true(written.contains('KEEP = "value"'))
	assert_eq(McpTomlStrategy.check_status(_client, "godot-ai", "", _launch(8123)), McpClient.Status.CONFIGURED)


func test_cancellation_rechecked_after_status_verification_before_write() -> void:
	_enroll(_launch(8000))
	var original := FileAccess.get_file_as_string(_path)
	var calls := [0]
	var result := _repair(_launch(8123), func() -> bool:
		calls[0] += 1
		return calls[0] > 1
	)
	assert_eq(result.get("status"), "cancelled")
	assert_eq(calls[0], 2)
	assert_eq(FileAccess.get_file_as_string(_path), original)


func test_stale_generation_cannot_queue_repair_after_reconnect() -> void:
	var jobs := Jobs.new()
	jobs._accepting_work = true
	jobs._repair_allowed = true
	jobs._repair_generation = 3
	jobs._queue_repairs({_client.id: {
		"status": McpClient.Status.CONFIGURED_MISMATCH,
		"repair_attempt_key": "old-session", "repair_generation": 2,
	}})
	assert_true(jobs._pending_actions.is_empty())
	assert_true(jobs._action_threads.is_empty())
	assert_true(jobs._repair_attempts.is_empty())
	jobs.free()


func test_corrupt_unrelated_toml_section_is_not_rewritten() -> void:
	_client.config_type = "toml"
	_client.command_shape = McpClient.CommandShape.COMMAND_ARRAY
	_client.toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	var claim := Lock.acquire(_client.id, "test-corrupt-toml-enroll")
	assert_true(bool(claim.get("ok", false)))
	assert_eq(McpTomlStrategy.configure(_client, "godot-ai", "", _launch(8000)).get("status"), "ok")
	assert_true(Ownership.record(_target, "fixture-project-A", _launch(8000)))
	assert_true(Lock.release(claim))
	var corrupt := FileAccess.get_file_as_string(_path) + '\n[other]\nmalformed = [\n'
	assert_true(McpAtomicWrite.write(_path, corrupt))
	var result := _repair(_launch(8123))
	assert_eq(result.get("status"), "skipped")
	assert_contains(str(result.get("message", "")), "invalid or oversized TOML", "a working parser must reject the malformed file")
	assert_eq(FileAccess.get_file_as_string(_path), corrupt)


func test_toml_parser_cancellation_and_size_limit() -> void:
	assert_true(McpAtomicWrite.write(_path, 'value = 1\n'))
	assert_eq(Ownership.validate_toml(_path, func() -> bool: return true).get("status"), "cancelled")
	assert_true(McpAtomicWrite.write(_path, '#'.repeat(Ownership.TOML_MAX_BYTES + 1)))
	assert_eq(Ownership.validate_toml(_path).get("status"), "skipped")


func test_toml_parser_falls_back_after_unusable_interpreter() -> void:
	for first in [
		{"exit_code": -1, "spawn_failed": true},
		{"exit_code": 1, "stdout": ""},
		{"exit_code": -1, "timed_out": true, "termination_failed": false},
		{"exit_code": 0, "stdout": "unavailable"},
		{"exit_code": 0, "stdout": "unexpected launcher output"},
	]:
		var calls: Array[String] = []
		var result := Ownership.validate_toml(_path, Callable(),
			func(name: String) -> String: return name,
			func(executable: String, args: Array, timeout: int, _cancel: Callable) -> Dictionary:
				calls.append(executable)
				assert_eq(args.slice(0, 3), ["-I", "-S", "-c"])
				assert_eq(args[-1], _path)
				assert_eq(timeout, Ownership.TOML_TIMEOUT_MS)
				return first if executable == "python3" else {"exit_code": 0, "stdout": "valid"}
		)
		assert_eq(result, {}, "an unusable first candidate must not hide a valid parser: " + str(first))
		assert_eq(calls, ["python3", "python"])


func test_toml_parser_invalid_does_not_try_another_interpreter() -> void:
	var calls: Array[String] = []
	var result := Ownership.validate_toml(_path, Callable(),
		func(name: String) -> String: return name,
		func(executable: String, _args: Array, _timeout: int, _cancel: Callable) -> Dictionary:
			calls.append(executable)
			return {"exit_code": 0, "stdout": "invalid" if executable == "python3" else "valid"}
	)
	assert_eq(result.get("status"), "skipped")
	assert_contains(str(result.get("message", "")), "invalid or oversized TOML")
	assert_eq(calls, ["python3"], "a valid parser's invalid result is final")


func test_toml_parser_cancelled_or_unterminated_process_prevents_fallback() -> void:
	for first in [
		{"exit_code": -1, "cancelled": true},
		{"exit_code": -1, "timed_out": true, "termination_failed": true},
	]:
		var calls: Array[String] = []
		var result := Ownership.validate_toml(_path, Callable(),
			func(name: String) -> String: return name,
			func(executable: String, _args: Array, _timeout: int, _cancel: Callable) -> Dictionary:
				calls.append(executable)
				return first
		)
		assert_eq(result.get("status"), "error" if first.get("termination_failed", false) else "cancelled")
		assert_eq(calls, ["python3"])
		if first.get("termination_failed", false):
			assert_true(result.get("termination_failed", false))


func test_toml_parser_cancellation_between_candidates_prevents_second_spawn() -> void:
	var state := {"cancelled": false}
	var calls: Array[String] = []
	var result := Ownership.validate_toml(_path,
		func() -> bool: return state.cancelled,
		func(name: String) -> String: return name,
		func(executable: String, _args: Array, _timeout: int, _cancel: Callable) -> Dictionary:
			calls.append(executable)
			state.cancelled = true
			return {"exit_code": 1}
	)
	assert_eq(result.get("status"), "cancelled")
	assert_eq(calls, ["python3"])


func test_toml_parser_cancellation_during_lookup_prevents_spawn() -> void:
	var state := {"cancelled": false}
	var calls: Array[String] = []
	var result := Ownership.validate_toml(_path,
		func() -> bool: return state.cancelled,
		func(name: String) -> String:
			state.cancelled = true
			return name,
		func(executable: String, _args: Array, _timeout: int, _cancel: Callable) -> Dictionary:
			calls.append(executable)
			return {"exit_code": 0, "stdout": "valid"}
	)
	assert_eq(result.get("status"), "cancelled")
	assert_true(calls.is_empty())


func test_external_scope_and_claude_project_suppression_require_manual_configure() -> void:
	_enroll(_launch(8000))
	_client.config_merge_path_templates = {"unix": PackedStringArray([_path]), "windows": PackedStringArray([_path])}
	_client.config_merge_project_paths = PackedStringArray([".repair-fixture-override.json"])
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray()).is_empty())
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray(), "   ").is_empty())
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray(), _path.get_base_dir()).is_empty())
	assert_false(Ownership.target(_client, "godot-ai", PackedStringArray([_path.get_base_dir()]), _path.get_base_dir()).is_empty())
	_client.config_type = "cli"
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_path))
	config["projects"] = {"/other/project": {"disabledMcpServers": ["godot-ai"]}}
	assert_true(McpAtomicWrite.write(_path, JSON.stringify(config)))
	assert_true(Ownership.target(_client, "godot-ai", PackedStringArray()).is_empty())


func test_settings_switch_emits_immediate_preference_and_persists() -> void:
	var settings := EditorInterface.get_editor_settings()
	var key := McpClientConfigurator.SETTING_AUTO_REPAIR
	var existed := settings.has_setting(key)
	var previous: Variant = settings.get_setting(key) if existed else null
	settings.set_setting(key, false)
	var dock = load("res://addons/godot_ai/mcp_dock.gd").new()
	var tabs := TabContainer.new()
	dock._build_settings_tab(tabs)
	var switches := tabs.find_children("*", "CheckButton", true, false)
	var toggle: CheckButton
	for candidate in switches:
		if candidate.text == "Automatically repair client configuration":
			toggle = candidate
	assert_true(toggle != null, "Settings tab contains the repair switch")
	var captured: Array = []
	dock.settings_apply_requested.connect(func(changes: Dictionary, reload: bool) -> void:
		captured.append({"changes": changes, "reload": reload})
		assert_true(bool(McpClientConfigurator.apply_endpoint_settings(changes).get("ok", false)))
	)
	if toggle != null:
		assert_false(toggle.button_pressed)
		toggle.button_pressed = true
		assert_eq(captured.size(), 1)
		if not captured.is_empty():
			assert_eq(captured[0].changes, {"auto_reconfigure_clients": true})
			assert_false(captured[0].reload)
		assert_true(bool(settings.get_setting(key)))
		settings.set_setting(key, false)
		dock._load_repair_setting()
		assert_false(toggle.button_pressed)
		assert_eq(captured.size(), 1, "Refreshing saved state must not emit another settings mutation")
	tabs.free()
	dock.free()
	if existed:
		settings.set_setting(key, previous)
	else:
		settings.erase(key)


func test_verified_owned_repin_refreshes_baseline_for_later_repair() -> void:
	_enroll(_launch(8000))
	var old_baseline: Dictionary = Ownership.read(_target).launch
	var repinned := McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context, false)
	assert_eq(repinned.get("status"), "ok")
	assert_true(bool(repinned.get("repair_baseline_refreshed", false)))
	assert_false(repinned.has("repair_enrolled"))
	var record := Ownership.read(_target)
	assert_eq(record.project, "fixture-project-A")
	assert_ne(record.launch, old_baseline)
	assert_eq(_repair(_launch(8123)).get("status"), "ok")
	assert_eq(Ownership.read(_target).launch.args, _launch(8123).args)


func test_repin_does_not_enroll_unowned_or_bless_external_launch_edits() -> void:
	var repinned := McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context, false)
	assert_eq(repinned.get("status"), "ok")
	assert_true(Ownership.read(_target).is_empty())
	_enroll(_launch(8000))
	assert_eq(McpJsonStrategy.configure(_client, "godot-ai", "", _launch(8999)).get("status"), "ok")
	var before := Ownership.read(_target)
	repinned = McpClientConfigurator.configure(_client.id, "http://localhost/mcp", _context, false)
	assert_eq(repinned.get("status"), "ok")
	assert_false(repinned.has("repair_baseline_refreshed"))
	assert_eq(Ownership.read(_target), before)
	assert_eq(_repair(_launch(8123)).get("status"), "skipped")
