@tool
extends McpTestSuite

## Tests for BatchHandler — stop-on-first-error and rollback semantics.

var _handler: BatchHandler
var _dispatcher: McpDispatcher
var _undo_redo: EditorUndoRedoManager
var _node_handler: NodeHandler
var _call_log: Array = []


func suite_name() -> String:
	return "batch"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	var log_buffer: McpLogBuffer = ctx.get("log_buffer")
	_dispatcher = McpDispatcher.new(log_buffer)
	_dispatcher.mcp_logging = false
	_node_handler = NodeHandler.new(_undo_redo)
	_dispatcher.register("create_node", _node_handler.create_node)
	_dispatcher.register("delete_node", _node_handler.delete_node)
	_dispatcher.register("set_property", _node_handler.set_property)

	_dispatcher.register("_ok_pure", func(_p: Dictionary) -> Dictionary:
		_call_log.append("_ok_pure")
		return {"data": {"undoable": false}})
	_dispatcher.register("_fail_pure", func(_p: Dictionary) -> Dictionary:
		_call_log.append("_fail_pure")
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "forced failure"))

	_handler = BatchHandler.new(_dispatcher, _undo_redo)


func setup() -> void:
	_call_log.clear()


func _undo_for_scene(scene_root: Node) -> UndoRedo:
	return _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(scene_root))


# ----- Validation -----

func test_rejects_non_list_commands() -> void:
	var result := _handler.batch_execute({"commands": "nope"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rejects_empty_commands() -> void:
	var result := _handler.batch_execute({"commands": []})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rejects_missing_command_field() -> void:
	var result := _handler.batch_execute({"commands": [{"params": {}}]})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rejects_non_dict_item() -> void:
	var result := _handler.batch_execute({"commands": [42]})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_rejects_unknown_subcommand() -> void:
	var result := _handler.batch_execute({"commands": [{"command": "does_not_exist"}]})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)


func test_unknown_command_error_mentions_plugin_names() -> void:
	# Simulates the common mistake: passing MCP tool name "node_create"
	# instead of the plugin command "create_node".
	var result := _handler.batch_execute({"commands": [{"command": "node_create"}]})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)
	var msg: String = result.error.message
	assert_contains(msg, "plugin command names", "error should explain naming convention")
	assert_contains(msg, "create_node", "error should suggest the correct plugin name")


func test_unknown_command_populates_suggestions_field() -> void:
	var result := _handler.batch_execute({"commands": [{"command": "node_create"}]})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "suggestions")
	var suggestions: Array = result.error.data.suggestions
	assert_gt(suggestions.size(), 0, "suggestions should be non-empty for near-match name")
	assert_contains(suggestions, "create_node", "suggestions should include 'create_node'")


func test_unknown_command_empty_suggestions_when_no_match() -> void:
	# Pure gibberish should still error cleanly, with suggestions empty or low-similarity.
	var result := _handler.batch_execute({"commands": [{"command": "zzzqqqxxx_totally_bogus"}]})
	assert_is_error(result, McpErrorCodes.UNKNOWN_COMMAND)
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "suggestions")
	# Array may be empty — the contract is just that the key exists and is an Array.
	assert_true(result.error.data.suggestions is Array, "suggestions must be an Array")


func test_rejects_batch_execute_as_subcommand() -> void:
	var result := _handler.batch_execute({
		"commands": [{"command": "batch_execute", "params": {}}],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- Success path -----

func test_all_succeed_returns_results() -> void:
	var result := _handler.batch_execute({
		"commands": [
			{"command": "_ok_pure", "params": {}},
			{"command": "_ok_pure", "params": {}},
		],
	})
	assert_has_key(result, "data")
	assert_eq(result.data.succeeded, 2)
	assert_eq(result.data.stopped_at, null)
	assert_eq(result.data.results.size(), 2)
	assert_eq(result.data.results[0].status, "ok")
	assert_eq(result.data.rolled_back, false)
	assert_eq(_call_log, ["_ok_pure", "_ok_pure"])


func test_success_undoable_false_when_any_subcommand_not_undoable() -> void:
	var result := _handler.batch_execute({
		"commands": [{"command": "_ok_pure", "params": {}}],
	})
	# _ok_pure returns undoable=false; batch reflects that.
	assert_eq(result.data.undoable, false)


# ----- Failure / stop semantics -----

func test_stops_on_first_error() -> void:
	var result := _handler.batch_execute({
		"commands": [
			{"command": "_ok_pure", "params": {}},
			{"command": "_fail_pure", "params": {}},
			{"command": "_ok_pure", "params": {}},
		],
	})
	assert_eq(result.data.succeeded, 1)
	assert_eq(result.data.stopped_at, 1)
	assert_eq(result.data.results.size(), 2)
	assert_eq(result.data.results[1].status, "error")
	assert_has_key(result.data, "error")
	assert_eq(_call_log, ["_ok_pure", "_fail_pure"])


func test_no_rollback_when_undo_false() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var before_count := scene_root.get_child_count()
	var result := _handler.batch_execute({
		"undo": false,
		"commands": [
			{"command": "create_node", "params": {"type": "Node3D", "name": "_BatchTempA", "parent_path": "/Main"}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_eq(result.data.stopped_at, 1)
	assert_eq(result.data.rolled_back, false)
	# Created node still exists
	var after_count := scene_root.get_child_count()
	assert_eq(after_count, before_count + 1)
	# Clean up manually
	_undo_for_scene(scene_root).undo()


func test_rollback_on_failure_with_undo_true() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var before_count := scene_root.get_child_count()
	var result := _handler.batch_execute({
		"commands": [
			{"command": "create_node", "params": {"type": "Node3D", "name": "_BatchTempB", "parent_path": "/Main"}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_eq(result.data.stopped_at, 1)
	assert_eq(result.data.rolled_back, true)
	assert_eq(result.data.succeeded, 1)
	# Rollback undid the create
	var after_count := scene_root.get_child_count()
	assert_eq(after_count, before_count)


func test_real_multi_step_success() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var result := _handler.batch_execute({
		"commands": [
			{"command": "create_node", "params": {"type": "Node3D", "name": "_BatchMulti", "parent_path": "/Main"}},
			{"command": "set_property", "params": {"path": "/Main/_BatchMulti", "property": "position", "value": {"x": 1.0, "y": 2.0, "z": 3.0}}},
		],
	})
	assert_eq(result.data.succeeded, 2)
	assert_eq(result.data.stopped_at, null)
	var node: Node3D = scene_root.get_node("_BatchMulti")
	assert_eq(node.position.x, 1.0)
	# Cleanup: two undos (one per sub-command)
	var ur := _undo_for_scene(scene_root)
	ur.undo()
	ur.undo()
