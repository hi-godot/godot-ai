@tool
extends RefCounted

## Handles input action listing, creation, removal, and event binding.
## Actions are persisted via ProjectSettings so they survive editor restarts.


func list_actions(params: Dictionary) -> Dictionary:
	var include_builtin: bool = params.get("include_builtin", false)
	## Authoritative source for user-authored actions is the ``[input]``
	## section of ``project.godot``. ``ProjectSettings.has_setting`` is not
	## reliable here because Godot registers ``ui_*`` defaults via
	## ``GLOBAL_DEF_BASIC``, which makes ``has_setting`` return true for
	## them. Reading the file via ``ConfigFile`` distinguishes the user's
	## entries from engine-registered defaults regardless of namespace.
	## See #213.
	var user_authored := _read_user_authored_actions()
	var actions: Array[Dictionary] = []
	for action_name in InputMap.get_actions():
		var name_str := str(action_name)
		var is_user_action := user_authored.has(name_str)
		if not include_builtin and not is_user_action:
			continue
		var events: Array[Dictionary] = []
		for event in InputMap.action_get_events(action_name):
			events.append(_serialize_event(event))
		actions.append({
			"name": name_str,
			"events": events,
			"event_count": events.size(),
			"is_builtin": not is_user_action,
		})
	return {"data": {"actions": actions, "count": actions.size()}}


func _read_user_authored_actions() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load("res://project.godot") != OK:
		return {}
	if not cfg.has_section("input"):
		return {}
	var result: Dictionary = {}
	for key in cfg.get_section_keys("input"):
		result[key] = true
	return result


func add_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var deadzone: float = params.get("deadzone", 0.5)

	if action.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: action")

	if InputMap.has_action(action):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Action '%s' already exists" % action)

	InputMap.add_action(action, deadzone)

	var key := "input/%s" % action
	ProjectSettings.set_setting(key, {
		"deadzone": deadzone,
		"events": [],
	})
	var err := ProjectSettings.save()
	if err != OK:
		InputMap.erase_action(action)
		ProjectSettings.clear(key)
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while adding action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"deadzone": deadzone,
			"undoable": false,
			"reason": "Input actions are saved to project.godot",
		}
	}


func remove_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: action")

	if not InputMap.has_action(action):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Action '%s' not found" % action)

	var key := "input/%s" % action
	var old_setting = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	InputMap.erase_action(action)

	if old_setting != null:
		ProjectSettings.clear(key)
		var err := ProjectSettings.save()
		if err != OK:
			var dz: float = old_setting.get("deadzone", 0.5) if old_setting is Dictionary else 0.5
			InputMap.add_action(action, dz)
			if old_setting is Dictionary:
				for ev in old_setting.get("events", []):
					if ev is InputEvent:
						InputMap.action_add_event(action, ev)
			ProjectSettings.set_setting(key, old_setting)
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
				"Failed to save project settings while removing action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"removed": true,
			"undoable": false,
			"reason": "Input actions are saved to project.godot",
		}
	}


func bind_event(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var event_type: String = params.get("event_type", "")

	if action.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: action")
	if event_type.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: event_type")

	if not InputMap.has_action(action):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Action '%s' not found" % action)

	var event: InputEvent = _create_event(event_type, params)
	if event == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unsupported event_type: %s (use key, mouse_button, or joy_button)" % event_type)

	InputMap.action_add_event(action, event)

	var err := _save_action_events(action)
	if err != OK:
		InputMap.action_erase_event(action, event)
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while binding event to action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"event": _serialize_event(event),
			"undoable": false,
			"reason": "Input bindings are saved to project.godot",
		}
	}


func _create_event(event_type: String, params: Dictionary) -> InputEvent:
	match event_type:
		"key":
			var ev := InputEventKey.new()
			var keycode_str: String = params.get("keycode", "")
			if keycode_str.is_empty():
				return null
			ev.keycode = OS.find_keycode_from_string(keycode_str)
			if ev.keycode == KEY_NONE:
				return null
			ev.ctrl_pressed = params.get("ctrl", false)
			ev.alt_pressed = params.get("alt", false)
			ev.shift_pressed = params.get("shift", false)
			ev.meta_pressed = params.get("meta", false)
			return ev
		"mouse_button":
			var ev := InputEventMouseButton.new()
			var button: int = params.get("button", 0)
			if button <= 0:
				return null
			ev.button_index = button
			return ev
		"joy_button":
			var ev := InputEventJoypadButton.new()
			if not params.has("button"):
				return null
			ev.button_index = int(params.get("button", 0))
			return ev
	return null


func _serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {
			"type": "key",
			"keycode": OS.get_keycode_string(event.keycode),
			"physical_keycode": OS.get_keycode_string(event.physical_keycode),
			"ctrl": event.ctrl_pressed,
			"alt": event.alt_pressed,
			"shift": event.shift_pressed,
			"meta": event.meta_pressed,
		}
	if event is InputEventMouseButton:
		return {
			"type": "mouse_button",
			"button": event.button_index,
		}
	if event is InputEventJoypadButton:
		return {
			"type": "joy_button",
			"button": event.button_index,
		}
	if event is InputEventJoypadMotion:
		return {
			"type": "joy_axis",
			"axis": event.axis,
			"axis_value": event.axis_value,
		}
	return {"type": event.get_class(), "string": str(event)}


func _save_action_events(action: String) -> int:
	var events: Array = []
	for event in InputMap.action_get_events(action):
		events.append(event)
	var key := "input/%s" % action
	var had_setting := ProjectSettings.has_setting(key)
	var old_setting = ProjectSettings.get_setting(key) if had_setting else null
	var deadzone: float = 0.5
	if old_setting is Dictionary:
		deadzone = old_setting.get("deadzone", 0.5)
	ProjectSettings.set_setting(key, {
		"deadzone": deadzone,
		"events": events,
	})
	var err := ProjectSettings.save()
	if err != OK:
		if had_setting:
			ProjectSettings.set_setting(key, old_setting)
		else:
			ProjectSettings.clear(key)
	return err
