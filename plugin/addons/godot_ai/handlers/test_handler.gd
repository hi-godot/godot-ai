@tool
extends RefCounted

## Discovers and runs McpTestSuite scripts from res://tests/.
## Exposes run_tests and get_test_results as MCP commands.
##
## Live MCP runs service the WebSocket transport between tests
## (McpConnection.service_transport_during_exclusive_run) so a long suite
## can no longer starve the server's keepalive, and abort at a per-call
## ceiling derived from the server-provided time budget. Direct callers,
## unit-test fixtures, and batch contexts (no request id / no connection)
## keep the legacy fully-synchronous behavior with no ceiling.
## See docs/test-run-transport-starvation-plan.md.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Clamp bounds for the server-provided ``timeout_budget_sec`` param. The
## floor is purely defensive (a malformed or buggy server value must not
## abort every run instantly); the param is not user-facing.
const BUDGET_MIN_SEC := 30.0
const BUDGET_MAX_SEC := 3600.0
## Conservative default when the server sent no (or an invalid) budget: an
## old server's own test_run timeout is 120s, and the plugin must abort
## and reply before that future expires.
const BUDGET_DEFAULT_SEC := 110.0
## Abort this long before the server would time the call out, so the
## partial-results reply beats the server-side timeout.
const CEILING_MARGIN_SEC := 10.0

var _runner: McpTestRunner
var _undo_redo: EditorUndoRedoManager
var _log_buffer: McpLogBuffer
## Live plugin dispatcher, exposed to suites via ctx so tests can prove the
## lazy handler registrations (#736) materialize with their real ctor args.
## Optional third arg keeps old two-arg fixtures working; untyped because
## the dispatcher constructs this handler (avoids a load-time type cycle).
var _dispatcher
## Live connection for exclusive-run transport servicing. Null in unit-test
## fixtures and batch contexts, which keep the legacy synchronous path.
var _connection: McpConnection


func _init(
	undo_redo: EditorUndoRedoManager,
	log_buffer: McpLogBuffer,
	dispatcher = null,
	connection: McpConnection = null,
) -> void:
	_runner = McpTestRunner.new()
	_undo_redo = undo_redo
	_log_buffer = log_buffer
	_dispatcher = dispatcher
	_connection = connection


func run_tests(params: Dictionary) -> Dictionary:
	var suite_filter: String = params.get("suite", "")
	var test_filter: String = params.get("test_name", "")
	var exclude_test_filter: String = params.get("exclude_test_name", "")
	var verbose: bool = params.get("verbose", false)

	var request_id: String = params.get("_request_id", "")
	var live := _connection != null and not request_id.is_empty()
	var service_cb := Callable()
	var deadline_ticks_ms := 0
	var budget_sec := 0.0
	var started_ms := Time.get_ticks_msec()
	var run_state := {}
	if live:
		budget_sec = _validated_budget_sec(params)
		service_cb = Callable(_connection, "service_transport_during_exclusive_run")
		deadline_ticks_ms = started_ms + int((budget_sec - CEILING_MARGIN_SEC) * 1000.0)

	## Clear the previous run's results BEFORE discovery so an abort at any
	## later point can never expose a stale prior run via get_test_results.
	_runner.clear()

	var discovery := _discover_suites(service_cb, deadline_ticks_ms, run_state)
	var discovery_outcome: String = discovery.get("outcome", "")
	if not discovery_outcome.is_empty():
		## Aborted during discovery: no suite has begun, so there is no
		## suite teardown to run. Same outcome mapping as the run itself.
		var empty_results: Dictionary = _runner.get_results(verbose)
		if not discovery.errors.is_empty():
			empty_results["load_errors"] = discovery.errors
		return _map_outcome(
			discovery_outcome, "discovery", empty_results, 0, started_ms, budget_sec
		)

	var suites: Array = discovery.suites
	if suites.is_empty():
		var msg := "No test suites found in res://tests/"
		if not discovery.errors.is_empty():
			msg += " (%d script(s) failed to load: %s)" % [
				discovery.errors.size(),
				", ".join(discovery.errors),
			]
		var no_suites := {"error": msg, "total": 0, "load_errors": discovery.errors}
		## Keep the edited_scene annotation on the no-suites error payload too,
		## so the response contract is consistent across every return path.
		_annotate_edited_scene(no_suites)
		return {"data": no_suites}

	var ctx := {
		"undo_redo": _undo_redo,
		"log_buffer": _log_buffer,
		"dispatcher": _dispatcher,
	}

	var run: Dictionary = _runner.run_suites_serviced(
		suites, suite_filter, test_filter, ctx, verbose, exclude_test_filter,
		service_cb, deadline_ticks_ms, run_state
	)
	var results: Dictionary = run["results"]
	if not discovery.errors.is_empty():
		results["load_errors"] = discovery.errors
	return _map_outcome(
		run["outcome"], "run", results, run["tests_not_run"], started_ms, budget_sec
	)


## Map a runner/discovery outcome onto the response envelope. Ownership is
## deliberately here, not in the runner: the runner reports WHAT happened,
## the handler decides how it goes over the wire (plan D2).
func _map_outcome(
	outcome: String,
	phase: String,
	results: Dictionary,
	tests_not_run: int,
	started_ms: int,
	budget_sec: float,
) -> Dictionary:
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	match outcome:
		"completed":
			_annotate_edited_scene(results)
			return {"data": results}
		"transport_lost":
			## The peer is gone (or flood-closed); the send will fail against
			## the dead socket regardless, but a sync handler must return an
			## envelope. Partials stay retrievable via get_test_results after
			## the plugin reconnects.
			results["aborted"] = "transport_lost"
			results["tests_not_run"] = tests_not_run
			_annotate_edited_scene(results)
			return {"data": results}
		"paused":
			var depth := _connection.pause_depth() if _connection != null else 0
			if _log_buffer != null:
				_log_buffer.log(
					"[error] test run aborted in %s: transport paused at checkpoint (depth %d)"
					% [phase, depth]
				)
			var paused_err := ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				(
					"Test run aborted: the MCP transport was paused at a between-test "
					+ "checkpoint (pause depth %d) — a paused transport cannot service "
					+ "the WebSocket heartbeat, so continuing would starve the session. "
					+ "Partial results: test_manage(op=\"results_get\")."
				) % depth
			)
			paused_err["error"]["data"] = _abort_data(
				phase, results, tests_not_run, elapsed_ms, budget_sec, {"pause_depth": depth}
			)
			return paused_err
		"timeout":
			var timeout_err := ErrorCodes.make(
				ErrorCodes.TEST_RUN_TIMEOUT,
				(
					"Test run hit its abort ceiling after %.1fs (budget %.0fs, ceiling = "
					+ "budget - %.0fs): %d passed, %d failed, %d of the selected tests "
					+ "never ran. Narrow the run with suite=/test_name= filters, or fetch "
					+ "the partial results with test_manage(op=\"results_get\")."
				) % [
					elapsed_ms / 1000.0, budget_sec, CEILING_MARGIN_SEC,
					int(results.get("passed", 0)), int(results.get("failed", 0)),
					tests_not_run,
				]
			)
			timeout_err["error"]["data"] = _abort_data(
				phase, results, tests_not_run, elapsed_ms, budget_sec, {}
			)
			return timeout_err
	## Unknown outcome is a runner bug — surface it loudly.
	return ErrorCodes.make(
		ErrorCodes.INTERNAL_ERROR, "Unknown test run outcome '%s'" % outcome
	)


func _abort_data(
	phase: String,
	results: Dictionary,
	tests_not_run: int,
	elapsed_ms: int,
	budget_sec: float,
	extra: Dictionary,
) -> Dictionary:
	var data := {
		"phase": phase,
		"elapsed_ms": elapsed_ms,
		"budget_sec": budget_sec,
		"passed": int(results.get("passed", 0)),
		"failed": int(results.get("failed", 0)),
		"skipped": int(results.get("skipped", 0)),
		"total": int(results.get("total", 0)),
		"tests_not_run": tests_not_run,
	}
	data.merge(extra)
	return data


## Strict validation of the server-provided per-call budget: numeric,
## finite, positive, then clamped to [BUDGET_MIN_SEC, BUDGET_MAX_SEC].
## Everything else (missing, wrong type, NaN/inf, non-positive) falls back
## to BUDGET_DEFAULT_SEC. typeof() so bool never sneaks through as int.
func _validated_budget_sec(params: Dictionary) -> float:
	var raw: Variant = params.get("timeout_budget_sec", null)
	var t := typeof(raw)
	if t == TYPE_FLOAT or t == TYPE_INT:
		var v := float(raw)
		if is_finite(v) and v > 0.0:
			return clampf(v, BUDGET_MIN_SEC, BUDGET_MAX_SEC)
	return BUDGET_DEFAULT_SEC


## Many suites assume the project's main scene is the edited scene (they read
## /Main/... nodes directly). Running with another scene open produces a flood
## of phantom failures that look like real regressions. Surface the edited
## scene and a warning when it differs from run/main_scene so the failures are
## attributable at a glance instead of costing a debugging round (#635).
func _annotate_edited_scene(results: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var edited := scene_root.scene_file_path if scene_root else ""
	results["edited_scene"] = edited
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty() or edited == main_scene:
		return
	if int(results.get("failed", 0)) <= 0:
		return
	results["scene_warning"] = (
		"Edited scene is '%s' but the project main scene is '%s'. Many suites "
		% [edited if not edited.is_empty() else "<none>", main_scene]
		+ "assume the main scene is open and will report phantom failures "
		+ "otherwise. If these failures are unexpected, scene_open('%s') and re-run." % main_scene
	)


func get_test_results(params: Dictionary) -> Dictionary:
	var verbose: bool = params.get("verbose", false)
	return {"data": _runner.get_results(verbose)}


## Returns {"suites": Array, "errors": Array[String], "outcome": String}.
## Resilient: a broken script doesn't kill discovery of the rest. A
## non-empty outcome ("timeout" / "transport_lost" / "paused") means a
## between-load checkpoint aborted discovery — script loading is itself an
## atomic phase, and a directory of heavy scripts must neither starve the
## heartbeat nor escape the run budget.
func _discover_suites(
	service_cb: Callable = Callable(),
	deadline_ticks_ms: int = 0,
	run_state: Dictionary = {},
) -> Dictionary:
	var suites := []
	var errors: Array[String] = []
	var dir := DirAccess.open("res://tests")
	if dir == null:
		return {
			"suites": suites,
			"errors": ["DirAccess.open('res://tests') returned null — directory may not exist"],
			"outcome": "",
		}

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			var stop := _discovery_checkpoint(service_cb, deadline_ticks_ms, run_state)
			if not stop.is_empty():
				return {"suites": suites, "errors": errors, "outcome": stop}
			var path := "res://tests/" + file_name
			var script = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
			if script == null:
				errors.append("%s (load failed — check for parse errors or duplicate methods)" % file_name)
			elif script.can_instantiate():
				var instance = script.new()
				if instance is McpTestSuite:
					suites.append(instance)
				else:
					errors.append("%s (not a McpTestSuite subclass)" % file_name)
			else:
				errors.append("%s (cannot instantiate — abstract or broken)" % file_name)
		file_name = dir.get_next()

	## Sort by suite name for deterministic order.
	suites.sort_custom(func(a, b) -> bool:
		return a.suite_name() < b.suite_name()
	)
	return {"suites": suites, "errors": errors, "outcome": ""}


## Discovery-phase twin of McpTestRunner._checkpoint. Both delegate to the
## shared McpConnection.exclusive_run_checkpoint so the outcome mapping
## cannot drift between the discovery and between-test paths.
func _discovery_checkpoint(
	service_cb: Callable, deadline_ticks_ms: int, run_state: Dictionary
) -> String:
	return McpConnection.exclusive_run_checkpoint(service_cb, deadline_ticks_ms, run_state)
