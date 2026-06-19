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


func test_add_action_rejects_deadzone_below_zero() -> void:
	## Issue #439: callers (LLMs) pass deadzone values outside [0, 1].
	## Reject explicitly with VALUE_OUT_OF_RANGE so retries can converge.
	var result := _handler.add_action({"action": TEST_ACTION, "deadzone": -0.1})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_false(InputMap.has_action(TEST_ACTION), "Action must not be created on validation failure")


func test_add_action_rejects_deadzone_above_one() -> void:
	var result := _handler.add_action({"action": TEST_ACTION, "deadzone": 1.5})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_false(InputMap.has_action(TEST_ACTION), "Action must not be created on validation failure")


func test_add_action_accepts_boundary_deadzones() -> void:
	var result := _handler.add_action({"action": TEST_ACTION, "deadzone": 0.0})
	assert_has_key(result, "data")
	_handler.remove_action({"action": TEST_ACTION})
	result = _handler.add_action({"action": TEST_ACTION, "deadzone": 1.0})
	assert_has_key(result, "data")
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


func test_bind_event_key_missing_keycode() -> void:
	## Issue #439: was collapsed into "Unsupported event_type" — now reports
	## the actual missing param so retries can converge.
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "key",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_key_invalid_keycode() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "key",
		"keycode": "NotARealKey",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_mouse_button_missing_button() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "mouse_button",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_mouse_button_zero_button() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "mouse_button",
		"button": 0,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_joy_axis_missing_axis() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "joy_axis",
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_joy_axis_null_axis() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "joy_axis",
		"axis": null,
	})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)
	_handler.remove_action({"action": TEST_ACTION})


func test_bind_event_unknown_action_message_suggests_add_action() -> void:
	## The error string should point the caller at the fix so they don't loop.
	var result := _handler.bind_event({
		"action": "_nope_xyz",
		"event_type": "key",
		"keycode": "Space",
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "add_action")


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


func test_bind_key_event_matches_all_keyboard_devices() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "key",
		"keycode": "Space",
	})
	assert_has_key(result, "data")

	var events := InputMap.action_get_events(TEST_ACTION)
	assert_eq(events.size(), 1)
	var stored_event = events[0]
	assert_true(stored_event is InputEventKey)
	assert_eq(stored_event.device, -1)

	var default_device_event := InputEventKey.new()
	default_device_event.keycode = KEY_SPACE
	default_device_event.pressed = true
	assert_true(InputMap.event_is_action(default_device_event, TEST_ACTION))

	var explicit_device_event := InputEventKey.new()
	explicit_device_event.keycode = KEY_SPACE
	explicit_device_event.device = 1
	explicit_device_event.pressed = true
	assert_true(InputMap.event_is_action(explicit_device_event, TEST_ACTION))

	_handler.remove_action({"action": TEST_ACTION})


func test_bind_mouse_button_event_matches_all_mouse_devices() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "mouse_button",
		"button": MOUSE_BUTTON_LEFT,
	})
	assert_has_key(result, "data")

	var events := InputMap.action_get_events(TEST_ACTION)
	assert_eq(events.size(), 1)
	var stored_event = events[0]
	assert_true(stored_event is InputEventMouseButton)
	assert_eq(stored_event.device, -1)

	var default_device_event := InputEventMouseButton.new()
	default_device_event.button_index = MOUSE_BUTTON_LEFT
	default_device_event.pressed = true
	assert_true(InputMap.event_is_action(default_device_event, TEST_ACTION))

	var explicit_device_event := InputEventMouseButton.new()
	explicit_device_event.button_index = MOUSE_BUTTON_LEFT
	explicit_device_event.device = 1
	explicit_device_event.pressed = true
	assert_true(InputMap.event_is_action(explicit_device_event, TEST_ACTION))

	_handler.remove_action({"action": TEST_ACTION})


func test_bind_joy_axis_event() -> void:
	_handler.add_action({"action": TEST_ACTION})
	var result := _handler.bind_event({
		"action": TEST_ACTION,
		"event_type": "joy_axis",
		"axis": JOY_AXIS_LEFT_X,
		"axis_value": -1.0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.action, TEST_ACTION)
	assert_has_key(result.data, "event")
	assert_eq(result.data.event.type, "joy_axis")
	assert_eq(result.data.event.axis, JOY_AXIS_LEFT_X)
	assert_eq(result.data.event.axis_value, -1.0)
	_handler.remove_action({"action": TEST_ACTION})
