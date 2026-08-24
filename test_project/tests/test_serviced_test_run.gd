@tool
extends McpTestSuite

## Tests for the serviced test-run path (transport-starvation fix):
## McpTestRunner.run_suites_serviced outcome contract, the handler's budget
## validation + outcome→envelope mapping, and McpConnection's exclusive-run
## servicing primitives. See docs/test-run-transport-starvation-plan.md.
##
## NOTE: nothing here calls TestHandler.run_tests() end-to-end — that would
## recursively re-run the whole corpus from inside itself. The live path is
## covered by script/ci-slow-suite-smoke and the concurrent-client E2E.

const TestHandlerScript := preload("res://addons/godot_ai/handlers/test_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")


func suite_name() -> String:
	return "serviced_test_run"


## Three-test probe with lifecycle instrumentation.
class ProbeSuite:
	extends McpTestSuite
	var suite_teardown_calls := 0

	func suite_name() -> String:
		return "probe"

	func suite_teardown() -> void:
		suite_teardown_calls += 1

	func test_a() -> void:
		assert_true(true, "a")

	func test_b() -> void:
		assert_true(true, "b")

	func test_c() -> void:
		assert_true(true, "c")


## Classification probe: one fail, one skip, one zero-assert.
class ClassifyProbe:
	extends McpTestSuite

	func suite_name() -> String:
		return "classify_probe"

	func test_fails() -> void:
		assert_true(false, "deliberate failure")

	func test_skips() -> void:
		skip("deliberate skip")

	func test_zero_asserts() -> void:
		pass


func test_completed_outcome_and_duration() -> void:
	var runner := McpTestRunner.new()
	var run: Dictionary = runner.run_suites_serviced([ProbeSuite.new()])
	assert_eq(run["outcome"], "completed", "unserviced run completes")
	assert_eq(int(run["tests_not_run"]), 0, "nothing left unrun")
	var results: Dictionary = run["results"]
	assert_eq(int(results["passed"]), 3, "all probe tests pass")
	assert_eq(int(results["total"]), 3, "three entries")
	var verbose: Dictionary = runner.get_results(true)
	for entry in verbose["results"]:
		assert_true(entry.has("duration_ms"), "per-test duration_ms present")
		assert_true(int(entry["duration_ms"]) >= 0, "duration_ms non-negative")


func test_legacy_run_suites_shape_unchanged() -> void:
	var runner := McpTestRunner.new()
	var results: Dictionary = runner.run_suites([ProbeSuite.new()])
	assert_true(results.has("passed"), "legacy API returns the results dict")
	assert_true(not results.has("outcome"), "legacy API has no outcome wrapper")
	assert_eq(int(results["passed"]), 3, "legacy run passes all probe tests")


func test_classification_equivalence() -> void:
	var runner := McpTestRunner.new()
	var results: Dictionary = runner.run_suites([ClassifyProbe.new()])
	assert_eq(int(results["failed"]), 2, "fail + zero-assert both count as failures")
	assert_eq(int(results["skipped"]), 1, "skip() counts as skipped")
	var messages := []
	for f in results.get("failures", []):
		messages.append(str(f["message"]))
	assert_true(
		"0 assertions" in "\n".join(messages),
		"zero-assert guardrail message survives the refactor"
	)


func test_ceiling_abort_before_first_test() -> void:
	var probe := ProbeSuite.new()
	var runner := McpTestRunner.new()
	var expired := Time.get_ticks_msec() - 10
	var run: Dictionary = runner.run_suites_serviced(
		[probe], "", "", {}, false, "", Callable(), expired
	)
	assert_eq(run["outcome"], "timeout", "expired deadline aborts at first checkpoint")
	assert_eq(int(run["tests_not_run"]), 3, "no probe test ran")
	assert_eq(int(run["results"]["total"]), 0, "no result entries")
	assert_eq(probe.suite_teardown_calls, 1, "suite teardown still ran on abort")


func test_transport_lost_mid_suite_preserves_partials() -> void:
	var probe := ProbeSuite.new()
	var runner := McpTestRunner.new()
	## Checkpoint order per suite: after suite_setup, then after each test.
	## SERVICED once (post-setup), then DISCONNECTED after test_a.
	var calls := [0]
	var cb := func(_run_state: Dictionary) -> int:
		calls[0] += 1
		if calls[0] <= 1:
			return McpConnection.ServiceStatus.SERVICED
		return McpConnection.ServiceStatus.DISCONNECTED
	var run: Dictionary = runner.run_suites_serviced(
		[probe], "", "", {}, false, "", cb
	)
	assert_eq(run["outcome"], "transport_lost", "disconnect maps to transport_lost")
	assert_eq(int(run["results"]["total"]), 1, "exactly one test ran before the abort")
	assert_eq(int(run["tests_not_run"]), 2, "two tests never ran")
	assert_eq(probe.suite_teardown_calls, 1, "suite teardown ran on abort")


func test_paused_outcome() -> void:
	var probe := ProbeSuite.new()
	var runner := McpTestRunner.new()
	var cb := func(_run_state: Dictionary) -> int:
		return McpConnection.ServiceStatus.PAUSED
	var run: Dictionary = runner.run_suites_serviced([probe], "", "", {}, false, "", cb)
	assert_eq(run["outcome"], "paused", "paused transport aborts the run")
	assert_eq(probe.suite_teardown_calls, 1, "suite teardown ran on paused abort")


func test_checkpoint_cadence() -> void:
	var runner := McpTestRunner.new()
	var calls := [0]
	var cb := func(_run_state: Dictionary) -> int:
		calls[0] += 1
		return McpConnection.ServiceStatus.SERVICED
	runner.run_suites_serviced([ProbeSuite.new()], "", "", {}, false, "", cb)
	## Post-suite_setup (1) + after each of 3 tests (3) + suite epilogue (1).
	assert_eq(calls[0], 5, "checkpoints fire between every phase")


func test_run_state_threaded_to_callback() -> void:
	var runner := McpTestRunner.new()
	var seen := [null]
	var cb := func(run_state: Dictionary) -> int:
		seen[0] = run_state
		run_state["marker"] = true
		return McpConnection.ServiceStatus.SERVICED
	var shared := {}
	runner.run_suites_serviced([ProbeSuite.new()], "", "", {}, false, "", cb, 0, shared)
	assert_true(seen[0] != null, "callback received a run_state")
	assert_true(shared.get("marker", false), "the caller-owned dict is the one threaded through")


func test_excluded_test_has_zero_duration() -> void:
	var runner := McpTestRunner.new()
	runner.run_suites_serviced([ProbeSuite.new()], "", "", {}, false, "test_b")
	var verbose: Dictionary = runner.get_results(true)
	var saw_excluded := false
	for entry in verbose["results"]:
		if entry["test"] == "test_b":
			saw_excluded = true
			assert_true(bool(entry.get("skipped", false)), "excluded test is skipped")
			assert_eq(int(entry["duration_ms"]), 0, "excluded test never ran")
	assert_true(saw_excluded, "excluded test still gets an entry")


func test_handler_budget_validation() -> void:
	var handler := TestHandlerScript.new(null, null)
	assert_eq(handler._validated_budget_sec({}), 110.0, "missing -> default")
	assert_eq(
		handler._validated_budget_sec({"timeout_budget_sec": 300.0}), 300.0, "valid float"
	)
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": 300}), 300.0, "valid int")
	assert_eq(
		handler._validated_budget_sec({"timeout_budget_sec": 45.5}), 45.5, "fractional kept"
	)
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": 5}), 30.0, "clamped up")
	assert_eq(
		handler._validated_budget_sec({"timeout_budget_sec": 100000}), 3600.0, "clamped down"
	)
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": 0}), 110.0, "zero -> default")
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": -5}), 110.0, "negative -> default")
	assert_eq(
		handler._validated_budget_sec({"timeout_budget_sec": "300"}), 110.0, "string -> default"
	)
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": true}), 110.0, "bool -> default")
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": NAN}), 110.0, "NaN -> default")
	assert_eq(handler._validated_budget_sec({"timeout_budget_sec": INF}), 110.0, "inf -> default")
	assert_eq(
		handler._validated_budget_sec({"timeout_budget_sec": {"nested": 1}}), 110.0,
		"dict -> default"
	)


func test_handler_map_outcome_timeout_shape() -> void:
	var handler := TestHandlerScript.new(null, null)
	var results := {"passed": 4, "failed": 1, "skipped": 0, "total": 5}
	var envelope: Dictionary = handler._map_outcome(
		"timeout", "run", results, 7, Time.get_ticks_msec() - 5000, 120.0
	)
	assert_eq(envelope["error"]["code"], ErrorCodes.TEST_RUN_TIMEOUT, "timeout error code")
	var data: Dictionary = envelope["error"]["data"]
	assert_eq(int(data["tests_not_run"]), 7, "remaining estimate carried")
	assert_eq(int(data["passed"]), 4, "partial pass count carried")
	assert_eq(data["phase"], "run", "phase carried")
	assert_true(int(data["elapsed_ms"]) >= 5000, "elapsed measured")
	assert_true("results_get" in str(envelope["error"]["message"]), "message points at partials")


func test_handler_map_outcome_paused_shape() -> void:
	var handler := TestHandlerScript.new(null, null)
	var envelope: Dictionary = handler._map_outcome(
		"paused", "run", {"passed": 1, "failed": 0, "skipped": 0, "total": 1},
		2, Time.get_ticks_msec(), 110.0
	)
	assert_eq(envelope["error"]["code"], ErrorCodes.INTERNAL_ERROR, "paused is an invariant violation")
	assert_true(envelope["error"]["data"].has("pause_depth"), "pause depth surfaced")


func test_handler_map_outcome_transport_lost_shape() -> void:
	var handler := TestHandlerScript.new(null, null)
	var results := {"passed": 2, "failed": 0, "skipped": 0, "total": 2}
	var envelope: Dictionary = handler._map_outcome(
		"transport_lost", "run", results, 1, Time.get_ticks_msec(), 110.0
	)
	assert_true(envelope.has("data"), "transport loss still returns a data envelope")
	assert_eq(envelope["data"]["aborted"], "transport_lost", "abort cause marked")
	assert_eq(int(envelope["data"]["tests_not_run"]), 1, "remaining count carried")


func test_handler_discovery_checkpoint_outcomes() -> void:
	## NOTE: only the ABORT paths of _discover_suites run here — they bail at
	## the first checkpoint, BEFORE any script load. The completed path is
	## deliberately not exercised in-suite: it would re-load every res://tests
	## script (CACHE_MODE_IGNORE) including this currently-executing one,
	## which trips a Godot VM internal error. Every live test_run covers it.
	var handler := TestHandlerScript.new(null, null)
	var paused_cb := func(_run_state: Dictionary) -> int:
		return McpConnection.ServiceStatus.PAUSED
	var discovery: Dictionary = handler._discover_suites(paused_cb, 0, {})
	assert_eq(discovery["outcome"], "paused", "paused during discovery is terminal")
	assert_eq(discovery["suites"].size(), 0, "aborted before any suite loaded")
	var expired: Dictionary = handler._discover_suites(Callable(), Time.get_ticks_msec() - 10, {})
	assert_eq(expired["outcome"], "timeout", "expired deadline aborts discovery")
	## The checkpoint helper itself, all three continue/abort classes:
	var ok_cb := func(_run_state: Dictionary) -> int:
		return McpConnection.ServiceStatus.SERVICED
	assert_eq(handler._discovery_checkpoint(ok_cb, 0, {}), "", "SERVICED continues")
	var lost_cb := func(_run_state: Dictionary) -> int:
		return McpConnection.ServiceStatus.DISCONNECTED
	assert_eq(
		handler._discovery_checkpoint(lost_cb, 0, {}), "transport_lost",
		"DISCONNECTED is terminal"
	)


func test_connection_classify_message() -> void:
	var conn := McpConnection.new()
	track(conn)
	var ack: Dictionary = conn._classify_message('{"type":"handshake_ack","server_version":"9.9.9"}')
	assert_eq(ack["kind"], "ack", "ack classified")
	var cmd: Dictionary = conn._classify_message(
		'{"request_id":"r1","command":"node_create","params":{}}'
	)
	assert_eq(cmd["kind"], "command", "valid command classified")
	var malformed: Dictionary = conn._classify_message('{"request_id":42,"command":"x"}')
	assert_eq(malformed["kind"], "malformed_command", "non-string request_id is malformed")
	assert_eq(conn._classify_message("not json")["kind"], "ignore", "garbage ignored")
	assert_eq(conn._classify_message("[1,2]")["kind"], "ignore", "non-dict JSON ignored")
	assert_eq(conn._classify_message('{"type":"other"}')["kind"], "ignore", "unknown dict ignored")


func test_connection_ack_handling_shared_by_service_path() -> void:
	var conn := McpConnection.new()
	track(conn)
	conn._service_handle_message('{"type":"handshake_ack","server_version":"7.7.7"}', 1)
	assert_eq(conn.server_version, "7.7.7", "ack processed during exclusive servicing")


func test_connection_service_reject_shape() -> void:
	var conn := McpConnection.new()
	track(conn)
	var response: Dictionary = conn._build_service_reject(
		{"request_id": "req-9", "command": "node_create", "params": {}}
	)
	assert_eq(response["error"]["code"], ErrorCodes.EDITOR_NOT_READY, "top-level code frozen")
	assert_eq(
		response["error"]["data"]["sub_code"], ErrorCodes.SUB_EDITOR_TEST_RUNNING,
		"sub-code names the state"
	)
	assert_true(bool(response["error"]["data"]["retryable"]), "reject is retryable")
	assert_eq(response["request_id"], "req-9", "request id preserved")
	assert_true(response.has("readiness"), "readiness stamped like every reply")
	assert_true("node_create" in str(response["error"]["message"]), "message names the command")


func test_connection_service_status_without_socket() -> void:
	var conn := McpConnection.new()
	track(conn)
	assert_eq(
		conn.service_transport_during_exclusive_run({}),
		McpConnection.ServiceStatus.DISCONNECTED,
		"fresh peer is not OPEN"
	)
	conn.pause_processing = true
	assert_eq(
		conn.service_transport_during_exclusive_run({}),
		McpConnection.ServiceStatus.PAUSED,
		"paused wins over socket state"
	)
	conn.pause_processing = false
	conn.connect_blocked = true
	assert_eq(
		conn.service_transport_during_exclusive_run({}),
		McpConnection.ServiceStatus.BLOCKED,
		"blocked connection reports BLOCKED"
	)


func test_connection_packet_cap_boundary() -> void:
	var run_state := {"packets_serviced": McpConnection.EXCLUSIVE_RUN_PACKET_CAP - 1}
	assert_true(
		not McpConnection._service_note_packet(run_state),
		"packet AT the cap is still processed"
	)
	assert_true(
		McpConnection._service_note_packet(run_state),
		"packet PAST the cap trips the flood close"
	)
	assert_eq(
		int(run_state["packets_serviced"]), McpConnection.EXCLUSIVE_RUN_PACKET_CAP + 1,
		"counter counts every packet"
	)


func test_batch_rejects_run_tests() -> void:
	var log_buffer := McpLogBuffer.new()
	var dispatcher := McpDispatcher.new(log_buffer)
	var BatchHandler := preload("res://addons/godot_ai/handlers/batch_handler.gd")
	var batch = BatchHandler.new(dispatcher, null)
	var result: Dictionary = batch.batch_execute(
		{"commands": [{"command": "run_tests", "params": {}}]}
	)
	assert_true(result.has("error"), "run_tests in a batch is rejected")
	assert_true(
		"test_run" in str(result["error"]["message"]),
		"rejection points at the test_run tool"
	)
	dispatcher.clear()

func test_unknown_suite_filter_is_an_error_not_an_empty_run() -> void:
	## #882: {"total": 0} for an unmatched `suite` filter is indistinguishable
	## from a suite that registered with no tests — so a truncated discovery
	## (suite file never registered) read as a harmless empty run. Pure-helper
	## pin; run_tests() wires it in right after discovery.
	var suites: Array = [ProbeSuite.new(), ClassifyProbe.new()]
	assert_eq(TestHandlerScript.unknown_suite_error("", suites), {},
		"no filter means no error")
	assert_eq(TestHandlerScript.unknown_suite_error("probe", suites), {},
		"a matching filter means no error")
	var unknown: Dictionary = TestHandlerScript.unknown_suite_error("custom_tools", suites)
	assert_false(unknown.is_empty(), "an unmatched filter must produce the error payload")
	assert_contains(str(unknown.get("error", "")), "custom_tools")
	assert_contains(str(unknown.get("error", "")), "truncated",
		"the message must name the truncated-discovery possibility")
	assert_eq(unknown.get("total"), 0)
	var available: Array = unknown.get("suites_available", [])
	assert_true(available.has("probe") and available.has("classify_probe"),
		"the payload lists what IS registered so the caller can self-diagnose")
