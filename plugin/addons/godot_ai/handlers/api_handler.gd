@tool
extends RefCounted

## Read-only access to version-correct Godot class metadata.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ClassIntrospection := preload("res://addons/godot_ai/utils/class_introspection.gd")
const FuzzySuggestions := preload("res://addons/godot_ai/utils/fuzzy_suggestions.gd")

func get_class_info(params: Dictionary) -> Dictionary:
	var requested_class: String = params.get("class_name", "")
	if requested_class.is_empty():
		return ErrorCodes.make(
			ErrorCodes.MISSING_REQUIRED_PARAM,
			"Missing required param: class_name"
		)
	if not ClassDB.class_exists(requested_class):
		var script_class := _global_script_class(requested_class)
		if not script_class.is_empty():
			return _script_class_error(requested_class, script_class)
		return _unknown_class_error(requested_class)
	if params.has("limit") and int(params.get("limit")) < 0:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"limit must be >= 0; use limit=0 only when an unlimited section is needed"
		)
	var section_check := ClassIntrospection.validate_sections(
		params.get("sections", ClassIntrospection.DEFAULT_SECTIONS)
	)
	if not section_check.invalid.is_empty():
		return _invalid_sections_error(section_check.invalid)
	return {"data": ClassIntrospection.build(requested_class, params)}


static func _unknown_class_error(requested_class: String) -> Dictionary:
	var suggestions := _suggest_classes(requested_class)
	var message := "Unknown Godot class: %s" % requested_class
	if not suggestions.is_empty():
		message += ". Did you mean: %s?" % ", ".join(suggestions)
	var result := ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, message)
	result["error"]["data"] = {"suggestions": suggestions}
	return result


static func _suggest_classes(requested_class: String) -> Array[String]:
	return FuzzySuggestions.rank(requested_class, ClassDB.get_class_list())


static func _global_script_class(requested_class: String) -> Dictionary:
	for raw_info in ProjectSettings.get_global_class_list():
		var info: Dictionary = raw_info
		if info.get("class", "") == requested_class:
			return info
	return {}


static func _script_class_error(requested_class: String, script_class: Dictionary) -> Dictionary:
	var path := str(script_class.get("path", ""))
	var base := str(script_class.get("base", ""))
	var message := (
		"%s is a project script class, not a ClassDB class. "
		+ "Use script_manage(op=\"find_symbols\", params={\"path\": \"%s\"}) for script symbols."
	) % [requested_class, path]
	var result := ErrorCodes.make(ErrorCodes.WRONG_TYPE, message)
	result["error"]["data"] = {
		"script_class": true,
		"class_name": requested_class,
		"base_class": base,
		"path": path,
	}
	return result


static func _invalid_sections_error(invalid_sections: Array[String]) -> Dictionary:
	var suggestions := {}
	for section in invalid_sections:
		suggestions[section] = FuzzySuggestions.rank(
			section,
			ClassIntrospection.SUGGESTABLE_SECTION_TOKENS,
			3,
			0.3
		)
	var message := "Unknown class-info section(s): %s. Valid sections: %s (or \"all\" for all documentation sections; \"inheritors\" must be requested by name)" % [
		", ".join(invalid_sections),
		", ".join(ClassIntrospection.KNOWN_SECTIONS),
	]
	var result := ErrorCodes.make(ErrorCodes.INVALID_PARAMS, message)
	result["error"]["data"] = {"suggestions": suggestions}
	return result
