@tool
class_name McpParamValidators
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Type-check a JSON-decoded param Variant before assigning it into a typed
## GDScript local. The dispatcher only catches handler crashes as an opaque
## "malformed result" (issue #210), so a typed assignment like
##   var group: String = params.get("group", "")
## will runtime-error and bubble up without telling the caller which param
## was the wrong shape. Only string params are guarded — int/bool params
## can't be: Godot's JSON parser decodes every number as float (a wire `5`
## arrives as `5.0`), so a strict int check would reject every legitimate
## integer a client sends, and GDScript's typed assignment already converts
## numeric Variants safely. Bool params arrive as real bools and a wrong
## type surfaces through the dispatcher's malformed-result path.


## Returns null iff `value` is a String or StringName. On any other type
## returns an INVALID_PARAMS error dict whose message names both `name` and
## the actual Variant type (via Godot's built-in `type_string`).
static func require_string(name: String, value: Variant) -> Variant:
	var t := typeof(value)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return null
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Param '%s' must be a String, got %s" % [name, type_string(t)],
	)
