@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const BatchHandler := preload("res://addons/godot_ai/handlers/batch_handler.gd")
const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")

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
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "forced failure"))

	## Commits a real undo action but reports no `undoable` key — the shape a
	## `custom_tool:` sub-command has, since `custom_tool_wrapper.gd` returns the
	## addon handler's dict verbatim and never stamps the spec's flag. Rollback
	## must still revert it, so this stub pins that the depth is measured from
	## the editor's history rather than read off the response.
	_dispatcher.register("_commits_unreported", func(_p: Dictionary) -> Dictionary:
		_call_log.append("_commits_unreported")
		_node_handler.create_node({
			"type": "Node3D", "name": "_BatchUnreported", "parent_path": "/Main",
		})
		return {"data": {}})
	## Commits, then returns an error. Rollback must still see the commit —
	## `_record_committed` cannot wait for `status == "ok"`.
	_dispatcher.register("_commits_then_errors", func(_p: Dictionary) -> Dictionary:
		_call_log.append("_commits_then_errors")
		_node_handler.create_node({
			"type": "Node3D", "name": "_BatchCommittedError", "parent_path": "/Main",
		})
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "committed then failed"))

	_handler = BatchHandler.new(_dispatcher, _undo_redo)


func suite_teardown() -> void:
	## Registered callbacks capture this suite. Break the dispatcher ->
	## callback -> suite cycle before releasing the suite's handler graph.
	if _dispatcher != null:
		_dispatcher.clear()
	_handler = null
	_dispatcher = null
	_node_handler = null
	_undo_redo = null
	_call_log.clear()


func setup() -> void:
	_call_log.clear()


func _undo_for_scene(scene_root: Node) -> UndoRedo:
	return _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(scene_root))


# ----- Validation -----

func test_rejects_non_list_commands() -> void:
	var result := _handler.batch_execute({"commands": "nope"})
	assert_is_error(result)


func test_rejects_empty_commands() -> void:
	var result := _handler.batch_execute({"commands": []})
	assert_is_error(result)


func test_rejects_missing_command_field() -> void:
	var result := _handler.batch_execute({"commands": [{"params": {}}]})
	assert_is_error(result)


func test_rejects_non_dict_item() -> void:
	var result := _handler.batch_execute({"commands": [42]})
	assert_is_error(result)


func test_rejects_unknown_subcommand() -> void:
	var result := _handler.batch_execute({"commands": [{"command": "does_not_exist"}]})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)


func test_unknown_command_error_mentions_plugin_names() -> void:
	# Simulates the common mistake: passing MCP tool name "node_create"
	# instead of the plugin command "create_node".
	var result := _handler.batch_execute({"commands": [{"command": "node_create"}]})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)
	var msg: String = result.error.message
	assert_contains(msg, "plugin command names", "error should explain naming convention")
	assert_contains(msg, "create_node", "error should suggest the correct plugin name")


func test_unknown_command_populates_suggestions_field() -> void:
	var result := _handler.batch_execute({"commands": [{"command": "node_create"}]})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "suggestions")
	var suggestions: Array = result.error.data.suggestions
	assert_gt(suggestions.size(), 0, "suggestions should be non-empty for near-match name")
	assert_contains(suggestions, "create_node", "suggestions should include 'create_node'")


func test_unknown_command_empty_suggestions_when_no_match() -> void:
	# Pure gibberish should still error cleanly, with suggestions empty or low-similarity.
	var result := _handler.batch_execute({"commands": [{"command": "zzzqqqxxx_totally_bogus"}]})
	assert_is_error(result, ErrorCodes.UNKNOWN_COMMAND)
	assert_has_key(result.error, "data")
	assert_has_key(result.error.data, "suggestions")
	# Array may be empty — the contract is just that the key exists and is an Array.
	assert_true(result.error.data.suggestions is Array, "suggestions must be an Array")


func test_rejects_batch_execute_as_subcommand() -> void:
	var result := _handler.batch_execute({
		"commands": [{"command": "batch_execute", "params": {}}],
	})
	assert_is_error(result)


func test_rejects_game_command_as_subcommand() -> void:
	## game_command ops are deferred — their reply flows out-of-band and has no
	## completion channel inside a batch (#814). Reject up front with a clear
	## message rather than letting the stripped-_request_id path hang/half-run.
	var result := _handler.batch_execute({
		"commands": [{"command": "game_command", "params": {"op": "input_sequence"}}],
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "deferred")


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


## Rollback depth is the number of actions the batch actually committed, not the
## number of sub-commands that succeeded. `_ok_pure` succeeds without pushing an
## action — the shape of `create_script` / `write_text_file`, which write to disk
## and report `undoable: false`. Counting it undoes one action too many, and the
## extra undo lands on the editor's shared history: the user's pre-batch edits.
##
## Cleanup is guarded on presence throughout: `assert_*` records a failure and
## returns rather than aborting the body, so an unguarded trailing undo would
## consume an unrelated action from shared history on every regression.
func test_rollback_does_not_undo_actions_the_batch_did_not_create() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	## The "user's prior edit" — committed, undoable, and not part of the batch.
	var sentinel := _node_handler.create_node({
		"type": "Node3D", "name": "_BatchSentinel", "parent_path": "/Main",
	})
	assert_eq(sentinel.data.undoable, true, "sentinel must be an undoable action")

	var result := _handler.batch_execute({
		"commands": [
			{"command": "_ok_pure", "params": {}},
			{"command": "create_node", "params": {"type": "Node3D", "name": "_BatchVictim", "parent_path": "/Main"}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_true(scene_root.has_node(^"_BatchSentinel"),
		"rollback must not walk past the batch into pre-batch history")
	assert_eq(result.data.stopped_at, 2)
	assert_eq(result.data.succeeded, 2, "both non-error sub-commands are still counted as succeeded")
	assert_eq(result.data.rolled_back, true)
	assert_false(scene_root.has_node(^"_BatchVictim"), "rollback undid the batch's own create")

	_undo_leftovers([^"_BatchSentinel", ^"_BatchVictim"])


## The mirror ordering: undoable first, non-undoable second. Guards against a
## refactor that ties history capture to the first iteration only.
func test_rollback_correct_when_the_undoable_sub_command_runs_first() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var sentinel := _node_handler.create_node({
		"type": "Node3D", "name": "_BatchSentinelC", "parent_path": "/Main",
	})
	assert_eq(sentinel.data.undoable, true, "sentinel setup")

	var result := _handler.batch_execute({
		"commands": [
			{"command": "create_node", "params": {"type": "Node3D", "name": "_BatchVictimC", "parent_path": "/Main"}},
			{"command": "_ok_pure", "params": {}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_true(scene_root.has_node(^"_BatchSentinelC"),
		"rollback must not reach the pre-batch sentinel")
	assert_eq(result.data.rolled_back, true)
	assert_false(scene_root.has_node(^"_BatchVictimC"), "the batch's own create was undone")

	_undo_leftovers([^"_BatchSentinelC", ^"_BatchVictimC"])


## A sub-command can commit an action without reporting `undoable` — every
## `custom_tool:` does, because the wrapper returns the addon's dict verbatim.
## Rollback must still revert it, so the depth cannot be read off the response.
func test_rollback_reverts_a_commit_that_reported_no_undoable_flag() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var sentinel := _node_handler.create_node({
		"type": "Node3D", "name": "_BatchSentinelU", "parent_path": "/Main",
	})
	assert_eq(sentinel.data.undoable, true, "sentinel setup")

	var result := _handler.batch_execute({
		"commands": [
			{"command": "_commits_unreported", "params": {}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_eq(result.data.stopped_at, 1)
	assert_false(scene_root.has_node(^"_BatchUnreported"),
		"an action committed without an `undoable` flag must still be rolled back")
	assert_eq(result.data.rolled_back, true)
	assert_true(scene_root.has_node(^"_BatchSentinelU"),
		"and rollback still must not reach pre-batch history")

	_undo_leftovers([^"_BatchSentinelU", ^"_BatchUnreported"])


## A handler can `commit_action()` and still return an error dict. Recording
## only on `status == "ok"` would leave that mutation out of `committed`.
func test_rollback_reverts_a_commit_from_a_failing_subcommand() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var sentinel := _node_handler.create_node({
		"type": "Node3D", "name": "_BatchSentinelE", "parent_path": "/Main",
	})
	assert_eq(sentinel.data.undoable, true, "sentinel setup")

	var result := _handler.batch_execute({
		"commands": [
			{"command": "_commits_then_errors", "params": {}},
		],
	})
	assert_eq(result.data.stopped_at, 0)
	assert_eq(result.data.succeeded, 0)
	assert_eq(result.data.rolled_back, true)
	assert_false(scene_root.has_node(^"_BatchCommittedError"),
		"a commit that preceded an error status must still be rolled back")
	assert_true(scene_root.has_node(^"_BatchSentinelE"),
		"and rollback still must not reach pre-batch history")
	assert_eq(_call_log, ["_commits_then_errors"])

	_undo_leftovers([^"_BatchSentinelE", ^"_BatchCommittedError"])


## A batch whose successful sub-commands committed nothing has nothing to roll
## back, and `rolled_back` must say so rather than undoing unrelated history.
func test_rollback_is_a_noop_when_nothing_was_committed() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var sentinel := _node_handler.create_node({
		"type": "Node3D", "name": "_BatchSentinel2", "parent_path": "/Main",
	})
	assert_eq(sentinel.data.undoable, true, "sentinel setup")

	var result := _handler.batch_execute({
		"commands": [
			{"command": "_ok_pure", "params": {}},
			{"command": "_ok_pure", "params": {}},
			{"command": "_fail_pure", "params": {}},
		],
	})
	assert_true(scene_root.has_node(^"_BatchSentinel2"),
		"a batch that committed nothing must leave prior history alone")
	assert_eq(result.data.stopped_at, 2)
	assert_eq(result.data.succeeded, 2)
	assert_eq(result.data.rolled_back, false, "nothing was committed, so nothing was rolled back")

	_undo_leftovers([^"_BatchSentinel2"])


## Undo one action per node in `names` that is still present, so a regression
## leaves the shared history where it started instead of eating an unrelated
## action. Never asserts: cleanup failures must not mask the real assertion.
func _undo_leftovers(names: Array) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	for n in names:
		if scene_root.has_node(n):
			editor_undo(_undo_redo)


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


# ----- pre-validation: params type, batch cap, reserved keys -----

func test_batch_rejects_non_dict_params_without_executing() -> void:
	var result := _handler.batch_execute({"commands": [
		{"command": "_ok_pure"},
		{"command": "_ok_pure", "params": "nope"},
	]})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)
	assert_contains(result.error.message, "commands[1].params")
	assert_eq(_call_log.size(), 0,
		"pre-validation failure must execute nothing (all-or-nothing)")


func test_batch_rejects_over_cap_without_executing() -> void:
	var commands: Array = []
	for i in range(BatchHandler.MAX_BATCH_COMMANDS + 1):
		commands.append({"command": "_ok_pure"})
	var result := _handler.batch_execute({"commands": commands})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "batch cap")
	assert_eq(_call_log.size(), 0, "an over-cap batch must execute nothing")


func test_batch_sub_command_cannot_carry_reserved_request_id() -> void:
	var seen: Array = []
	_dispatcher.register("_capture_params", func(p: Dictionary) -> Dictionary:
		seen.append(p.duplicate())
		return {"data": {"undoable": false}})
	var result := _handler.batch_execute({"commands": [
		{"command": "_capture_params", "params": {"_request_id": "hijack", "x": 1}},
	]})
	assert_has_key(result, "data")
	assert_eq(result.data.succeeded, 1, "the sub-command should execute normally")
	assert_eq(seen.size(), 1)
	assert_true(not seen[0].has("_request_id"),
		"dispatch_direct must strip the reserved deferred-reply key")
	assert_eq(seen[0].get("x"), 1)
