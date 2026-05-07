@tool
class_name McpParamValidators
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Type-check a JSON-decoded param Variant before assigning it into a typed
## GDScript local. The dispatcher only catches handler crashes as an opaque
## "malformed result" (issue #210), so a typed assignment like
##   var group: String = params.get("group", "")
## will runtime-error and bubble up without telling the caller which param
## was the wrong shape. Handlers should guard untrusted values with one of
## the require_*() helpers below and return its error dict on mismatch.


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


## Returns null iff `value` is an int. Floats are rejected — JSON decoders
## that emit `1.0` for an integer slot will surface a clear error here
## rather than silently truncating downstream.
static func require_int(name: String, value: Variant) -> Variant:
	if typeof(value) == TYPE_INT:
		return null
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Param '%s' must be an int, got %s" % [name, type_string(typeof(value))],
	)


## Returns null iff `value` is a bool.
static func require_bool(name: String, value: Variant) -> Variant:
	if typeof(value) == TYPE_BOOL:
		return null
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Param '%s' must be a bool, got %s" % [name, type_string(typeof(value))],
	)
