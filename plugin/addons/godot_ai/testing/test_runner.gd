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

		if suite._skipped:
			_results.append({
				"suite": name,
				"test": method_name,
				"passed": true,
				"skipped": true,
				"message": suite._skip_reason,
				"assertion_count": 0,
			})
			continue

		var passed := not suite._failed
		var msg := suite._message

		## Warn about zero-assertion tests (likely silently skipped logic).
		if passed and suite._assertion_count == 0:
			passed = false
			msg = "Test completed with 0 assertions (likely skipped its logic)"

		_results.append({
			"suite": name,
			"test": method_name,
			"passed": passed,
			"message": msg,
			"assertion_count": suite._assertion_count,
		})


func run_suites(suites: Array, suite_filter: String = "", test_filter: String = "", ctx: Dictionary = {}, verbose: bool = false) -> Dictionary:
	_results.clear()
	var start := Time.get_ticks_msec()

	for suite: McpTestSuite in suites:
		if not suite_filter.is_empty() and suite.suite_name() != suite_filter:
			continue

		## Snapshot scene children before the suite so we can clean up leaks.
		var scene_root := EditorInterface.get_edited_scene_root()
		var before_children: Array[Node] = []
		if scene_root != null:
			before_children = _get_children_snapshot(scene_root)

		suite.suite_setup(ctx.duplicate(true))
		run_suite(suite, test_filter)
		suite.suite_teardown()

		## Remove any nodes the suite left behind (failed undo, missing cleanup).
		if scene_root != null and scene_root.is_inside_tree():
			_cleanup_leaked_nodes(scene_root, before_children)

	_last_run_ms = Time.get_ticks_msec() - start
	return get_results(verbose)


func get_results(verbose: bool = false) -> Dictionary:
	var passed := 0
	var failed := 0
	var skipped := 0
	var failures: Array[Dictionary] = []
	var suites_seen := {}
	for r in _results:
		suites_seen[r.suite] = true
		if r.get("skipped", false):
			skipped += 1
		elif r.passed:
			passed += 1
		else:
			failed += 1
			failures.append(r)

	var result := {
		"passed": passed,
		"failed": failed,
		"skipped": skipped,
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


func _get_children_snapshot(node: Node) -> Array[Node]:
	var children: Array[Node] = []
	for child in node.get_children():
		children.append(child)
	return children


## Remove any nodes in scene_root that weren't present before the suite ran,
## plus any _McpTest* named nodes anywhere in the tree (catches nested leaks).
## NOTE: this bypasses EditorUndoRedoManager by design — the test runner
## owns these leaks and needs to clear them unconditionally. Don't Ctrl-Z in
## the editor immediately after a test run that triggered cleanup; the undo
## stack may reference freed nodes.
func _cleanup_leaked_nodes(scene_root: Node, before: Array[Node]) -> void:
	var before_set := {}
	for n in before:
		before_set[n] = true
	for child in scene_root.get_children():
		if not before_set.has(child):
			scene_root.remove_child(child)
			child.queue_free()
	# Also sweep descendants for _McpTest* nodes added under non-root parents.
	for child in scene_root.get_children():
		_sweep_mcp_test_nodes(child)


func _sweep_mcp_test_nodes(node: Node) -> void:
	for child in node.get_children():
		if child.name.begins_with("_McpTest"):
			node.remove_child(child)
			child.queue_free()
		else:
			_sweep_mcp_test_nodes(child)
