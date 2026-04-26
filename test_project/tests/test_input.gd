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


func test_list_actions_default_excludes_spatial_editor() -> void:
	## ``spatial_editor/*`` actions (3D viewport freelook/orbit/pan) live on
	## InputMap but are not in ``project.godot``. They must not surface in the
	## default user-facing list — agents would otherwise mistake them for
	## actions the project author wired up.
	var with_builtin := _handler.list_actions({"include_builtin": true})
	var saw_spatial_editor := false
	for action in with_builtin.data.actions:
		if action.name.begins_with("spatial_editor/"):
			saw_spatial_editor = true
			break
	assert_true(
		saw_spatial_editor,
		"Sanity: editor should expose spatial_editor/* actions when include_builtin=true",
	)
	var result := _handler.list_actions({})
	for action in result.data.actions:
		assert_false(
			action.name.begins_with("spatial_editor/"),
			"Default list leaked spatial_editor action: %s" % action.name,
		)
		assert_false(action.is_builtin, "Default list should expose only user-defined actions")


func test_list_actions_default_returns_user_defined_action() -> void:
	## A user-added action must round-trip through the default (filtered) list.
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.list_actions({})
	var found := false
	for action in result.data.actions:
		if action.name == TEST_ACTION:
			found = true
			assert_false(action.is_builtin, "User-added action must not be flagged as built-in")
			break
	assert_true(found, "User-defined action %s should appear in default list" % TEST_ACTION)
	_handler.remove_action({"action": TEST_ACTION})


func test_list_actions_with_builtins_includes_spatial_editor_when_present() -> void:
	## When asked, the listing surfaces built-in/editor-runtime actions so
	## power users can inspect them. Some Godot 4 editor builds expose
	## actions such as ``spatial_editor/freelook_left``, but this test only
	## asserts the more general contract: include_builtin=true must return at
	## least one action flagged as built-in.
	var result := _handler.list_actions({"include_builtin": true})
	assert_gt(result.data.count, 0)
	var saw_non_user := false
	for action in result.data.actions:
		if action.is_builtin:
			saw_non_user = true
			break
	assert_true(saw_non_user, "include_builtin=true should expose at least one editor-runtime action")


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
