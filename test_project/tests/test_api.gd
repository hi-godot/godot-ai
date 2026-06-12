@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ApiHandler := preload("res://addons/godot_ai/handlers/api_handler.gd")

var _handler: ApiHandler


func suite_name() -> String:
	return "api"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = ApiHandler.new()


func test_get_class_info_requires_class_name() -> void:
	var result := _handler.get_class_info({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_get_class_info_unknown_class_suggests_match() -> void:
	var result := _handler.get_class_info({"class_name": "CharacterBod3D"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_has_key(result.error, "data")
	assert_contains(result.error.data.suggestions, "CharacterBody3D")


func test_get_class_info_project_script_class_reports_limitation() -> void:
	var result := _handler.get_class_info({"class_name": "McpConnection"})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_has_key(result.error, "data")
	assert_true(result.error.data.script_class)
	assert_contains(result.error.data.path, "connection.gd")
	assert_contains(result.error.message, "script_manage")


func test_get_class_info_invalid_section_suggests_plural() -> void:
	var result := _handler.get_class_info({
		"class_name": "CharacterBody3D",
		"sections": ["method"],
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_has_key(result.error, "data")
	assert_contains(result.error.data.suggestions.method, "methods")


func test_get_class_info_negative_limit_errors() -> void:
	var result := _handler.get_class_info({
		"class_name": "CharacterBody3D",
		"limit": -1,
	})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "limit")


func test_get_class_info_singleton_does_not_report_abstract() -> void:
	var result := _handler.get_class_info({
		"class_name": "Input",
		"sections": ["methods"],
		"limit": 1,
	})
	assert_has_key(result, "data")
	assert_false(result.data.has("is_abstract"))
	assert_false(result.data.can_instantiate)
	assert_true(result.data.is_singleton)


func test_get_class_info_character_body_3d() -> void:
	var result := _handler.get_class_info({
		"class_name": "CharacterBody3D",
		"include_inherited": true,
		"limit": 0,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.class_name, "CharacterBody3D")
	assert_false(result.data.has("is_abstract"))
	assert_contains(result.data.inheritance_chain, "PhysicsBody3D")
	assert_contains(result.data.inheritance_chain, "Node")
	assert_gt(result.data.property_count, 0)
	assert_gt(result.data.method_count, 0)
	assert_gt(result.data.signal_count, 0)

	var motion_mode := _find_named(result.data.properties, "motion_mode")
	assert_false(motion_mode.is_empty(), "motion_mode property should be present")
	assert_eq(motion_mode.type, "int")
	assert_contains(motion_mode.hint_string, "Grounded")
	assert_has_key(motion_mode, "default")

	var move_and_slide := _find_named(result.data.methods, "move_and_slide")
	assert_false(move_and_slide.is_empty(), "move_and_slide method should be present")
	assert_eq(move_and_slide.return.type, "bool")

	var tree_entered := _find_named(result.data.signals, "tree_entered")
	assert_false(tree_entered.is_empty(), "inherited Node signals should be present")

	var motion_enum := _find_named(result.data.enums, "MotionMode")
	assert_false(motion_enum.is_empty(), "MotionMode enum should be present")
	assert_false(_find_named(motion_enum.values, "MOTION_MODE_GROUNDED").is_empty())


func test_get_class_info_resource_class() -> void:
	var result := _handler.get_class_info({"class_name": "BoxMesh"})
	assert_has_key(result, "data")
	assert_true(result.data.can_instantiate)
	assert_contains(result.data.inheritance_chain, "Resource")
	assert_false(_find_named(result.data.properties, "size").is_empty())


func test_get_class_info_default_is_direct_and_limited() -> void:
	var result := _handler.get_class_info({"class_name": "Control"})
	assert_has_key(result, "data")
	assert_false(result.data.include_inherited)
	assert_true(result.data.methods.size() <= result.data.limit)
	assert_eq(_find_named(result.data.methods, "get_parent"), {})


func _find_named(items: Array, item_name: String) -> Dictionary:
	for item in items:
		if item.get("name", "") == item_name:
			return item
	return {}
