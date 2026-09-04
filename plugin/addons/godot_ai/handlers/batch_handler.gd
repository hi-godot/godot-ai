@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Executes a list of sub-commands through the dispatcher with stop-on-first-error
## semantics. When undo=true (default), any successful sub-commands are rolled
## back via the scene's UndoRedo history if a later sub-command fails.

## Commands that cannot run as batch sub-commands, each with the reason a batch
## can't host it.
## - batch_execute: would recurse.
## - run_tests: a batch executes synchronously inside one dispatcher tick with
##   NO transport servicing, so a full suite starves the WebSocket heartbeat
##   (the exact disconnect the serviced test_run path exists to prevent) and
##   the Python batch handler only allows 30s anyway — call the test_run tool
##   directly.
## - game_command: it is deferred — its reply flows out-of-band correlated by a
##   _request_id that dispatch_direct deliberately strips (see
##   McpDispatcher.dispatch_direct), so a game op nested in a batch would have
##   no completion channel and hang or lose its reply. input_sequence made this
##   concrete (#814); the whole game_command surface shares the deferred path.
const FORBIDDEN_SUBCOMMANDS := {
	"batch_execute": "batch_execute cannot be nested inside another batch",
	"run_tests":
		"run_tests is not allowed as a sub-command — a batch runs synchronously "
		+ "with no transport servicing; call the test_run tool directly",
	"game_command":
		"game_command ops are deferred (their reply arrives out-of-band) and "
		+ "have no completion channel inside a batch — run them as their own tool call",
	"configure_client":
		"configure_client is deferred and has no completion channel inside a batch — "
		+ "run it as its own tool call",
	"remove_client":
		"remove_client is deferred and has no completion channel inside a batch — "
		+ "run it as its own tool call",
}

## The whole batch executes synchronously inside one dispatcher tick,
## outside the 4ms frame budget — an unbounded array freezes the editor
## for the batch's full duration. 500 is far above any legitimate scene
## edit while keeping worst-case stalls in check.
const MAX_BATCH_COMMANDS := 500

var _dispatcher: McpDispatcher
var _undo_redo: EditorUndoRedoManager


func _init(dispatcher: McpDispatcher, undo_redo: EditorUndoRedoManager) -> void:
	_dispatcher = dispatcher
	_undo_redo = undo_redo


func batch_execute(params: Dictionary) -> Dictionary:
	var commands = params.get("commands", null)
	if typeof(commands) != TYPE_ARRAY:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "commands must be a list")
	if commands.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "commands must not be empty")
	if commands.size() > MAX_BATCH_COMMANDS:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"commands exceeds the %d-command batch cap (got %d) — split into multiple batches" % [MAX_BATCH_COMMANDS, commands.size()]
		)

	var undo: bool = params.get("undo", true)

	for idx in range(commands.size()):
		var item = commands[idx]
		if typeof(item) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "commands[%d] must be a dict" % idx)
		var cmd_name: String = item.get("command", "")
		if cmd_name.is_empty():
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "commands[%d] missing 'command' field" % idx)
		if FORBIDDEN_SUBCOMMANDS.has(cmd_name):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"commands[%d]: %s" % [idx, FORBIDDEN_SUBCOMMANDS[cmd_name]])
		if not _dispatcher.has_command(cmd_name):
			return _unknown_command_error(idx, cmd_name)
		## Pre-validate params type: the execution loop's typed Dictionary
		## local would hard-error on a non-dict mid-batch, aborting AFTER
		## earlier mutations committed. Catching it here keeps the
		## all-or-nothing contract for malformed input.
		if typeof(item.get("params", {})) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "commands[%d].params must be a dict" % idx)
		if cmd_name.begins_with("custom_tool:"):
			var _custom_tools := McpToolRegistry.get_instance()
			if _custom_tools:
				var spec := _custom_tools.get_spec(cmd_name.trim_prefix("custom_tool:"))
				## A deferred tool's real reply arrives via ctx.send_deferred
				## AFTER the batch has already returned its synchronous
				## results — the sub-command would report an opaque
				## "_deferred" placeholder and the actual payload would be
				## orphaned. Reject up-front, matching the FORBIDDEN_SUBCOMMANDS
				## contract for run_tests.
				if spec != null and spec.deferred:
					return ErrorCodes.make(
						ErrorCodes.VALUE_OUT_OF_RANGE,
						"commands[%d] custom_tool:%s is deferred — its reply outlives the batch response; call it directly instead" % [idx, cmd_name.trim_prefix("custom_tool:")]
					)
				if undo and spec != null and not spec.undoable:
					return ErrorCodes.make(
						ErrorCodes.CUSTOM_TOOL_NOT_UNDOABLE,
						"commands[%d] custom_tool:%s is not undoable" % [idx, cmd_name.trim_prefix("custom_tool:")]
					)

	var results: Array = []
	var succeeded := 0
	var stopped_at = null
	var all_undoable := true
	## One entry per action a sub-command actually committed, in commit order,
	## naming the UndoRedo that received it. Rollback replays this in reverse.
	##
	## Measured rather than inferred. Counting *successes* over-undoes, because
	## a sub-command can succeed without committing anything (`create_script`
	## and `write_text_file` write straight to disk) — the extra undos then eat
	## the user's own pre-batch edits. Trusting the response's `undoable` flag
	## instead under-undoes, because `custom_tool:` sub-commands never carry one
	## (`custom_tool_wrapper.gd` returns the addon handler's dict verbatim) even
	## when their spec declares `undoable = true` and they did commit. Comparing
	## `UndoRedo.get_version()` across the call is the only reading that can't
	## disagree with what the editor actually recorded.
	var committed: Array = []

	for idx in range(commands.size()):
		var item: Dictionary = commands[idx]
		var cmd_name: String = item["command"]
		var sub_params: Dictionary = item.get("params", {})

		var tracked := _tracked_histories()
		var before: Array = []
		for ur in tracked:
			before.append(ur.get_version())

		var raw_result: Dictionary = _dispatcher.dispatch_direct(cmd_name, sub_params)
		## Record before reading status. A handler can commit_action() and still
		## return an error; those actions must be in `committed` so a later
		## (or this) failure rolls them back.
		_record_committed(tracked, before, committed)
		var status: String = raw_result.get("status", "ok")

		var result_entry: Dictionary = {"command": cmd_name, "status": status}
		if status == "error":
			result_entry["error"] = raw_result.get("error", {})
			results.append(result_entry)
			stopped_at = idx
			break
		else:
			var data: Dictionary = raw_result.get("data", raw_result)
			result_entry["data"] = data
			if typeof(data) == TYPE_DICTIONARY and data.get("undoable", false) != true:
				all_undoable = false
			results.append(result_entry)
			succeeded += 1

	var rolled_back := false
	if stopped_at != null and undo and not committed.is_empty():
		rolled_back = _rollback(committed)

	var response_data: Dictionary = {
		"succeeded": succeeded,
		"stopped_at": stopped_at,
		"results": results,
		"undo": undo,
		"rolled_back": rolled_back,
		"undoable": stopped_at == null and all_undoable and not rolled_back,
	}
	if stopped_at != null:
		response_data["error"] = results[-1]["error"]
	return {"data": response_data}


## The histories a batch sub-command can commit into.
##
## Most write handlers pin their action to the edited scene, but not all:
## handlers that `create_action(label)` without a context object bind it to the
## handler `RefCounted` instead, and it lands in `GLOBAL_HISTORY` (see
## `animation_handler.gd`'s note on mismatched histories, and
## `testing/test_suite.gd`, which watches both for the same reason). Watching
## only the scene history would leave those actions un-rolled-back.
func _tracked_histories() -> Array:
	var out: Array = []
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		var scene_ur := _undo_redo.get_history_undo_redo(
			_undo_redo.get_object_history_id(scene_root)
		)
		if scene_ur != null:
			out.append(scene_ur)
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	if global_ur != null and not global_ur in out:
		out.append(global_ur)
	return out


## Append one entry to `committed` per action the just-finished sub-command
## pushed, by diffing each watched history's version against `before`.
## `UndoRedo.get_version()` advances once per `commit_action`, so the delta is
## the action count — a handler that commits twice is recorded twice, and one
## that commits nothing is recorded not at all.
func _record_committed(tracked: Array, before: Array, committed: Array) -> void:
	for i in range(tracked.size()):
		var delta: int = tracked[i].get_version() - int(before[i])
		for _n in range(delta):
			committed.append(tracked[i])


## Build the unknown-command error for a sub-command. Clarifies that
## batch_execute expects plugin command names (not MCP tool names) and
## surfaces fuzzy suggestions in both the message and structured data.
func _unknown_command_error(idx: int, cmd_name: String) -> Dictionary:
	var suggestions := _dispatcher.suggest_similar(cmd_name)
	var msg := "commands[%d]: unknown plugin command '%s'. batch_execute expects plugin command names (e.g. 'create_node'), not MCP tool names (e.g. 'node_create')." % [idx, cmd_name]
	if not suggestions.is_empty():
		msg += " Did you mean: %s?" % ", ".join(suggestions)
	var err := ErrorCodes.make(ErrorCodes.UNKNOWN_COMMAND, msg)
	err["error"]["data"] = {"suggestions": suggestions}
	return err


## Undo every action the batch committed, newest first, against the history
## that actually received it. Returns true iff every undo() reported success.
##
## Strict LIFO across histories matters: undoing a scene action before a global
## one committed after it would replay them out of order. Walking `committed`
## in reverse preserves commit order regardless of which history each landed in.
func _rollback(committed: Array) -> bool:
	if committed.is_empty():
		return false
	var ok := true
	for i in range(committed.size() - 1, -1, -1):
		if not committed[i].undo():
			ok = false
	return ok
