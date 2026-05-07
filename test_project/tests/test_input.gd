@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const InputHandler := preload("res://addons/godot_ai/handlers/input_handler.gd")

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
		assert_false(action.is_builtin, "Default should only return user-authored actions")
		## Cross-check: the action must actually exist in project.godot.
		assert_true(ProjectSettings.has_setting("input/" + action.name),
			"Default-filtered action should be authored in project.godot: %s" % action.name)


func test_list_actions_with_builtins() -> void:
	var result := _handler.list_actions({"include_builtin": true})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should have at least the built-in ui_* actions")


func test_list_actions_hides_editor_internal_namespaces() -> void:
	## Bug #213: the previous ``begins_with("ui_")`` filter let editor-runtime
	## actions like ``spatial_editor/freelook_left`` leak through on the
	## default (``include_builtin=False``) path. Cross-check that the new
	## "must exist in project.godot" filter hides them.
	##
	## The test project's project.godot has no ``[input]`` section so the
	## default-filtered list is empty — comparing against the full
	## ``include_builtin=true`` count is what proves the filter is doing
	## work, not just iterating zero entries.
	var with_builtin := _handler.list_actions({"include_builtin": true})
	var default := _handler.list_actions({})
	assert_has_key(with_builtin, "data")
	assert_has_key(default, "data")
	assert_true(with_builtin.data.count > default.data.count,
		"include_builtin=true must surface entries the default filter hides")
	for action in default.data.actions:
		assert_false(str(action.name).begins_with("spatial_editor/"),
			"Editor-internal spatial_editor/* must not appear in default list")
		assert_false(str(action.name).begins_with("ui_"),
			"Built-in ui_* must not appear in default list")


# ----- add_action -----

func test_add_action_missing_name() -> void:
	var result := _handler.add_action({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


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
	assert_is_error(result)
	_handler.remove_action({"action": TEST_ACTION})


# ----- remove_action -----

func test_remove_action_missing_name() -> void:
	var result := _handler.remove_action({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_remove_action_not_found() -> void:
	var result := _handler.remove_action({"action": "_nonexistent_action_xyz"})
	assert_is_error(result)


# ----- bind_event -----

func test_bind_event_missing_params() -> void:
	var result := _handler.bind_event({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)

	result = _handler.bind_event({"action": TEST_ACTION})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_bind_event_unknown_action() -> void:
	var result := _handler.bind_event({
		"action": "_nonexistent_action",
		"event_type": "key",
		"keycode": "Space",
	})
	assert_is_error(result)


func test_bind_event_unsupported_type() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "unsupported",
	})
	assert_is_error(result)
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
