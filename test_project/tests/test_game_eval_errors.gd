@tool
extends McpTestSuite

## #490: coverage for the fast game_eval error detection plumbing.
##
## Three layers, all exercised here without a live game subprocess:
##   1. game_logger.gd — counts ERROR_TYPE_SCRIPT (2) errors into a ring that
##      records each error's backtrace function names, and exposes
##      find_script_error_since(baseline, fn) for token correlation.
##   2. game_helper.gd — per-request in-flight tracking + token correlation:
##      _try_report_eval_runtime_error / _handle_eval_check only fail an eval
##      when an error past its baseline carries its uniquely named wrapper
##      function, so unrelated game errors and sibling overlapping evals never
##      cross-attribute.
##   3. mcp_debugger_plugin.gd — editor-side _on_eval_compiled /
##      _on_eval_runtime_error / _clear_pending for the eval flow.
##
## game_logger extends Logger (Godot 4.5+), so the logger/helper tests gate on
## ClassDB.class_exists("Logger") and skip on older engines.

const _LoggerLoader := preload("res://addons/godot_ai/runtime/logger_loader.gd")
const GameHelper := preload("res://addons/godot_ai/runtime/game_helper.gd")
const StubBacktrace := preload("res://addons/godot_ai/testing/stub_backtrace.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const _SCRIPT_ERROR := 2  ## ERROR_TYPE_SCRIPT
const _WARNING := 1       ## ERROR_TYPE_WARNING (push_warning)
const _ERROR := 0         ## ERROR_TYPE_ERROR (push_error)


func suite_name() -> String:
	return "game_eval_errors"


func _build_game_logger():
	var script := _LoggerLoader.build(_LoggerLoader.GAME_LOGGER_PATH)
	assert_true(script != null, "game_logger.gd should compile on Godot 4.5+")
	return script.new() if script != null else null


## Fresh (out-of-tree) game_helper with a fresh logger attached, so _process
## never runs and the in-flight state stays exactly as the test sets it.
func _build_helper_with_logger() -> Array:
	var helper: Node = GameHelper.new()
	var logger = _build_game_logger()
	helper._logger = logger
	return [helper, logger]


## Register an in-flight eval the way _handle_eval does (node omitted — these
## unit tests don't create a real eval node).
func _register_inflight(helper: Node, request_id: String, token: String) -> void:
	helper._inflight_evals[request_id] = {
		"node": null,
		"token": token,
		"baseline": helper._logger.script_error_seq(),
	}


## Emit a script-type (runtime) error whose backtrace frame is `fn`.
func _log_script_error(logger, fn: String, msg := "kaboom") -> void:
	logger._log_error(
		fn, "res://eval.gd", 10, msg, "",
		false, _SCRIPT_ERROR, [StubBacktrace.new("res://eval.gd", 10, fn)])


# --- game_logger: script-error ring + token lookup ---

func test_script_error_increments_seq_and_stores_text() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	assert_eq(logger.script_error_seq(), 0, "counter starts at zero")
	logger._log_error(
		"_run", "res://eval.gd", 10,
		"Invalid call. Nonexistent function 'foo' in base 'Nil'.", "",
		false, _SCRIPT_ERROR, [],
	)
	assert_eq(logger.script_error_seq(), 1, "a script-type error bumps the counter")
	var text: String = logger.last_script_error_text()
	assert_contains(text, "Nonexistent function 'foo'", "stores the real error message")
	assert_contains(text, "res://eval.gd:10 @ _run", "inlines the resolved source location")


func test_script_error_text_prefers_backtrace_frame() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	## A real runtime error reports the engine call site in file/line but the
	## user frame in script_backtraces[0]; the user frame must win.
	logger._log_error(
		"execute", "res://wrapper.gd", 4, "boom", "",
		false, _SCRIPT_ERROR, [StubBacktrace.new("res://user.gd", 99, "_run")],
	)
	assert_eq(logger.script_error_seq(), 1)
	assert_contains(logger.last_script_error_text(), "res://user.gd:99 @ _run",
		"resolves to the user backtrace frame, not the engine call site")


func test_push_error_does_not_bump_script_seq() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	## push_error("x") arrives as type 0 with the message in `code`.
	logger._log_error("_run", "res://eval.gd", 5, "x", "", false, _ERROR, [])
	assert_eq(logger.script_error_seq(), 0,
		"push_error (type 0) must NOT bump the script-error counter (the #490 guard)")


func test_push_warning_does_not_bump_script_seq() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	logger._log_error("_run", "res://eval.gd", 5, "deprecated", "", false, _WARNING, [])
	assert_eq(logger.script_error_seq(), 0,
		"push_warning (type 1) must NOT bump the script-error counter")


func test_find_script_error_since_matches_function_token() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	_log_script_error(logger, "_mcp_run_9", "boom")
	assert_contains(logger.find_script_error_since(0, "_mcp_run_9"), "boom",
		"finds an error whose backtrace contains the queried function")
	assert_eq(logger.find_script_error_since(0, "_mcp_run_other"), "",
		"no match for a function not in any backtrace")


func test_find_script_error_since_respects_baseline() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var logger = _build_game_logger()
	if logger == null:
		return
	_log_script_error(logger, "_mcp_run_9", "boom")  # seq -> 1
	assert_eq(logger.find_script_error_since(1, "_mcp_run_9"), "",
		"errors at/below the baseline seq are excluded")
	assert_contains(logger.find_script_error_since(0, "_mcp_run_9"), "boom",
		"errors after the baseline are included")


# --- game_helper: per-request token-correlated reporting ---

func test_try_report_fires_after_matching_runtime_error() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ1", "7")
	assert_false(helper._try_report_eval_runtime_error("REQ1"),
		"no error yet → nothing to report")
	_log_script_error(logger, "_mcp_run_7", "Nonexistent function 'foo'")
	assert_true(helper._try_report_eval_runtime_error("REQ1"),
		"an error carrying the eval's token reports it")
	assert_false(helper._inflight_evals.has("REQ1"),
		"a reported eval is removed from in-flight")
	helper.free()


func test_try_report_ignores_unrelated_game_error() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	## P2a: a runtime error from the game's own code (different function) while
	## the eval is in flight must NOT fail the eval.
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ1", "7")
	_log_script_error(logger, "_on_some_game_signal", "unrelated game bug")
	assert_false(helper._try_report_eval_runtime_error("REQ1"),
		"an unrelated error (no eval token in its backtrace) must not fail the eval")
	assert_true(helper._inflight_evals.has("REQ1"), "eval stays in flight")
	helper.free()


func test_try_report_isolates_overlapping_evals() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	## P2b: two evals in flight; only one raises a runtime error. The other
	## must be unaffected.
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ_A", "1")
	_register_inflight(helper, "REQ_B", "2")
	_log_script_error(logger, "_mcp_run_2", "B failed")
	assert_false(helper._try_report_eval_runtime_error("REQ_A"),
		"eval A is not failed by eval B's error")
	assert_true(helper._inflight_evals.has("REQ_A"), "eval A stays in flight")
	assert_true(helper._try_report_eval_runtime_error("REQ_B"),
		"eval B is failed by its own error")
	assert_false(helper._inflight_evals.has("REQ_B"), "eval B is removed")
	helper.free()


func test_try_report_ignores_push_error_even_from_eval() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ1", "7")
	## A push_error from inside the eval carries the eval token but is type 0,
	## so it never enters the script-error ring — the eval keeps running.
	logger._log_error("_mcp_run_7", "res://eval.gd", 5, "x", "",
		false, _ERROR, [StubBacktrace.new("res://eval.gd", 5, "_mcp_run_7")])
	assert_false(helper._try_report_eval_runtime_error("REQ1"),
		"a push_error (type 0) must not fail the eval, even with the eval token")
	assert_true(helper._inflight_evals.has("REQ1"))
	helper.free()


func test_handle_eval_check_reports_matching_request() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ1", "7")
	_log_script_error(logger, "_mcp_run_7")
	helper._handle_eval_check(["REQ1"])
	assert_false(helper._inflight_evals.has("REQ1"),
		"a probe for the erroring in-flight request reports + removes it")
	helper.free()


func test_handle_eval_check_ignores_other_request() -> void:
	if not ClassDB.class_exists("Logger"):
		skip("Logger class requires Godot 4.5+")
		return
	var pair := _build_helper_with_logger()
	var helper: Node = pair[0]
	var logger = pair[1]
	_register_inflight(helper, "REQ1", "7")
	_log_script_error(logger, "_mcp_run_7")
	helper._handle_eval_check(["DIFFERENT"])
	assert_true(helper._inflight_evals.has("REQ1"),
		"a probe naming a different request is a no-op")
	helper.free()


# --- editor side: McpDebuggerPlugin compile/runtime handlers ---

## Records send_deferred_response payloads instead of touching a real socket.
class _StubConnection:
	extends McpConnection
	var captured: Array = []

	func send_deferred_response(request_id: String, payload: Dictionary) -> void:
		captured.append({"request_id": request_id, "payload": payload})


func test_on_eval_compiled_flips_compiled_flag() -> void:
	var plugin := McpDebuggerPlugin.new()
	var rid := "rid-compiled"
	plugin._pending[rid] = {"connection": null, "compiled": false}
	plugin._on_eval_compiled([rid])
	assert_true(plugin._pending[rid]["compiled"],
		"mcp:eval_compiled flips the pending entry's compiled flag so the grace timer won't fire")
	## _on_eval_compiled arms a self-re-arming probe timer; clear it so the
	## test leaves nothing ticking.
	plugin._clear_pending(rid)


func test_on_eval_compiled_unknown_request_no_crash() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin._on_eval_compiled(["unknown-id"])
	assert_true(true, "mcp:eval_compiled for an unknown request_id is silently ignored")


func test_on_eval_runtime_error_clears_pending_and_replies_with_code() -> void:
	var plugin := McpDebuggerPlugin.new()
	var conn := _StubConnection.new()
	var rid := "rid-runtime"
	plugin._pending[rid] = {"connection": conn, "compiled": true}
	plugin._on_eval_runtime_error(
		[rid, "Invalid call. Nonexistent function 'foo' in base 'Nil'."])
	assert_false(plugin._pending.has(rid), "a runtime error clears the pending entry")
	assert_eq(conn.captured.size(), 1, "exactly one deferred reply is sent")
	var payload: Dictionary = conn.captured[0]["payload"]
	assert_has_key(payload, "error")
	assert_eq(payload["error"]["code"], ErrorCodes.EVAL_RUNTIME_ERROR,
		"replies with the EVAL_RUNTIME_ERROR code")
	assert_contains(payload["error"]["message"], "Nonexistent function 'foo'",
		"surfaces the real runtime error text")
	conn.free()


func test_on_eval_runtime_error_unknown_request_no_crash() -> void:
	var plugin := McpDebuggerPlugin.new()
	plugin._on_eval_runtime_error(["unknown-id", "boom"])
	assert_true(true, "mcp:eval_runtime_error for an unknown request_id is silently dropped")


func test_clear_pending_disconnects_grace_and_probe_timers() -> void:
	## #490: eval pending entries carry a compile-grace timer and a runtime
	## probe timer beyond the base timeout timer; _clear_pending must release
	## all of them so a resolved request leaves nothing armed.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		skip("No SceneTree available")
		return
	var plugin := McpDebuggerPlugin.new()
	var rid := "rid-clear-eval"
	var grace_cb := func() -> void: pass
	var probe_cb := func() -> void: pass
	var grace := tree.create_timer(60.0)
	var probe := tree.create_timer(60.0)
	grace.timeout.connect(grace_cb)
	probe.timeout.connect(probe_cb)
	plugin._pending[rid] = {
		"connection": null,
		"grace_timer": grace,
		"grace_callable": grace_cb,
		"probe_timer": probe,
		"probe_callable": probe_cb,
	}
	plugin._clear_pending(rid)
	assert_false(plugin._pending.has(rid), "_clear_pending erases the request entry")
	assert_false(grace.timeout.is_connected(grace_cb),
		"_clear_pending disconnects the compile-grace timer")
	assert_false(probe.timeout.is_connected(probe_cb),
		"_clear_pending disconnects the runtime probe timer")


func test_on_eval_ack_sets_flag() -> void:
	var plugin := McpDebuggerPlugin.new()
	var rid := "rid-ack"
	plugin._pending[rid] = {"connection": null, "acked": false, "compiled": false}
	plugin._on_eval_ack([rid])
	assert_true(plugin._pending[rid]["acked"],
		"mcp:eval_ack flips the pending entry's acked flag")


func test_eval_grace_fires_compile_error_when_acked_but_not_compiled() -> void:
	## The positive compile-failure signal: the game acked (started reload) but
	## never sent mcp:eval_compiled → the source failed to parse.
	var plugin := McpDebuggerPlugin.new()
	var conn := _StubConnection.new()
	var rid := "rid-grace-compile"
	plugin._pending[rid] = {"connection": conn, "acked": true, "compiled": false}
	plugin._on_eval_grace(rid)
	assert_false(plugin._pending.has(rid), "a confirmed compile error clears pending")
	assert_eq(conn.captured.size(), 1, "one deferred reply")
	assert_eq(conn.captured[0]["payload"]["error"]["code"], ErrorCodes.EVAL_COMPILE_ERROR,
		"replies with EVAL_COMPILE_ERROR")
	conn.free()


func test_eval_grace_defers_when_not_acked() -> void:
	## The fix: a missing ack means the game hasn't serviced the eval yet (busy
	## main thread), NOT a parse error. Must NOT fire EVAL_COMPILE_ERROR and must
	## leave pending intact so the eventual real reply is still delivered.
	var plugin := McpDebuggerPlugin.new()
	var conn := _StubConnection.new()
	var rid := "rid-grace-noack"
	plugin._pending[rid] = {"connection": conn, "acked": false, "compiled": false}
	plugin._on_eval_grace(rid)
	assert_true(plugin._pending.has(rid),
		"an un-acked eval is left pending (deferred to the normal timeout)")
	assert_eq(conn.captured.size(), 0, "no false EVAL_COMPILE_ERROR is sent")
	conn.free()


func test_eval_grace_noop_when_already_compiled() -> void:
	var plugin := McpDebuggerPlugin.new()
	var conn := _StubConnection.new()
	var rid := "rid-grace-compiled"
	plugin._pending[rid] = {"connection": conn, "acked": true, "compiled": true}
	plugin._on_eval_grace(rid)
	assert_true(plugin._pending.has(rid), "a compiled eval is untouched by the grace timer")
	assert_eq(conn.captured.size(), 0, "no compile error for a compiled eval")
	conn.free()


func test_send_eval_without_active_session_replies_game_not_ready() -> void:
	## #518: with no live debugger session, _send_eval replies with the
	## caller-actionable EVAL_GAME_NOT_READY rather than the opaque INTERNAL_ERROR
	## that the telemetry bucket now reserves for a genuine ~10s eval hang. (The
	## no-session branch returns before touching `tree`, so a bare plugin is safe.)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		skip("No SceneTree available")
		return
	var plugin := McpDebuggerPlugin.new()
	## Gate BEFORE calling _send_eval: a bare plugin normally has no session, but
	## if one were present _send_eval would take its live path (arm timers, send a
	## real mcp:eval into the running game). Skip first so the test never has side
	## effects in that case rather than bailing after the fact.
	if plugin._first_active_session() != null:
		skip("an active debugger session is present; no-session branch not exercised")
		return
	var conn := _StubConnection.new()
	plugin._send_eval(tree, "return 1", "rid-no-session", conn, 10.0)
	assert_eq(conn.captured.size(), 1, "exactly one deferred reply is sent")
	assert_eq(conn.captured[0]["payload"]["error"]["code"], ErrorCodes.EVAL_GAME_NOT_READY,
		"no active debugger session replies with EVAL_GAME_NOT_READY, not INTERNAL_ERROR")
	conn.free()
