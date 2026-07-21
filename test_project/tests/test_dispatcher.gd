@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ProjectHandler := preload("res://addons/godot_ai/handlers/project_handler.gd")

## Tests for McpDispatcher — specifically the crash-detection guardrail
## that catches handlers returning malformed results (null, empty dict,
## or dicts missing both "data" and "error" keys).

class _FakeErrorTracker:
	extends RefCounted
	var calls := 0

	func watermark() -> Dictionary:
		calls += 1
		return {
			"editor_ring": 1,
			"debugger_promoted": 2,
			"game_error_warn": 3,
		}


func suite_name() -> String:
	return "dispatcher"


func _make_dispatcher() -> McpDispatcher:
	return McpDispatcher.new(McpLogBuffer.new())


# ----- crash detection -----

func test_dispatch_direct_converts_empty_dict_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("returns_empty", func(_p): return {})
	var result := d.dispatch_direct("returns_empty", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "returns_empty")
	assert_contains(result.error.message, "malformed result")


func test_dispatch_direct_converts_null_result_to_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	## GDScript coerces null Variant to {} for typed Dictionary returns, so
	## this ends up looking the same as the empty-dict case — still flagged.
	d.register("returns_null", func(_p): return {})
	var result := d.dispatch_direct("returns_null", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)


func test_dispatch_direct_rejects_dict_missing_data_and_error_keys() -> void:
	## A non-empty dict that still lacks the protocol-required keys is also
	## treated as a crash — e.g. a handler accidentally returns {"foo": 1}.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("malformed", func(_p): return {"foo": "bar", "baz": 42})
	var result := d.dispatch_direct("malformed", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "malformed")


func test_dispatch_direct_accepts_data_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_data", func(_p): return {"data": {"value": 1}})
	var result := d.dispatch_direct("good_data", {})
	assert_has_key(result, "data")
	assert_eq(result.data.value, 1)


func test_dispatch_direct_accepts_error_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("good_error", func(_p):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "bad input"))
	var result := d.dispatch_direct("good_error", {})
	assert_is_error(result)
	assert_eq(result.error.message, "bad input")


func test_dispatch_direct_unknown_command_unchanged() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var result := d.dispatch_direct("never_registered", {})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)


# ----- malformed-result error surfaces args + writes to log buffer (#210) -----


func test_malformed_result_message_includes_received_args() -> void:
	## When a handler crashes / returns junk, the agent has no way to inspect
	## Godot's console. Surface what the handler was called with so the
	## agent can spot a param type mismatch from outside the editor.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var result := d.dispatch_direct("crashy", {"path": "/Main", "group": ["a", "b"]})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "crashy")
	assert_contains(result.error.message, "/Main")
	assert_contains(result.error.message, "group")


func test_malformed_result_message_strips_internal_request_id() -> void:
	## The dispatcher threads `_request_id` into the duplicated params dict
	## for handlers that need it (deferred responses); it must not leak back
	## into a user-facing error message.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var result := d.dispatch_direct("crashy", {"_request_id": "secret-rid-123"})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_true(
		result.error.message.find("secret-rid-123") == -1,
		"_request_id must not appear in the user-facing error message",
	)


func test_malformed_result_writes_error_line_to_log_buffer() -> void:
	## logs_read is the only out-of-editor channel for post-crash context.
	## Confirm a line lands there alongside the protocol response.
	var buf := McpLogBuffer.new()
	var d := McpDispatcher.new(buf)
	d.mcp_logging = true
	d.register("crashy", func(_p): return {})
	d.dispatch_direct("crashy", {"path": "/Main"})
	var lines := buf.get_recent(20)
	var found := false
	for line in lines:
		if line.find("[error]") != -1 and line.find("crashy") != -1:
			found = true
			break
	assert_true(found, "malformed result should log an [error] line")


func test_malformed_result_log_includes_non_empty_backtrace() -> void:
	## Agent-readable logs should carry compact stack context. Runtime
	## GDScript failures surface to the dispatcher as malformed results, so
	## this pins the same guard path without making the test runner depend on
	## engine-version-specific runtime-error continuation semantics.
	var buf := McpLogBuffer.new()
	var d := McpDispatcher.new(buf)
	d.mcp_logging = true
	d.register("crashy", func(_p): return {})
	var result := d.dispatch_direct("crashy", {"path": "/Main"})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "Backtrace:")

	var lines := buf.get_recent(20)
	var found := false
	for line in lines:
		if line.find("[error]") != -1 and line.find("backtrace=") != -1:
			found = line.find("dispatcher.gd") != -1 or line.find("test_dispatcher.gd") != -1
			break
	assert_true(found, "malformed result log should include a non-empty compact backtrace")


func test_malformed_result_truncates_long_args() -> void:
	## Avoid bloating responses with huge param dumps — a few hundred chars
	## is usually enough to identify the bad field.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("crashy", func(_p): return {})
	var big := ""
	for i in range(200):
		big += "x"
	var result := d.dispatch_direct("crashy", {"blob": big + big + big})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "...")


# ----- deferred timeout -----


func test_deferred_response_times_out_and_cleans_pending_entry() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.deferred_timeout_overrides_ms["never_replies"] = 1
	d.register("never_replies", func(_p): return McpDispatcher.DEFERRED_RESPONSE)
	d.enqueue({
		"request_id": "req-timeout",
		"command": "never_replies",
		"params": {},
	})

	var first := d.tick(100.0)
	assert_eq(first.size(), 0, "initial deferred dispatch must not auto-reply")
	assert_eq(d.pending_deferred_count(), 1)

	var started := Time.get_ticks_msec()
	var responses: Array[Dictionary] = []
	while responses.is_empty() and Time.get_ticks_msec() - started < 100:
		responses = d.tick(100.0)

	assert_eq(responses.size(), 1, "deferred timeout should produce one local error")
	assert_eq(responses[0].request_id, "req-timeout")
	assert_is_error(responses[0], ErrorCodes.DEFERRED_TIMEOUT)
	assert_eq(d.pending_deferred_count(), 0, "timeout should clean the pending entry")


func test_deferred_completion_removes_pending_entry() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("later", func(_p): return McpDispatcher.DEFERRED_RESPONSE)
	d.enqueue({
		"request_id": "req-ok",
		"command": "later",
		"params": {},
	})

	d.tick(100.0)
	assert_eq(d.pending_deferred_count(), 1)
	assert_true(d.complete_deferred_response("req-ok"))
	assert_eq(d.pending_deferred_count(), 0)
	assert_false(
		d.complete_deferred_response("req-ok"),
		"late duplicate deferred responses should be rejected",
	)


func test_run_project_has_deferred_timeout_budget() -> void:
	assert_has_key(McpDispatcher.DEFERRED_TIMEOUT_MS_BY_COMMAND, "run_project")
	assert_gt(
		int(McpDispatcher.DEFERRED_TIMEOUT_MS_BY_COMMAND.run_project),
		int(ProjectHandler.RUN_READY_WAIT_SEC * 1000.0),
		"dispatcher timeout must exceed project_run's liveness wait window",
	)


# ----- deferred response path -----

func test_tick_suppresses_deferred_response_and_threads_request_id() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var seen := {}
	d.register("deferred_command", func(p):
		seen["request_id"] = p.get("_request_id", "")
		return McpDispatcher.DEFERRED_RESPONSE
	)

	var params := {"value": 42}
	d.enqueue({
		"request_id": "req-deferred-1",
		"command": "deferred_command",
		"params": params,
	})

	var responses := d.tick()
	assert_eq(responses.size(), 0, "Deferred handlers must not get an immediate auto-response")
	assert_eq(seen.get("request_id", ""), "req-deferred-1")
	assert_false(params.has("_request_id"), "Dispatcher internals must not mutate queued params")
	assert_eq(d.tick().size(), 0, "Deferred command should be drained from the queue")


# ----- envelope-level readiness stamp (server-side stale-cache self-heal) -----


func test_tick_stamps_envelope_readiness_on_success_response() -> void:
	## Every dispatcher reply now carries the live editor readiness so the
	## Python server's session cache self-heals on the very next tool call.
	## Without this, a single dropped `readiness_changed` event leaves
	## `EDITOR_NOT_READY` firing long after `project_run` against a
	## writable editor (the recurring telemetry signal that motivated PR #437).
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("ok_cmd", func(_p): return {"data": {"value": 1}})
	d.enqueue({"request_id": "req-rd-ok", "command": "ok_cmd", "params": {}})

	var responses := d.tick(100.0)
	assert_eq(responses.size(), 1)
	assert_has_key(responses[0], "readiness")
	## The dispatcher runs inside the editor, so any non-empty live readiness
	## from `McpConnection.get_readiness()` is acceptable here — pin only
	## the contract (presence + member of the canonical set).
	var allowed := ["ready", "no_scene", "playing", "importing"]
	assert_true(
		responses[0].readiness in allowed,
		"readiness must be a known state, got %s" % responses[0].readiness,
	)


func test_tick_stamps_error_watermark_on_success_response() -> void:
	var tracker := _FakeErrorTracker.new()
	var d := McpDispatcher.new(McpLogBuffer.new(), tracker)
	d.mcp_logging = false
	d.register("ok_cmd", func(_p): return {"data": {"value": 1}})
	d.enqueue({"request_id": "req-ew-ok", "command": "ok_cmd", "params": {}})

	var responses := d.tick(100.0)
	assert_eq(responses.size(), 1)
	assert_has_key(responses[0], "error_watermark")
	assert_eq(responses[0].error_watermark.editor_ring, 1)
	assert_eq(responses[0].error_watermark.debugger_promoted, 2)
	assert_eq(responses[0].error_watermark.game_error_warn, 3)
	assert_eq(tracker.calls, 1)


func test_tick_stamps_envelope_readiness_on_handler_error_response() -> void:
	## Error replies must also self-heal the cache. Otherwise an agent
	## retrying a recoverable error sees the stale "playing" cache and
	## bails out before reaching the next legitimate write.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register("bad_cmd", func(_p):
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "no such node"))
	d.enqueue({"request_id": "req-rd-err", "command": "bad_cmd", "params": {}})

	var responses := d.tick(100.0)
	assert_eq(responses.size(), 1)
	assert_is_error(responses[0], ErrorCodes.NODE_NOT_FOUND)
	assert_has_key(responses[0], "readiness")


func test_tick_stamps_error_watermark_on_handler_error_response() -> void:
	var tracker := _FakeErrorTracker.new()
	var d := McpDispatcher.new(McpLogBuffer.new(), tracker)
	d.mcp_logging = false
	d.register("bad_cmd", func(_p):
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "no such node"))
	d.enqueue({"request_id": "req-ew-err", "command": "bad_cmd", "params": {}})

	var responses := d.tick(100.0)
	assert_eq(responses.size(), 1)
	assert_is_error(responses[0], ErrorCodes.NODE_NOT_FOUND)
	assert_eq(responses[0].error_watermark.game_error_warn, 3)


func test_tick_stamps_envelope_readiness_on_deferred_timeout_response() -> void:
	## Symmetric with the success/error paths — a deferred-timeout reply
	## is still a server-bound response, so the envelope must heal the
	## cache from this branch too.
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.deferred_timeout_overrides_ms["never_replies"] = 1
	d.register("never_replies", func(_p): return McpDispatcher.DEFERRED_RESPONSE)
	d.enqueue({"request_id": "req-rd-defer", "command": "never_replies", "params": {}})

	d.tick(100.0)
	var responses: Array[Dictionary] = []
	var started := Time.get_ticks_msec()
	while responses.is_empty() and Time.get_ticks_msec() - started < 100:
		responses = d.tick(100.0)

	assert_eq(responses.size(), 1)
	assert_is_error(responses[0], ErrorCodes.DEFERRED_TIMEOUT)
	assert_has_key(responses[0], "readiness")


func test_tick_stamps_error_watermark_on_deferred_timeout_response() -> void:
	var tracker := _FakeErrorTracker.new()
	var d := McpDispatcher.new(McpLogBuffer.new(), tracker)
	d.mcp_logging = false
	d.deferred_timeout_overrides_ms["never_replies"] = 1
	d.register("never_replies", func(_p): return McpDispatcher.DEFERRED_RESPONSE)
	d.enqueue({"request_id": "req-ew-defer", "command": "never_replies", "params": {}})

	d.tick(100.0)
	var responses: Array[Dictionary] = []
	var started := Time.get_ticks_msec()
	while responses.is_empty() and Time.get_ticks_msec() - started < 100:
		responses = d.tick(100.0)

	assert_eq(responses.size(), 1)
	assert_is_error(responses[0], ErrorCodes.DEFERRED_TIMEOUT)
	assert_eq(responses[0].error_watermark.debugger_promoted, 2)


# ----- reserved-key stripping (dispatch_direct) -----

func test_dispatch_direct_strips_reserved_request_id_key() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var seen: Array = []
	d.register("capture_params", func(p: Dictionary) -> Dictionary:
		seen.append(p.duplicate())
		return {"data": {"ok": true}})
	var caller_params := {"_request_id": "hijack", "x": 1}
	var result := d.dispatch_direct("capture_params", caller_params)
	assert_has_key(result, "data")
	assert_eq(result.data.ok, true, "handler should run normally and return its data")
	assert_eq(seen.size(), 1)
	assert_true(not seen[0].has("_request_id"),
		"reserved key must be stripped before the handler sees params")
	assert_eq(seen[0].get("x"), 1)
	assert_true(caller_params.has("_request_id"),
		"stripping must not mutate the caller's dict")


# ----- pause-depth restore on handler crash (#712) -----

## Stand-in for McpConnection's pause surface: the dispatcher only reads
## pause_depth() and calls resume() to rebalance.
class _PauseTargetStub extends RefCounted:
	var depth := 0
	func pause_depth() -> int:
		return depth
	func pause() -> void:
		depth += 1
	func resume() -> void:
		depth = maxi(0, depth - 1)


func test_crashed_handler_leaked_pause_is_restored() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var target := _PauseTargetStub.new()
	d.pause_target = target
	## Simulates a handler that paused, then crashed before resuming —
	## GDScript swallows the error and the dispatcher sees a malformed
	## (empty) result. Without the boundary restore the transport would
	## stay paused forever.
	d.register("crashy_pauser", func(_p):
		target.pause()
		return {})
	var result := d.dispatch_direct("crashy_pauser", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_eq(target.depth, 0, "leaked pause level must be restored at the call boundary")


func test_pause_restore_preserves_outer_depth() -> void:
	## Only the handler's OWN leaked levels are unwound — a pre-existing
	## outer pause (e.g. batch_execute inside a paused save) must survive.
	var d := _make_dispatcher()
	d.mcp_logging = false
	var target := _PauseTargetStub.new()
	target.depth = 1
	d.pause_target = target
	d.register("crashy_pauser", func(_p):
		target.pause()
		return {})
	d.dispatch_direct("crashy_pauser", {})
	assert_eq(target.depth, 1, "restore must stop at the pre-call depth, not zero")


func test_balanced_handler_is_untouched_by_pause_restore() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	var target := _PauseTargetStub.new()
	d.pause_target = target
	d.register("balanced", func(_p):
		target.pause()
		target.resume()
		return {"data": {"ok": true}})
	var result := d.dispatch_direct("balanced", {})
	assert_has_key(result, "data")
	assert_eq(target.depth, 0)


# ----- lazy handler registration (#736) -----

const _LAZY_FIXTURE_PATH := "res://tests/mcp_lazy_handler_fixture.gd"


func _make_lazy_dispatcher() -> McpDispatcher:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register_lazy_handler("fixture", _LAZY_FIXTURE_PATH, ["pre_"])
	d.register_lazy("lazy_echo", "fixture", &"echo")
	return d


func test_lazy_command_counts_as_registered_before_materialization() -> void:
	var d := _make_lazy_dispatcher()
	assert_true(d.has_command("lazy_echo"),
		"lazily-registered commands must be visible to has_command before first dispatch")


func test_lazy_command_dispatches_with_ctor_args() -> void:
	var d := _make_lazy_dispatcher()
	var result := d.dispatch_direct("lazy_echo", {"value": 42})
	assert_has_key(result, "data")
	assert_eq(result.data.echo, "pre_42",
		"handler must be constructed with the registered ctor args")
	var again := d.dispatch_direct("lazy_echo", {"value": 7})
	assert_eq(again.data.echo, "pre_7")


func test_lazy_commands_share_one_cached_handler_instance() -> void:
	var d := _make_lazy_dispatcher()
	d.register_lazy("lazy_count_a", "fixture", &"count")
	d.register_lazy("lazy_count_b", "fixture", &"count")
	assert_eq(d.dispatch_direct("lazy_count_a", {}).data.calls, 1)
	assert_eq(d.dispatch_direct("lazy_count_b", {}).data.calls, 2,
		"both commands must resolve against the same cached handler instance")


func test_lazy_command_dispatches_via_queue_tick() -> void:
	var d := _make_lazy_dispatcher()
	d.enqueue({"request_id": "r-lazy", "command": "lazy_echo", "params": {"value": 5}})
	var responses := d.tick(100.0)
	assert_eq(responses.size(), 1)
	assert_eq(responses[0].data.echo, "pre_5")
	assert_eq(responses[0].request_id, "r-lazy")


func test_lazy_unknown_method_surfaces_internal_error() -> void:
	var d := _make_lazy_dispatcher()
	d.register_lazy("lazy_missing_method", "fixture", &"nope")
	var result := d.dispatch_direct("lazy_missing_method", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "nope")


func test_lazy_unknown_handler_key_surfaces_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register_lazy("lazy_orphan", "ghost", &"echo")
	var result := d.dispatch_direct("lazy_orphan", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "ghost")


func test_lazy_missing_script_surfaces_internal_error() -> void:
	var d := _make_dispatcher()
	d.mcp_logging = false
	d.register_lazy_handler("broken", "res://tests/does_not_exist_handler.gd", [])
	d.register_lazy("lazy_broken", "broken", &"echo")
	var result := d.dispatch_direct("lazy_broken", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "does_not_exist_handler.gd")


func test_lazy_handler_malformed_result_still_flagged() -> void:
	var d := _make_lazy_dispatcher()
	d.register_lazy("lazy_malformed", "fixture", &"malformed")
	var result := d.dispatch_direct("lazy_malformed", {})
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_contains(result.error.message, "malformed result")


func test_suggest_similar_includes_lazy_commands() -> void:
	var d := _make_lazy_dispatcher()
	var suggestions := d.suggest_similar("lazy_echo")
	assert_true("lazy_echo" in suggestions,
		"suggestions must rank lazily-registered command names too")


func test_clear_resets_lazy_state() -> void:
	var d := _make_lazy_dispatcher()
	d.dispatch_direct("lazy_echo", {"value": 1})
	d.clear()
	assert_true(not d.has_command("lazy_echo"), "clear() must drop lazy registrations")
	var result := d.dispatch_direct("lazy_echo", {})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)


# ----- live plugin lazy registration coverage (#736) -----

## The live plugin's dispatcher, provided by test_handler via ctx. Null when
## an old two-arg TestHandler fixture drives the runner.
var _live_dispatcher = null


func suite_setup(ctx: Dictionary) -> void:
	_live_dispatcher = ctx.get("dispatcher")


func test_live_dispatcher_materializes_every_lazy_command() -> void:
	## The eager preload block used to prove at boot that every handler
	## script loads, constructs with its registered args, and has every
	## registered method. Lazy registration moved that proof to first
	## dispatch — this test moves it back under CI: materialize every
	## lazily-registered command of the LIVE plugin dispatcher with its
	## real ctor args. No commands are executed, so nothing mutates.
	if _live_dispatcher == null:
		skip("live dispatcher not exposed in ctx (old test_handler fixture)")
		return
	var specs: Dictionary = _live_dispatcher._lazy_handler_specs
	assert_eq(specs.size(), 28, "every plugin handler should be declared lazily")
	var commands: Array = _live_dispatcher._lazy_commands.keys()
	assert_true(commands.size() > 100,
		"expected the full plugin command surface registered lazily, got %d" % commands.size())
	var handlers_seen: Dictionary = {}
	for command in commands:
		var err: Dictionary = _live_dispatcher._materialize_lazy_command(command)
		assert_true(err.is_empty(),
			"command '%s' failed to materialize: %s" % [command, str(err)])
		handlers_seen[_live_dispatcher._lazy_commands[command]["handler"]] = true
	assert_eq(handlers_seen.size(), specs.size(),
		"every declared lazy handler must be reachable through at least one command")
