@tool
extends McpTestSuite

## Tests for McpTestRunner itself — specifically the guardrails that
## catch silent failures: skip() mechanism, zero-assertion detection,
## deep ctx isolation, and leaked-node cleanup.


func suite_name() -> String:
	return "test_runner"


# ----- inner suites used as test fixtures -----

class _SkipSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_skip"
	func test_skipped() -> void:
		skip("precondition not met")


class _ZeroAssertSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_zero"
	func test_no_assertions() -> void:
		return  # intentionally never asserts


class _PassingSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_pass"
	func test_one_assert() -> void:
		assert_true(true)


class _CtxMutatorSuite extends McpTestSuite:
	var _seen_ctx: Dictionary
	func suite_name() -> String: return "inner_ctx"
	func suite_setup(ctx: Dictionary) -> void:
		_seen_ctx = ctx
		## Mutate both top-level and nested — deep copy should protect both.
		ctx["new_top"] = "added"
		if ctx.has("nested"):
			ctx.nested["injected"] = "leaked"
	func test_dummy() -> void:
		assert_true(true)


class _LeakingSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_leak"
	func test_leaks_a_node() -> void:
		## Attach a Node3D to the scene root and forget to clean it up.
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return
		var leak := Node3D.new()
		leak.name = "__runner_leak_node__"
		scene_root.add_child(leak)
		assert_true(true)


# ----- skip() semantics -----

func test_skip_records_separately_from_pass_fail() -> void:
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_SkipSuite.new()])
	assert_eq(result.skipped, 1, "one skipped test")
	assert_eq(result.passed, 0, "skip does not count as pass")
	assert_eq(result.failed, 0, "skip does not count as fail")
	assert_eq(result.total, 1)


# ----- zero-assertion detection -----

func test_zero_assertion_test_is_flagged_as_failure() -> void:
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_ZeroAssertSuite.new()])
	assert_eq(result.failed, 1, "zero-assertion test should fail")
	assert_eq(result.passed, 0)
	assert_has_key(result, "failures")
	assert_contains(result.failures[0].message, "0 assertions")


func test_single_assertion_test_passes() -> void:
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_PassingSuite.new()])
	assert_eq(result.passed, 1)
	assert_eq(result.failed, 0)


# ----- ctx deep-copy isolation -----

func test_suite_setup_receives_deep_copy_of_ctx() -> void:
	var runner := McpTestRunner.new()
	var nested := {"value": 1}
	var ctx := {"top": "original", "nested": nested}
	var suite := _CtxMutatorSuite.new()

	runner.run_suites([suite], "", "", ctx)

	## The original ctx must be untouched — top level AND nested.
	assert_eq(ctx.top, "original", "top-level key should not leak back")
	assert_false(ctx.has("new_top"), "new top-level key should not leak back")
	assert_false(nested.has("injected"), "nested dict should be deep-copied")
	assert_eq(nested.value, 1, "nested value should be unchanged")


# ----- leaked-node cleanup -----

func test_leaked_nodes_are_cleaned_up_after_suite() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root — is a scene open?")
		return

	var before_count := scene_root.get_child_count()
	var runner := McpTestRunner.new()
	runner.run_suites([_LeakingSuite.new()])

	## The suite leaked one node; cleanup should have removed it.
	assert_eq(scene_root.get_child_count(), before_count,
		"leaked node should be removed by runner")
	assert_eq(scene_root.get_node_or_null("__runner_leak_node__"), null,
		"leak marker should no longer exist under scene root")
