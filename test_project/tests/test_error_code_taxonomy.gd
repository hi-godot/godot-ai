@tool
extends McpTestSuite

## Acceptance test for audit-v2 #21 (issue #365): pin that each new
## error code is actually emitted by a handler under the right
## condition. The existence-counter test in
## tests/unit/test_error_code_distribution.py guards "the code is used
## somewhere"; this suite guards "the code is emitted for *the right
## reason*" — a refactor that migrated every NODE_NOT_FOUND to
## INVALID_PARAMS would still pass the counter (same total, just
## redistributed), but would break these tests.

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const AnimationHandler := preload("res://addons/godot_ai/handlers/animation_handler.gd")

var _node_handler: NodeHandler
var _material_handler: MaterialHandler
var _script_handler: ScriptHandler
var _animation_handler: AnimationHandler


func suite_name() -> String:
	return "error_code_taxonomy"


func suite_setup(ctx: Dictionary) -> void:
	var undo_redo: EditorUndoRedoManager = ctx.get("undo_redo")
	_node_handler = NodeHandler.new(undo_redo)
	_material_handler = MaterialHandler.new(undo_redo)
	_script_handler = ScriptHandler.new(undo_redo)
	_animation_handler = AnimationHandler.new(undo_redo)


# ----- NODE_NOT_FOUND -----


func test_node_not_found_when_path_does_not_resolve() -> void:
	var result := _node_handler.get_properties({"path": "/Main/__definitely_nonexistent_node_X__"})
	assert_is_error(result, McpErrorCodes.NODE_NOT_FOUND)


# ----- RESOURCE_NOT_FOUND -----


func test_resource_not_found_when_script_path_missing() -> void:
	var result := _script_handler.read({"path": "res://__missing_script_audit_v21__.gd"})
	assert_is_error(result, McpErrorCodes.RESOURCE_NOT_FOUND)


# ----- PROPERTY_NOT_ON_CLASS -----


func test_property_not_on_class_when_unknown_property() -> void:
	var result := _node_handler.set_property(
		{"path": "/Main", "property": "__definitely_not_a_property__", "value": 0}
	)
	assert_is_error(result, McpErrorCodes.PROPERTY_NOT_ON_CLASS)


# ----- VALUE_OUT_OF_RANGE -----


func test_value_out_of_range_when_animation_length_zero() -> void:
	## animation_handler.create rejects length <= 0 with VALUE_OUT_OF_RANGE
	## ('length must be > 0 (got %s)').
	var result := _animation_handler.create({
		"player_path": "/Main/AnimationPlayer",
		"name": "audit_v21_zero_length",
		"length": 0.0,
	})
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)


# ----- WRONG_TYPE -----


func test_wrong_type_when_resource_path_loads_non_material() -> void:
	## material_handler.assign rejects a resource_path that resolves to
	## something that isn't a Material with WRONG_TYPE
	## ('Resource at %s is not a Material').
	var result := _material_handler.assign({
		"node_path": "/Main",
		"resource_path": "res://main.tscn",  # exists but is a PackedScene, not Material
	})
	assert_is_error(result, McpErrorCodes.WRONG_TYPE)


# ----- MISSING_REQUIRED_PARAM -----


func test_missing_required_param_when_player_path_omitted() -> void:
	var result := _animation_handler.create({"name": "audit_v21_missing_player"})
	assert_is_error(result, McpErrorCodes.MISSING_REQUIRED_PARAM)
