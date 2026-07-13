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
	assert_is_error(err)
	assert_contains(err.error.message, "group")
	assert_contains(err.error.message, "Array")


func test_require_string_rejects_dict() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", {"key": "val"})
	assert_is_error(err)
	assert_contains(err.error.message, "Dictionary")


func test_require_string_rejects_int() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", 42)
	assert_is_error(err)
	assert_contains(err.error.message, "int")


func test_require_string_rejects_null() -> void:
	var err: Dictionary = McpParamValidators.require_string("group", null)
	assert_is_error(err)
	assert_contains(err.error.message, "Nil")
