@tool
extends McpTestSuite

## Tests for InputHandler — input action listing, adding, removing, binding.

var _handler: InputHandler
const TEST_ACTION := "_mcp_test_action"


func suite_name() -> String:
	return "input"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = InputHandler.new()


func suite_teardown() -> void:
	## Clean up any test actions
	if InputMap.has_action(TEST_ACTION):
		InputMap.erase_action(TEST_ACTION)
	var key := "input/%s" % TEST_ACTION
	if ProjectSettings.has_setting(key):
		ProjectSettings.clear(key)
		ProjectSettings.save()


# ----- list_actions -----

func test_list_actions_excludes_builtins_by_default() -> void:
	var result := _handler.list_actions({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "actions")
	assert_has_key(result.data, "count")
	for action in result.data.actions:
		assert_false(action.is_builtin, "Default should exclude ui_* actions")


func test_list_actions_with_builtins() -> void:
	var result := _handler.list_actions({"include_builtin": true})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should have at least the built-in ui_* actions")


func test_list_actions_filters_editor_runtime_actions() -> void:
	## Editor-runtime actions (e.g. spatial_editor/freelook_left) live in
	## InputMap but never appear under input/ in project.godot. Simulate one by
	## adding directly to InputMap without registering a ProjectSettings entry,
	## and confirm list_actions(include_builtin=False) hides it.
	const RUNTIME_ACTION := "_McpTestRuntimeAction"
	if InputMap.has_action(RUNTIME_ACTION):
		InputMap.erase_action(RUNTIME_ACTION)
	InputMap.add_action(RUNTIME_ACTION)
	# Capture-then-tear-down-then-assert: collect listings, then erase the
	# runtime action, then check. Keeps the fixture from leaking past this
	# test if any assertion fails.
	var precondition_in_settings := ProjectSettings.has_setting("input/" + RUNTIME_ACTION)
	var default_names := _action_names(_handler.list_actions({}))
	var full_names := _action_names(_handler.list_actions({"include_builtin": true}))
	InputMap.erase_action(RUNTIME_ACTION)

	assert_false(precondition_in_settings,
		"Precondition: the simulated runtime action must not be in ProjectSettings")
	assert_false(default_names.has(RUNTIME_ACTION),
		"Editor-runtime actions (no input/<name> in project.godot) should be hidden by default")
	assert_true(full_names.has(RUNTIME_ACTION),
		"include_builtin=True should expose every InputMap action, including runtime-only ones")


func test_list_actions_includes_user_authored() -> void:
	## A user-authored action (registered in ProjectSettings via add_action)
	## must appear in the default include_builtin=False listing.
	_handler.add_action({"action": TEST_ACTION})
	var names := _action_names(_handler.list_actions({}))
	_handler.remove_action({"action": TEST_ACTION})
	assert_true(names.has(TEST_ACTION),
		"User-authored action should appear in default listing")


func _action_names(result: Dictionary) -> Array:
	var names: Array = []
	for action in result.data.actions:
		names.append(action.name)
	return names


# ----- add_action -----

func test_add_action_missing_name() -> void:
	var result := _handler.add_action({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_add_and_remove_action() -> void:
	var result := _handler.add_action({"action": TEST_ACTION})
	assert_has_key(result, "data")
	assert_eq(result.data.action, TEST_ACTION)

	## Verify it exists
	assert_true(InputMap.has_action(TEST_ACTION), "Action should exist after adding")

	## Remove it
	var remove_result := _handler.remove_action({"action": TEST_ACTION})
	assert_has_key(remove_result, "data")
	assert_eq(remove_result.data.removed, true)
	assert_false(InputMap.has_action(TEST_ACTION), "Action should not exist after removing")


func test_add_action_duplicate() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.add_action({"action": TEST_ACTION})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_handler.remove_action({"action": TEST_ACTION})


# ----- remove_action -----

func test_remove_action_missing_name() -> void:
	var result := _handler.remove_action({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_remove_action_not_found() -> void:
	var result := _handler.remove_action({"action": "_nonexistent_action_xyz"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- bind_event -----

func test_bind_event_missing_params() -> void:
	var result := _handler.bind_event({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.bind_event({"action": TEST_ACTION})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_bind_event_unknown_action() -> void:
	var result := _handler.bind_event({
		"action": "_nonexistent_action",
		"event_type": "key",
		"keycode": "Space",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_bind_event_unsupported_type() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "unsupported",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_key_event() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "key",
		"keycode": "Space",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.action, TEST_ACTION)
	assert_has_key(result.data, "event")
	assert_eq(result.data.event.type, "key")
	_handler.remove_action({"action": TEST_ACTION})
