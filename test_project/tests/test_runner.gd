@tool
extends McpTestSuite

const TestHandler := preload("res://addons/godot_ai/handlers/test_handler.gd")

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


class _FilterSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_filter"
	func test_excluded_flaky_case() -> void:
		assert_true(false, "excluded test body should not run")
	func test_kept_case() -> void:
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
		if not Engine.is_editor_hint():
			return
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return
		var leak := Node3D.new()
		leak.name = "__runner_leak_node__"
		scene_root.add_child(leak)
		assert_true(true)


class _TrackedAllocationSuite extends McpTestSuite:
	var tracked_object: Object
	var tracked_node: Node
	func suite_name() -> String: return "inner_tracked"
	func test_tracked_allocations() -> void:
		tracked_object = track(Object.new())
		tracked_node = track(Node.new())
		assert_true(is_instance_valid(tracked_object))
		assert_true(is_instance_valid(tracked_node))


class _ExpectedScriptErrorSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_expected_script_error"
	func test_expected_script_error_does_not_abort() -> void:
		expect_script_error_containing("Parse Error: Expected conditional expression after \"if\".")
		var script := GDScript.new()
		script.source_code = "extends Node\n\nfunc _ready() -> void:\n\tif\n"
		var err := script.reload()
		assert_ne(err, OK, "invalid GDScript should fail to compile")


class _FailedSetupSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_failed_setup"
	func suite_setup(_ctx: Dictionary) -> void:
		fail_setup("arena.gd cannot instantiate in @tool scope")
	func test_a() -> void:
		assert_true(true)  # never runs
	func test_b() -> void:
		assert_true(true)  # never runs


class _SkippedSetupSuite extends McpTestSuite:
	func suite_name() -> String: return "inner_skipped_setup"
	func suite_setup(_ctx: Dictionary) -> void:
		skip_suite("no scene open")
	func test_a() -> void:
		assert_true(true)  # never runs
	func test_b() -> void:
		assert_true(true)  # never runs


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


func test_exclude_test_name_skips_matching_tests() -> void:
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_FilterSuite.new()], "", "", {}, false, "excluded")
	assert_eq(result.passed, 1)
	assert_eq(result.failed, 0)
	assert_eq(result.skipped, 1)


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


# ----- suite-level failure (issue #75) -----

func test_fail_setup_emits_one_suite_level_failure() -> void:
	## A suite that calls fail_setup() in suite_setup should emit ONE result
	## (not N per-test "0 assertions" results) and skip individual tests.
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_FailedSetupSuite.new()])
	assert_eq(result.failed, 1, "exactly one suite-level failure")
	assert_eq(result.passed, 0, "individual tests must not run")
	assert_eq(result.total, 1, "one result, not per-test results")
	assert_has_key(result, "failures")
	var failure: Dictionary = result.failures[0]
	assert_eq(failure.test, "<suite_setup>")
	assert_contains(failure.message, "arena.gd cannot instantiate")
	assert_contains(failure.message, "subsequent tests not run")


func test_skip_suite_emits_one_suite_level_skip() -> void:
	## skip_suite() is the no-precondition counterpart to fail_setup().
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_SkippedSetupSuite.new()])
	assert_eq(result.skipped, 1, "exactly one suite-level skip")
	assert_eq(result.failed, 0)
	assert_eq(result.passed, 0)
	assert_eq(result.total, 1)


func test_failed_setup_does_not_run_other_suites_tests() -> void:
	## Mixed: a failing suite should not poison the runner — subsequent
	## suites must still execute normally.
	var runner := McpTestRunner.new()
	var result := runner.run_suites([_FailedSetupSuite.new(), _PassingSuite.new()])
	assert_eq(result.failed, 1, "failing suite's suite-level failure")
	assert_eq(result.passed, 1, "passing suite still ran")
	assert_eq(result.total, 2)


# ----- leaked-node cleanup -----

func test_leaked_nodes_are_cleaned_up_after_suite() -> void:
	var scene_root := _edited_scene_root()
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


func test_tracked_allocations_are_freed_after_each_test() -> void:
	var runner := McpTestRunner.new()
	var suite := _TrackedAllocationSuite.new()

	var result := runner.run_suites([suite])

	assert_eq(result.failed, 0)
	assert_false(is_instance_valid(suite.tracked_object), "tracked plain Object should be freed")
	assert_false(is_instance_valid(suite.tracked_node), "tracked out-of-tree Node should be freed")


func test_expected_script_error_does_not_fail_test() -> void:
	if skip_on_godot_lt("4.5", "Logger subclass only exists on Godot 4.5+"):
		return
	var runner := McpTestRunner.new()
	expect_script_error_containing("Parse Error: Expected conditional expression after \"if\".")
	var result := runner.run_suites([_ExpectedScriptErrorSuite.new()])

	assert_eq(result.failed, 0, "expected script errors should be filtered")
	assert_eq(result.passed, 1)


func test_run_tests_annotates_edited_scene() -> void:
	## #635: run_tests surfaces the edited scene so main-scene-assuming suites'
	## phantom failures are attributable. Verify the annotation is populated.
	var handler := TestHandler.new(null, null)
	var results := {"failed": 0}
	handler._annotate_edited_scene(results)
	assert_has_key(results, "edited_scene")
	var scene_root := EditorInterface.get_edited_scene_root()
	var expected := scene_root.scene_file_path if scene_root else ""
	assert_eq(results.edited_scene, expected)
	## Tests run with the main scene open, so no warning should be emitted even
	## though failed=0 here.
	assert_false(results.has("scene_warning"),
		"no warning when edited scene is the main scene")


func test_annotate_scene_warns_on_mismatch_with_failures() -> void:
	## #635: deterministically exercise BOTH the warn and no-warn branches by
	## overriding application/run/main_scene to a path that cannot equal the
	## edited scene, then restoring it. (Reading the live main_scene and
	## branching the assertion on it — as an earlier draft did — is tautological:
	## in CI the main scene is open, so only the suppression branch ever ran.)
	var handler := TestHandler.new(null, null)
	var key := "application/run/main_scene"
	var had_setting := ProjectSettings.has_setting(key)
	var original = ProjectSettings.get_setting(key) if had_setting else null
	var fake_main := "res://__mcp_nonexistent_main__.tscn"

	# mismatch + failures => warning naming the mismatched main scene
	ProjectSettings.set_setting(key, fake_main)
	var failing := {"failed": 3}
	handler._annotate_edited_scene(failing)
	# mismatch + zero failures => no warning
	var clean := {"failed": 0}
	handler._annotate_edited_scene(clean)

	# restore BEFORE asserting so a failed assert can't leak the override
	if had_setting:
		ProjectSettings.set_setting(key, original)
	else:
		ProjectSettings.clear(key)

	assert_true(failing.has("scene_warning"),
		"edited scene != main_scene with failures must warn")
	assert_true(str(failing.get("scene_warning", "")).contains(fake_main),
		"warning should name the mismatched main scene")
	assert_false(clean.has("scene_warning"),
		"mismatch but zero failures must not warn")


static func _edited_scene_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()
