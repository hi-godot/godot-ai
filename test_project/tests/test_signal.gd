@tool
extends McpTestSuite

## Tests for SignalHandler — signal listing, connecting, and disconnecting.

var _handler: SignalHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "signal"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = SignalHandler.new(_undo_redo)


# ----- list_signals -----

func test_list_signals_returns_signals() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var path := "/" + scene_root.name
	var result := _handler.list_signals({"path": path})
	assert_has_key(result, "data")
	assert_has_key(result.data, "signals")
	assert_has_key(result.data, "signal_count")
	assert_gt(result.data.signal_count, 0, "Root node should have signals")


func test_list_signals_missing_path() -> void:
	var result := _handler.list_signals({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_signals_unknown_node() -> void:
	var result := _handler.list_signals({"path": "/NonExistentNode"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_list_signals_no_scene() -> void:
	## If no scene is open this should report EDITOR_NOT_READY.
	## We can't easily test this in-editor since a scene is always open,
	## so just verify the path validation works.
	var result := _handler.list_signals({"path": "/BogusRoot/BogusChild"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- connect_signal -----

func test_connect_signal_missing_params() -> void:
	var result := _handler.connect_signal({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)

	result = _handler.connect_signal({"path": "/Main", "signal": "ready", "target": "/Main"})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_connect_signal_unknown_source() -> void:
	var result := _handler.connect_signal({
		"path": "/NoSuchNode",
		"signal": "ready",
		"target": "/Main",
		"method": "_ready",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


# ----- disconnect_signal -----

func test_disconnect_signal_missing_params() -> void:
	var result := _handler.disconnect_signal({})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_disconnect_signal_not_connected() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var path := "/" + scene_root.name
	var result := _handler.disconnect_signal({
		"path": path,
		"signal": "ready",
		"target": path,
		"method": "_nonexistent_method",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
