@tool
class_name McpTestRunner
extends RefCounted

## Lightweight test runner for MCP plugin tests. Discovers test_* methods
## on McpTestSuite instances, runs them, and collects structured results.

var _results: Array[Dictionary] = []
var _last_run_ms: int = 0


func run_suite(suite: McpTestSuite, test_filter: String = "", exclude_test_filter: String = "") -> void:
	var name := suite.suite_name()
	var methods := _get_test_methods(suite)
	var exclusions := _parse_exclusions(exclude_test_filter)

	for method_name in methods:
		if not test_filter.is_empty() and method_name.find(test_filter) == -1:
			continue
		if _matches_any_exclusion(method_name, exclusions):
			_results.append({
				"suite": name,
				"test": method_name,
				"passed": true,
				"skipped": true,
				"message": "Excluded by exclude_test_name filter",
				"assertion_count": 0,
			})
			continue

		suite._reset()
		suite.setup()
		suite.call(method_name)
		suite.teardown()

		## Issue #19 defence: free any `_McpTest*` nodes the test created, even
		## nested ones. If the scene gets auto-saved mid-test while one of these
		## exists, the reference bakes into main.tscn and breaks the next open
		## with a "missing dependency" error. Runs after every test, not just at
		## suite boundaries, so a test that fails mid-flow can't leave a trap
		## for the next test or for scene autosave.
		var scene_root_for_cleanup := EditorInterface.get_edited_scene_root()
		if scene_root_for_cleanup != null and scene_root_for_cleanup.is_inside_tree():
			_free_mcp_test_nodes_recursive(scene_root_for_cleanup)

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


func run_suites(suites: Array, suite_filter: String = "", test_filter: String = "", ctx: Dictionary = {}, verbose: bool = false, exclude_test_filter: String = "") -> Dictionary:
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

		suite._reset_suite_state()
		suite.suite_setup(ctx.duplicate(true))

		## fail_setup() / skip_suite() gives suites a clean way to bail out of
		## suite_setup without leaving N tests to fail with "0 assertions". We
		## emit ONE suite-level result and skip individual tests entirely.
		if suite._suite_failed:
			_results.append({
				"suite": suite.suite_name(),
				"test": "<suite_setup>",
				"passed": false,
				"message": "suite_setup() failed: %s (subsequent tests not run)" % suite._suite_failed_message,
				"assertion_count": 0,
			})
		elif suite._suite_skipped:
			_results.append({
				"suite": suite.suite_name(),
				"test": "<suite_setup>",
				"passed": true,
				"skipped": true,
				"message": "suite_setup() skipped: %s" % suite._suite_skipped_reason,
				"assertion_count": 0,
			})
		else:
			run_suite(suite, test_filter, exclude_test_filter)
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


## Recursively free every node whose name starts with `_McpTest`, anywhere in
## the scene. Intentionally bypasses undo — these are test leaks, not user
## work. Walk breadth-first so we can collect victims before mutating the tree.
func _free_mcp_test_nodes_recursive(root: Node) -> void:
	var victims: Array[Node] = []
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var node: Node = queue.pop_back()
		for child in node.get_children():
			if str(child.name).begins_with("_McpTest"):
				victims.append(child)
			else:
				queue.append(child)
	for v in victims:
		if v.get_parent() != null:
			v.get_parent().remove_child(v)
		v.queue_free()


## Split the `exclude_test_name` filter into individual substring matchers.
## Comma-separated so the CI smoke harness can list multiple flaky tests
## without shipping a richer schema (single names still work — same string,
## no comma, same one-element list). Whitespace around each name is stripped
## so `"a, b"` and `"a,b"` behave identically.
static func _parse_exclusions(filter: String) -> Array[String]:
	var out: Array[String] = []
	if filter.is_empty():
		return out
	for part in filter.split(","):
		var trimmed := part.strip_edges()
		if not trimmed.is_empty():
			out.append(trimmed)
	return out


static func _matches_any_exclusion(method_name: String, exclusions: Array[String]) -> bool:
	for ex in exclusions:
		if method_name.find(ex) != -1:
			return true
	return false
