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


func test_list_actions_excludes_editor_runtime_namespaces() -> void:
	## InputMap.get_actions() exposes spatial_editor/* and other editor-runtime
	## namespaces alongside user actions. The default filter must drop them
	## so an agent listing actions in a project with zero user-defined
	## actions doesn't see "freelook_left" et al.
	var result := _handler.list_actions({})
	assert_has_key(result, "data")
	for action in result.data.actions:
		var name: String = action.name
		assert_false(name.begins_with("spatial_editor/"),
			"Default list should exclude spatial_editor/* actions, got: %s" % name)
		assert_true(ProjectSettings.has_setting("input/" + name),
			"Default list should only return ProjectSettings-backed actions, got: %s" % name)


func test_list_actions_include_builtin_surfaces_editor_namespaces() -> void:
	## include_builtin=true is the debugging path — it should include
	## ui_* AND any other editor-runtime namespace InputMap exposes.
	var result := _handler.list_actions({"include_builtin": true})
	assert_has_key(result, "data")
	var found_non_user := false
	for action in result.data.actions:
		var name: String = action.name
		if not ProjectSettings.has_setting("input/" + name):
			found_non_user = true
			assert_true(action.is_builtin,
				"Editor-runtime action should be flagged is_builtin: %s" % name)
	## Editor always defines ui_accept etc., so the include path must
	## surface at least one non-user action in any environment.
	assert_true(found_non_user,
		"include_builtin=true should surface at least one non-user action")


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
