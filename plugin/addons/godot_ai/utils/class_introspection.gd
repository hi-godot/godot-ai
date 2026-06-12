@tool
extends RefCounted

## Builds stable, JSON-safe metadata for any class registered in ClassDB.

const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

const DEFAULT_SECTIONS := ["properties", "methods", "signals", "enums", "constants"]
const KNOWN_SECTIONS := ["properties", "methods", "signals", "enums", "constants", "inheritors"]
const MAX_DEFAULT_ITEMS := 100


static func build(type_name: String, options: Dictionary = {}) -> Dictionary:
	var sections := _sections(options.get("sections", DEFAULT_SECTIONS))
	var include_inherited := bool(options.get("include_inherited", false))
	var include_inheritors := bool(options.get("include_inheritors", false))
	var offset := max(0, int(options.get("offset", 0)))
	var limit := int(options.get("limit", MAX_DEFAULT_ITEMS))
	if limit < 0:
		limit = MAX_DEFAULT_ITEMS
	var can_instantiate := ClassDB.can_instantiate(type_name)

	var data := {
		"class_name": type_name,
		"engine_version": Engine.get_version_info().get("string", ""),
		"parent_class": str(ClassDB.get_parent_class(type_name)),
		"inheritance_chain": _inheritance_chain(type_name),
		"can_instantiate": can_instantiate,
		"is_singleton": Engine.has_singleton(type_name),
		"include_inherited": include_inherited,
		"offset": offset,
		"limit": limit,
	}
	if include_inheritors or sections.has("inheritors"):
		_add_paged(data, "inheritor", "inheritors", _inheritors(type_name, false), offset, limit)
		_add_paged(
			data,
			"concrete_inheritor",
			"concrete_inheritors",
			_inheritors(type_name, true),
			offset,
			limit
		)
	if sections.has("properties"):
		_add_paged(data, "property", "properties", _properties(type_name, include_inherited), offset, limit)
	if sections.has("methods"):
		_add_paged(data, "method", "methods", _methods(type_name, include_inherited), offset, limit)
	if sections.has("signals"):
		_add_paged(data, "signal", "signals", _signals(type_name, include_inherited), offset, limit)
	if sections.has("enums"):
		_add_paged(data, "enum", "enums", _enums(type_name, include_inherited), offset, limit)
	if sections.has("constants"):
		_add_paged(
			data,
			"constant",
			"constants",
			_unscoped_constants(type_name, include_inherited),
			offset,
			limit
		)
	return data


static func validate_sections(raw_sections: Variant) -> Dictionary:
	var sections := _sections(raw_sections)
	var invalid: Array[String] = []
	for section in sections:
		if not KNOWN_SECTIONS.has(section):
			invalid.append(section)
	return {"sections": sections, "invalid": invalid}


static func _inheritance_chain(type_name: String) -> Array[String]:
	var chain: Array[String] = []
	var current := type_name
	while not current.is_empty():
		chain.append(current)
		current = str(ClassDB.get_parent_class(current))
	return chain


static func _sections(raw_sections: Variant) -> Array[String]:
	var result: Array[String] = []
	var values: Array = []
	if raw_sections is String:
		values = raw_sections.split(",", false)
	elif raw_sections is Array:
		values = raw_sections
	else:
		values = DEFAULT_SECTIONS
	for raw_section in values:
		var section := str(raw_section).strip_edges().to_lower()
		if not section.is_empty() and not result.has(section):
			result.append(section)
	if result.is_empty():
		result.assign(DEFAULT_SECTIONS)
	return result


static func _add_paged(
	data: Dictionary,
	singular: String,
	key: String,
	items: Array,
	offset: int,
	limit: int
) -> void:
	var end := items.size() if limit == 0 else min(items.size(), offset + limit)
	var page: Array = []
	if offset < items.size():
		page = items.slice(offset, end)
	data[key] = page
	data["%s_count" % singular] = items.size()
	data["%s_returned_count" % singular] = page.size()


static func _inheritors(type_name: String, concrete_only: bool) -> Array[String]:
	var result: Array[String] = []
	for inheritor in ClassDB.get_inheriters_from_class(type_name):
		var inheritor_name := str(inheritor)
		if concrete_only and not ClassDB.can_instantiate(inheritor_name):
			continue
		result.append(inheritor_name)
	result.sort()
	return result


static func _properties(type_name: String, include_inherited: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_prop in ClassDB.class_get_property_list(type_name, not include_inherited):
		var prop: Dictionary = raw_prop
		var usage := int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var prop_name := str(prop.get("name", ""))
		result.append({
			"name": prop_name,
			"type": type_string(int(prop.get("type", TYPE_NIL))),
			"class_name": str(prop.get("class_name", "")),
			"hint": int(prop.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(prop.get("hint_string", "")),
			"usage": usage,
			"default": VariantSerializer.serialize(
				ClassDB.class_get_property_default_value(type_name, prop_name)
			),
		})
	result.sort_custom(func(a, b): return a.name < b.name)
	return result


static func _methods(type_name: String, include_inherited: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_method in ClassDB.class_get_method_list(type_name, not include_inherited):
		var method: Dictionary = raw_method
		var args: Array[Dictionary] = []
		for raw_arg in method.get("args", []):
			args.append(_argument_info(raw_arg))
		var defaults: Array = []
		for value in method.get("default_args", []):
			defaults.append(VariantSerializer.serialize(value))
		result.append({
			"name": str(method.get("name", "")),
			"arguments": args,
			"default_arguments": defaults,
			"return": _argument_info(method.get("return", {})),
			"flags": int(method.get("flags", 0)),
		})
	result.sort_custom(func(a, b): return a.name < b.name)
	return result


static func _signals(type_name: String, include_inherited: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_signal in ClassDB.class_get_signal_list(type_name, not include_inherited):
		var signal_info: Dictionary = raw_signal
		var args: Array[Dictionary] = []
		for raw_arg in signal_info.get("args", []):
			args.append(_argument_info(raw_arg))
		var defaults: Array = []
		for value in signal_info.get("default_args", []):
			defaults.append(VariantSerializer.serialize(value))
		result.append({
			"name": str(signal_info.get("name", "")),
			"arguments": args,
			"default_arguments": defaults,
			"flags": int(signal_info.get("flags", 0)),
		})
	result.sort_custom(func(a, b): return a.name < b.name)
	return result


static func _argument_info(raw_info: Variant) -> Dictionary:
	var info: Dictionary = raw_info if raw_info is Dictionary else {}
	return {
		"name": str(info.get("name", "")),
		"type": type_string(int(info.get("type", TYPE_NIL))),
		"class_name": str(info.get("class_name", "")),
		"hint": int(info.get("hint", PROPERTY_HINT_NONE)),
		"hint_string": str(info.get("hint_string", "")),
		"usage": int(info.get("usage", 0)),
	}


static func _enums(type_name: String, include_inherited: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var enum_names: Array[String] = []
	for enum_name in ClassDB.class_get_enum_list(type_name, not include_inherited):
		enum_names.append(str(enum_name))
	enum_names.sort()
	for enum_name in enum_names:
		var values: Array[Dictionary] = []
		for constant_name in ClassDB.class_get_enum_constants(type_name, enum_name, not include_inherited):
			values.append({
				"name": str(constant_name),
				"value": ClassDB.class_get_integer_constant(type_name, constant_name),
			})
		values.sort_custom(func(a, b): return a.name < b.name)
		result.append({
			"name": enum_name,
			"is_bitfield": ClassDB.is_class_enum_bitfield(type_name, enum_name, not include_inherited),
			"values": values,
		})
	return result


static func _unscoped_constants(type_name: String, include_inherited: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for constant_name in ClassDB.class_get_integer_constant_list(type_name, not include_inherited):
		var enum_name := str(
			ClassDB.class_get_integer_constant_enum(type_name, constant_name, not include_inherited)
		)
		if not enum_name.is_empty():
			continue
		result.append({
			"name": str(constant_name),
			"value": ClassDB.class_get_integer_constant(type_name, constant_name),
		})
	result.sort_custom(func(a, b): return a.name < b.name)
	return result
