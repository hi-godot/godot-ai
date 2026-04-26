@tool
extends McpTestSuite

## Tests for McpParamValidators — the type-check helpers handlers call on
## values pulled from JSON-decoded params before assigning them into typed
## GDScript locals (issue #210).


func suite_name() -> String:
	return "param_validators"


# ----- require_string -----

func test_require_string_accepts_string() -> void:
	var err: Variant = McpParamValidators.require_string("group", "ok")
	assert_eq(err, null)


func test_require_string_accepts_string_name() -> void:
	var err: Variant = McpParamValidators.require_string("group", &"sn")
	assert_eq(err, null)


func test_require_string_rejects_array() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", ["a", "b"])
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "group")
	assert_contains(err.error.message, "Array")


func test_require_string_rejects_dict() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", {"key": "val"})
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "Dictionary")


func test_require_string_rejects_int() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", 42)
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "int")


func test_require_string_rejects_null() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", null)
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "Nil")


# ----- require_int -----

func test_require_int_accepts_int() -> void:
	var err: Variant = McpParamValidators.require_int("count", 7)
	assert_eq(err, null)


func test_require_int_rejects_float() -> void:
	var err: Dictionary = McpParamValidators.require_int("count", 1.5)
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "float")


func test_require_int_rejects_string() -> void:
	var err: Dictionary = McpParamValidators.require_int("count", "7")
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "String")


# ----- require_bool -----

func test_require_bool_accepts_bool() -> void:
	var err_true: Variant = McpParamValidators.require_bool("flag", true)
	var err_false: Variant = McpParamValidators.require_bool("flag", false)
	assert_eq(err_true, null)
	assert_eq(err_false, null)


func test_require_bool_rejects_int() -> void:
	## GDScript will happily coerce 0/1 into bool elsewhere, but JSON sends
	## booleans as booleans — agents passing 1 for a bool slot are confused
	## and deserve an explicit error rather than silent coercion.
	var err: Dictionary = McpParamValidators.require_bool("flag", 1)
	assert_is_error(err, McpErrorCodes.INVALID_PARAMS)
	assert_contains(err.error.message, "int")
