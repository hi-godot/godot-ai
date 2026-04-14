@tool
class_name McpTestRunner
extends RefCounted

## Lightweight test runner for MCP plugin tests. Discovers test_* methods
## on McpTestSuite instances, runs them, and collects structured results.

var _results: Array[Dictionary] = []
var _last_run_ms: int = 0


func run_suite(suite: McpTestSuite, test_filter: String = "") -> void:
	var name := suite.suite_name()
	var methods := _get_test_methods(suite)

	for method_name in methods:
		if not test_filter.is_empty() and method_name.find(test_filter) == -1:
			continue

		suite._reset()
		suite.setup()
		suite.call(method_name)
		suite.teardown()

		_results.append({
			"suite": name,
			"test": method_name,
			"passed": not suite._failed,
			"message": suite._message,
		})


func run_suites(suites: Array, suite_filter: String = "", test_filter: String = "", ctx: Dictionary = {}, verbose: bool = false) -> Dictionary:
	_results.clear()
	var start := Time.get_ticks_msec()

	for suite: McpTestSuite in suites:
		if not suite_filter.is_empty() and suite.suite_name() != suite_filter:
			continue
		suite.suite_setup(ctx)
		run_suite(suite, test_filter)
		suite.suite_teardown()

	_last_run_ms = Time.get_ticks_msec() - start
	return get_results(verbose)


func get_results(verbose: bool = false) -> Dictionary:
	var passed := 0
	var failed := 0
	var failures: Array[Dictionary] = []
	var suites_seen := {}
	for r in _results:
		suites_seen[r.suite] = true
		if r.passed:
			passed += 1
		else:
			failed += 1
			failures.append(r)

	var result := {
		"passed": passed,
		"failed": failed,
		"total": _results.size(),
		"duration_ms": _last_run_ms,
		"suites_run": suites_seen.keys(),
		"suite_count": suites_seen.size(),
	}

	if not failures.is_empty():
		result["failures"] = failures

	if verbose:
		result["results"] = _results

	return result


func clear() -> void:
	_results.clear()
	_last_run_ms = 0


func _get_test_methods(obj: Object) -> Array[String]:
	var methods: Array[String] = []
	for m in obj.get_method_list():
		var name: String = m.get("name", "")
		if name.begins_with("test_"):
			methods.append(name)
	methods.sort()
	return methods
