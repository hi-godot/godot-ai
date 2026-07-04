@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

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
	var seen := {}
	for action_name in InputMap.get_actions():
		var name_str := str(action_name)
		var is_user_action := user_authored.has(name_str)
		if not include_builtin and not is_user_action:
			continue
		seen[name_str] = true
		var events: Array[Dictionary] = []
		for event in InputMap.action_get_events(action_name):
			events.append(_serialize_event(event))
		actions.append({
			"name": name_str,
			"events": events,
			"event_count": events.size(),
			"is_builtin": not is_user_action,
			"loaded_in_input_map": true,
		})
	for action_name in user_authored.keys():
		var name_str := str(action_name)
		if seen.has(name_str):
			continue
		var setting: Dictionary = user_authored.get(name_str, {})
		var events: Array[Dictionary] = []
		for event in setting.get("events", []):
			if event is InputEvent:
				events.append(_serialize_event(event))
			else:
				events.append({"type": type_string(typeof(event)), "string": str(event)})
		actions.append({
			"name": name_str,
			"events": events,
			"event_count": events.size(),
			"is_builtin": false,
			"loaded_in_input_map": false,
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
		var value = cfg.get_value("input", key, {})
		result[key] = value if value is Dictionary else {}
	return result


func add_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var deadzone: float = params.get("deadzone", 0.5)

	if action.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: action")

	var deadzone_error := _validate_deadzone(deadzone)
	if deadzone_error.has("error"):
		return deadzone_error

	if InputMap.has_action(action):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Action '%s' already exists" % action)

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
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while adding action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"deadzone": deadzone,
			"undoable": false,
			"reason": "Input actions are saved to project.godot",
		}
	}


func ensure_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var deadzone: float = params.get("deadzone", 0.5)

	if action.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: action")

	var deadzone_error := _validate_deadzone(deadzone)
	if deadzone_error.has("error"):
		return deadzone_error

	var result := _ensure_action_state(action, deadzone)
	if result.has("error"):
		return result
	return {"data": result}


func remove_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: action")

	var key := "input/%s" % action
	var was_loaded := InputMap.has_action(action)
	var old_setting = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null

	## An action can live in the editor process's InputMap, in project.godot,
	## or both. Actions persisted by a previous editor session exist only on
	## disk (`loaded_in_input_map: false` in list_actions) — those must still
	## be removable. #632
	if not was_loaded and old_setting == null:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Action '%s' not found" % action)

	if was_loaded:
		InputMap.erase_action(action)

	if old_setting != null:
		ProjectSettings.clear(key)
		var err := ProjectSettings.save()
		if err != OK:
			if was_loaded:
				var dz: float = old_setting.get("deadzone", 0.5) if old_setting is Dictionary else 0.5
				InputMap.add_action(action, dz)
				if old_setting is Dictionary:
					for ev in old_setting.get("events", []):
						if ev is InputEvent:
							InputMap.action_add_event(action, ev)
			ProjectSettings.set_setting(key, old_setting)
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
				"Failed to save project settings while removing action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"removed": true,
			"was_loaded": was_loaded,
			"undoable": false,
			"reason": "Input actions are saved to project.godot",
		}
	}


func bind_event(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var event_type: String = params.get("event_type", "")

	if action.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: action")
	if event_type.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: event_type")

	if not InputMap.has_action(action):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Action '%s' not found. Call input_map_manage(op='add_action', params={action: '%s'}) first." % [action, action])

	var event_or_error = _create_event(event_type, params)
	if event_or_error is Dictionary:
		return event_or_error
	var event: InputEvent = event_or_error

	InputMap.action_add_event(action, event)

	var err := _save_action_events(action)
	if err != OK:
		InputMap.action_erase_event(action, event)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while binding event to action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"event": _serialize_event(event),
			"undoable": false,
			"reason": "Input bindings are saved to project.godot",
		}
	}


func ensure_binding(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	var event_type: String = params.get("event_type", "")
	var deadzone: float = params.get("deadzone", 0.5)

	if action.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: action")
	if event_type.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: event_type")

	var deadzone_error := _validate_deadzone(deadzone)
	if deadzone_error.has("error"):
		return deadzone_error

	var event_or_error = _create_event(event_type, params)
	if event_or_error is Dictionary:
		return event_or_error
	var event: InputEvent = event_or_error

	var ensured := _ensure_action_state(action, deadzone)
	if ensured.has("error"):
		return ensured

	for existing in InputMap.action_get_events(action):
		if _events_match(existing, event):
			return {
				"data": {
					"action": action,
					"event": _serialize_event(existing),
					"already_bound": true,
					"action_created": ensured.get("created", false),
					"undoable": false,
					"reason": "Input binding already exists",
				}
			}

	InputMap.action_add_event(action, event)
	var err := _save_action_events(action)
	if err != OK:
		InputMap.action_erase_event(action, event)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings while binding event to action '%s': %s (error %d)" % [action, error_string(err), err])

	return {
		"data": {
			"action": action,
			"event": _serialize_event(event),
			"already_bound": false,
			"action_created": ensured.get("created", false),
			"undoable": false,
			"reason": "Input bindings are saved to project.godot",
		}
	}


func _validate_deadzone(deadzone: float) -> Dictionary:
	if deadzone < 0.0 or deadzone > 1.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"deadzone must be in [0.0, 1.0] (got %s). Typical values are 0.2-0.5; default is 0.5." % deadzone)
	return {}


func _ensure_action_state(action: String, deadzone: float) -> Dictionary:
	var key := "input/%s" % action
	var user_authored := _read_user_authored_actions()
	var existed_in_input_map := InputMap.has_action(action)
	var existed_in_project := user_authored.has(action) or ProjectSettings.has_setting(key)
	var old_setting = user_authored.get(action, null) if user_authored.has(action) else null
	if old_setting == null and ProjectSettings.has_setting(key):
		old_setting = ProjectSettings.get_setting(key)

	if not existed_in_input_map:
		var dz := deadzone
		if old_setting is Dictionary:
			dz = float(old_setting.get("deadzone", deadzone))
		InputMap.add_action(action, dz)
		if old_setting is Dictionary:
			for ev in old_setting.get("events", []):
				if ev is InputEvent:
					InputMap.action_add_event(action, ev)

	if not existed_in_project:
		var err := _save_action_events(action)
		if err != OK:
			if not existed_in_input_map:
				InputMap.erase_action(action)
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
				"Failed to save project settings while ensuring action '%s': %s (error %d)" % [action, error_string(err), err])

	var stored_deadzone := deadzone
	if ProjectSettings.has_setting(key):
		var stored = ProjectSettings.get_setting(key)
		if stored is Dictionary:
			stored_deadzone = float(stored.get("deadzone", deadzone))
	return {
		"action": action,
		"deadzone": stored_deadzone,
		"created": not existed_in_input_map and not existed_in_project,
		"already_exists": existed_in_input_map or existed_in_project,
		"loaded_in_input_map": true,
		"persisted": true,
		"undoable": false,
		"reason": "Input actions are saved to project.godot",
	}


## Returns an InputEvent on success, or a Dictionary error on failure.
## Caller must check ``result is Dictionary`` before treating it as an event.
func _create_event(event_type: String, params: Dictionary):
	match event_type:
		"key":
			var ev := InputEventKey.new()
			var keycode_str: String = params.get("keycode", "")
			if keycode_str.is_empty():
				return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
					"event_type='key' requires keycode (e.g. 'Space', 'A', 'Enter', 'Escape', 'F1').")
			ev.keycode = OS.find_keycode_from_string(keycode_str)
			if ev.keycode == KEY_NONE:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
					"Invalid keycode '%s'. Use Godot keycode names like 'A', 'Space', 'Enter', 'Escape', 'F1', 'Left', 'Right'." % keycode_str)
			ev.ctrl_pressed = params.get("ctrl", false)
			ev.alt_pressed = params.get("alt", false)
			ev.shift_pressed = params.get("shift", false)
			ev.meta_pressed = params.get("meta", false)
			ev.device = -1
			return ev
		"mouse_button":
			if not params.has("button"):
				return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
					"event_type='mouse_button' requires button (1=left, 2=right, 3=middle, 4=wheel up, 5=wheel down).")
			var button: int = int(params.get("button", 0))
			if button <= 0:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
					"mouse_button button must be > 0 (got %d). Use 1=left, 2=right, 3=middle, 4=wheel up, 5=wheel down." % button)
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			ev.device = -1
			return ev
		"joy_button":
			if not params.has("button"):
				return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
					"event_type='joy_button' requires button (JoyButton index, e.g. 0=A/Cross, 1=B/Circle).")
			var ev := InputEventJoypadButton.new()
			ev.button_index = int(params.get("button", 0))
			return ev
		"joy_axis":
			var axis_param = params.get("axis", null)
			if axis_param == null:
				return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
					"event_type='joy_axis' requires axis (JoyAxis index, e.g. 0=left stick X, 1=left stick Y).")
			var axis: int
			match typeof(axis_param):
				TYPE_INT:
					axis = axis_param
				TYPE_FLOAT:
					if axis_param != floor(axis_param):
						return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
							"joy_axis axis must be an integer JoyAxis index (got %s)." % str(axis_param))
					axis = int(axis_param)
				TYPE_STRING:
					var axis_text := str(axis_param)
					if not axis_text.is_valid_int():
						return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
							"joy_axis axis must be an integer JoyAxis index (got '%s')." % axis_text)
					axis = int(axis_text)
				_:
					return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
						"joy_axis axis must be an integer JoyAxis index (got %s)." % type_string(typeof(axis_param)))
			var ev := InputEventJoypadMotion.new()
			ev.axis = axis
			ev.axis_value = float(params.get("axis_value", 1.0))
			return ev
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
		"Unsupported event_type: '%s'. Use 'key', 'mouse_button', 'joy_button', or 'joy_axis'." % event_type)


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


func _events_match(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		return _key_events_match(a as InputEventKey, b as InputEventKey)
	return _serialize_event(a) == _serialize_event(b)


func _key_events_match(a: InputEventKey, b: InputEventKey) -> bool:
	if a.ctrl_pressed != b.ctrl_pressed:
		return false
	if a.alt_pressed != b.alt_pressed:
		return false
	if a.shift_pressed != b.shift_pressed:
		return false
	if a.meta_pressed != b.meta_pressed:
		return false
	var a_codes := [a.keycode, a.physical_keycode]
	var b_codes := [b.keycode, b.physical_keycode]
	for a_code in a_codes:
		if int(a_code) == KEY_NONE:
			continue
		for b_code in b_codes:
			if int(b_code) != KEY_NONE and int(a_code) == int(b_code):
				return true
	return false


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
	elif InputMap.has_action(action):
		deadzone = InputMap.action_get_deadzone(action)
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
