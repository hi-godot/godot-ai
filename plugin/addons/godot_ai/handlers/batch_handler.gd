@tool
class_name BatchHandler
extends RefCounted

## Executes a list of sub-commands through the dispatcher with stop-on-first-error
## semantics. When undo=true (default), any successful sub-commands are rolled
## back via the scene's UndoRedo history if a later sub-command fails.

const FORBIDDEN_SUBCOMMANDS := ["batch_execute"]

var _dispatcher: McpDispatcher
var _undo_redo: EditorUndoRedoManager


func _init(dispatcher: McpDispatcher, undo_redo: EditorUndoRedoManager) -> void:
	_dispatcher = dispatcher
	_undo_redo = undo_redo


func batch_execute(params: Dictionary) -> Dictionary:
	var commands = params.get("commands", null)
	if typeof(commands) != TYPE_ARRAY:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "commands must be a list")
	if commands.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "commands must not be empty")

	var undo: bool = params.get("undo", true)

	for idx in range(commands.size()):
		var item = commands[idx]
		if typeof(item) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "commands[%d] must be a dict" % idx)
		var cmd_name: String = item.get("command", "")
		if cmd_name.is_empty():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "commands[%d] missing 'command' field" % idx)
		if cmd_name in FORBIDDEN_SUBCOMMANDS:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "commands[%d]: '%s' is not allowed as a sub-command" % [idx, cmd_name])
		if not _dispatcher.has_command(cmd_name):
			return _unknown_command_error(idx, cmd_name)

	var results: Array = []
	var succeeded := 0
	var stopped_at = null
	var all_undoable := true
	# Captured after the first successful commit — get_history_undo_redo()
	# errors if called before any action exists in the history_map.
	var histories: Array = []

	for idx in range(commands.size()):
		var item: Dictionary = commands[idx]
		var cmd_name: String = item["command"]
		var sub_params: Dictionary = item.get("params", {})

		var raw_result: Dictionary = _dispatcher.dispatch_direct(cmd_name, sub_params)
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
			_capture_histories(histories)

	var rolled_back := false
	if stopped_at != null and undo and succeeded > 0:
		rolled_back = _rollback(succeeded, histories)

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


## Capture UndoRedo references for the scene and global histories. Safe to call
## multiple times; appends only new references. Must be called only after at
## least one action has been committed to each history.
func _capture_histories(histories: Array) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var scene_id := _undo_redo.get_object_history_id(scene_root)
	var scene_ur := _undo_redo.get_history_undo_redo(scene_id)
	if scene_ur != null and not scene_ur in histories:
		histories.append(scene_ur)


## Build the unknown-command error for a sub-command. Clarifies that
## batch_execute expects plugin command names (not MCP tool names) and
## surfaces fuzzy suggestions in both the message and structured data.
func _unknown_command_error(idx: int, cmd_name: String) -> Dictionary:
	var suggestions := _dispatcher.suggest_similar(cmd_name)
	var msg := "commands[%d]: unknown plugin command '%s'. batch_execute expects plugin command names (e.g. 'create_node'), not MCP tool names (e.g. 'node_create')." % [idx, cmd_name]
	if not suggestions.is_empty():
		msg += " Did you mean: %s?" % ", ".join(suggestions)
	var err := McpErrorCodes.make(McpErrorCodes.UNKNOWN_COMMAND, msg)
	err["error"]["data"] = {"suggestions": suggestions}
	return err


## Undo `count` actions by calling undo() on captured histories in LIFO order.
## Returns true iff all undo calls succeeded.
func _rollback(count: int, histories: Array) -> bool:
	if histories.is_empty():
		return false
	for _i in range(count):
		var undone := false
		for ur in histories:
			if ur.undo():
				undone = true
				break
		if not undone:
			return false
	return true
