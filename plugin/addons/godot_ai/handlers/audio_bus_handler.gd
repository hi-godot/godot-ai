@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const Serializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")
const ResourceIO := preload("res://addons/godot_ai/utils/resource_io.gd")
const BUS_FIELDS := {
	"volume_db": ["get_bus_volume_db", "set_bus_volume_db"],
	"send": ["get_bus_send", "set_bus_send"],
	"mute": ["is_bus_mute", "set_bus_mute"],
	"solo": ["is_bus_solo", "set_bus_solo"],
	"bypass_effects": ["is_bus_bypassing_effects", "set_bus_bypass_effects"],
}

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


func bus_list(_params: Dictionary) -> Dictionary:
	var buses: Array[Dictionary] = []
	for index in AudioServer.bus_count:
		buses.append(_bus_data(index))
	return {"data": {"buses": buses, "count": buses.size()}}


func _bus_data(index: int) -> Dictionary:
	var data := {"index": index, "name": AudioServer.get_bus_name(index)}
	for key in BUS_FIELDS:
		data[key] = Serializer.serialize(AudioServer.call(BUS_FIELDS[key][0], index))
	var effects: Array[Dictionary] = []
	for effect_index in AudioServer.get_bus_effect_count(index):
		var effect := AudioServer.get_bus_effect(index, effect_index)
		var properties := {}
		for prop in effect.get_property_list():
			if int(prop.usage) & PROPERTY_USAGE_EDITOR and prop.name != "script":
				properties[String(prop.name)] = Serializer.serialize(effect.get(prop.name))
		effects.append({"index": effect_index, "class": effect.get_class(),
			"enabled": AudioServer.is_bus_effect_enabled(index, effect_index), "properties": properties})
	data["effects"] = effects
	return data


func _bus_index(name: String) -> Variant:
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Bus name is required")
	var index := AudioServer.get_bus_index(name)
	if index < 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Audio bus not found: %s" % name)
	return index


func _index(value: Variant, low: int, high: int, label: String) -> Variant:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be an integer" % label)
	if not is_finite(float(value)) or float(value) != floor(float(value)) or value < low or value > high:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be an integer from %d to %d" % [label, low, high])
	return int(value)


func _send_error(send: Variant, index: int) -> Variant:
	if typeof(send) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "send must be a bus name")
	var target := AudioServer.get_bus_index(send)
	if target < 0 or target >= index:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "send must name an existing bus before this bus; Master has no send")
	return null


func _action(label: String) -> void:
	_undo_redo.create_action("MCP: " + label, UndoRedo.MERGE_DISABLE, AudioServer)


func bus_add(params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	if AudioServer.get_bus_index(name) >= 0:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Audio bus already exists: %s" % name)
	var at: Variant = _index(params.get("at_position", -1), -1, AudioServer.bus_count, "at_position")
	if at is Dictionary:
		return at
	if at == -1:
		at = AudioServer.bus_count
	if at == 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Master must remain at index 0")
	var send: Variant = params.get("send", "Master")
	var error: Variant = _send_error(send, at)
	if error != null:
		return error
	_action("Add audio bus %s" % name)
	_undo_redo.add_do_method(AudioServer, "add_bus", at)
	_undo_redo.add_do_method(AudioServer, "set_bus_name", at, name)
	_undo_redo.add_do_method(AudioServer, "set_bus_send", at, send)
	_undo_redo.add_undo_method(AudioServer, "remove_bus", at)
	_undo_redo.commit_action()
	return {"data": {"bus": _bus_data(at), "undoable": true}}


func bus_remove(params: Dictionary) -> Dictionary:
	var index: Variant = _bus_index(params.get("name", ""))
	if index is Dictionary:
		return index
	if index == 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot remove Master")
	var name := AudioServer.get_bus_name(index)
	var references := PackedStringArray()
	for other in AudioServer.bus_count:
		if other == index:
			continue
		if AudioServer.get_bus_send(other) == name:
			references.append("send from " + AudioServer.get_bus_name(other))
		for effect_index in AudioServer.get_bus_effect_count(other):
			var effect := AudioServer.get_bus_effect(other, effect_index)
			if effect is AudioEffectCompressor and effect.sidechain == name:
				references.append("compressor sidechain on " + AudioServer.get_bus_name(other))
	if not references.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Bus %s is referenced by %s; reroute those references before removing it." % [name, ", ".join(references)])
	_action("Remove audio bus %s" % name)
	_undo_redo.add_do_method(AudioServer, "remove_bus", index)
	# Rebuild through native mutations so undo also notifies the editor and autosave.
	_undo_redo.add_undo_method(AudioServer, "add_bus", index)
	_undo_redo.add_undo_method(AudioServer, "set_bus_name", index, name)
	for key in BUS_FIELDS:
		_undo_redo.add_undo_method(AudioServer, BUS_FIELDS[key][1], index, AudioServer.call(BUS_FIELDS[key][0], index))
	for effect_index in AudioServer.get_bus_effect_count(index):
		_undo_redo.add_undo_method(AudioServer, "add_bus_effect", index, AudioServer.get_bus_effect(index, effect_index), effect_index)
		_undo_redo.add_undo_method(AudioServer, "set_bus_effect_enabled", index, effect_index, AudioServer.is_bus_effect_enabled(index, effect_index))
	_undo_redo.commit_action()
	return {"data": {"name": name, "undoable": true}}


func bus_set(params: Dictionary) -> Dictionary:
	var index: Variant = _bus_index(params.get("name", ""))
	if index is Dictionary:
		return index
	var updates := {}
	for key in BUS_FIELDS:
		if not params.has(key):
			continue
		var value: Variant = params[key]
		if key == "send":
			var error: Variant = _send_error(value, index)
			if error != null:
				return error
		elif key == "volume_db":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
				return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "volume_db must be a number")
			if not is_finite(float(value)) or not is_finite(PackedFloat32Array([float(value)])[0]):
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "volume_db must remain finite in native float32 storage")
		elif not value is bool:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a boolean" % key)
		updates[key] = value
	if updates.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide volume_db, send, mute, solo or bypass_effects")
	_action("Set audio bus %s" % AudioServer.get_bus_name(index))
	for key in updates:
		_undo_redo.add_do_method(AudioServer, BUS_FIELDS[key][1], index, updates[key])
		_undo_redo.add_undo_method(AudioServer, BUS_FIELDS[key][1], index, AudioServer.call(BUS_FIELDS[key][0], index))
	_undo_redo.commit_action()
	return {"data": {"bus": _bus_data(index), "undoable": true}}


func _effect_properties(effect: AudioEffect, properties: Dictionary) -> Variant:
	var allowed := {}
	for prop in effect.get_property_list():
		if int(prop.usage) & PROPERTY_USAGE_EDITOR and prop.name != "script":
			allowed[String(prop.name)] = prop.type
	for key in properties:
		if not allowed.has(key):
			return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"No editable effect property '%s' on %s" % [key, effect.get_class()])
		var value: Variant = properties[key]
		if typeof(value) == TYPE_FLOAT and not is_finite(value):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be finite" % key)
		if allowed[key] == TYPE_BOOL and not value is bool:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a boolean" % key)
		if allowed[key] == TYPE_INT and typeof(value) == TYPE_FLOAT and value != floor(value):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be an integer" % key)
	if properties.has("sidechain") and not str(properties.sidechain).is_empty() and AudioServer.get_bus_index(str(properties.sidechain)) < 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "sidechain must name an existing bus or be empty")
	var error: Variant = ResourceHandler._apply_resource_properties(effect, properties)
	if error != null:
		return error
	for key in properties:
		var stored: Variant = effect.get(key)
		if typeof(stored) == TYPE_FLOAT and not is_finite(stored):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must remain finite in native effect storage" % key)
	return null


func bus_effect_add(params: Dictionary) -> Dictionary:
	var index: Variant = _bus_index(params.get("bus", ""))
	if index is Dictionary:
		return index
	var effect_class: String = params.get("effect_class", "")
	if effect_class == "AudioEffect" or not ClassDB.class_exists(effect_class) or not ClassDB.is_parent_class(effect_class, "AudioEffect") or not ClassDB.can_instantiate(effect_class):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "effect_class must be a concrete native AudioEffect class")
	var at: Variant = _index(params.get("at_position", -1), -1, AudioServer.get_bus_effect_count(index), "at_position")
	if at is Dictionary:
		return at
	if at == -1:
		at = AudioServer.get_bus_effect_count(index)
	var enabled: Variant = params.get("enabled", true)
	if not enabled is bool:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "enabled must be a boolean")
	var properties: Variant = params.get("properties", {})
	if not properties is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "properties must be a dictionary")
	var effect := ClassDB.instantiate(effect_class) as AudioEffect
	var error: Variant = _effect_properties(effect, properties)
	if error != null:
		return error
	_action("Add %s to audio bus %s" % [effect_class, AudioServer.get_bus_name(index)])
	_undo_redo.add_do_method(AudioServer, "add_bus_effect", index, effect, at)
	_undo_redo.add_do_method(AudioServer, "set_bus_effect_enabled", index, at, enabled)
	_undo_redo.add_undo_method(AudioServer, "remove_bus_effect", index, at)
	_undo_redo.commit_action()
	return {"data": {"bus": _bus_data(index), "index": at, "undoable": true}}


func _effect_index(params: Dictionary, bus: int) -> Variant:
	if not params.has("index"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: index")
	return _index(params.index, 0, AudioServer.get_bus_effect_count(bus) - 1, "index")


func bus_effect_set(params: Dictionary) -> Dictionary:
	var bus: Variant = _bus_index(params.get("bus", ""))
	if bus is Dictionary:
		return bus
	var index: Variant = _effect_index(params, bus)
	if index is Dictionary:
		return index
	var properties: Variant = params.get("properties", {})
	if not properties is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "properties must be a dictionary")
	if params.has("enabled") and not params.enabled is bool:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "enabled must be a boolean")
	if properties.is_empty() and not params.has("enabled"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Provide properties or enabled")
	var effect := AudioServer.get_bus_effect(bus, index)
	if effect.get_script() != null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "bus_effect_set supports native, unscripted AudioEffects only")
	var updated := effect.duplicate(true) as AudioEffect
	if updated == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not duplicate AudioEffect for validation")
	var error: Variant = _effect_properties(updated, properties)
	if error != null:
		return error
	_action("Set audio bus effect")
	for key in properties:
		# Pathless effects are otherwise guessed into the open scene's history.
		_undo_redo.force_fixed_history()
		_undo_redo.add_do_property(effect, key, updated.get(key))
		_undo_redo.force_fixed_history()
		_undo_redo.add_undo_property(effect, key, effect.get(key))
	if params.has("enabled"):
		_undo_redo.add_do_method(AudioServer, "set_bus_effect_enabled", bus, index, params.enabled)
		_undo_redo.add_undo_method(AudioServer, "set_bus_effect_enabled", bus, index, AudioServer.is_bus_effect_enabled(bus, index))
	_undo_redo.commit_action()
	return {"data": {"bus": _bus_data(bus), "index": index, "undoable": true}}


func bus_effect_remove(params: Dictionary) -> Dictionary:
	var bus: Variant = _bus_index(params.get("bus", ""))
	if bus is Dictionary:
		return bus
	var index: Variant = _effect_index(params, bus)
	if index is Dictionary:
		return index
	var effect := AudioServer.get_bus_effect(bus, index)
	var enabled := AudioServer.is_bus_effect_enabled(bus, index)
	_action("Remove audio bus effect")
	_undo_redo.add_do_method(AudioServer, "remove_bus_effect", bus, index)
	_undo_redo.add_undo_method(AudioServer, "add_bus_effect", bus, effect, index)
	_undo_redo.add_undo_method(AudioServer, "set_bus_effect_enabled", bus, index, enabled)
	_undo_redo.commit_action()
	return {"data": {"bus": AudioServer.get_bus_name(bus), "index": index, "undoable": true}}


func bus_layout_save(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "res://default_bus_layout.tres")
	if path.get_extension().to_lower() not in ["tres", "res"]:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "AudioBusLayout path must end in .tres or .res")
	return ResourceIO.save_to_disk(AudioServer.generate_bus_layout(), path, params.get("overwrite", false),
		"AudioBusLayout", {"reason": "Exports a snapshot; does not change the active layout or project default"}, _connection)
