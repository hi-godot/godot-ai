@tool
class_name McpDispatcher
extends RefCounted

## Routes incoming commands to handlers and manages the command queue
## with a per-frame time budget.

var _command_queue: Array[Dictionary] = []
var _handlers: Dictionary = {}  # command_name -> Callable
var _log_buffer: McpLogBuffer
var mcp_logging := true


func _init(log_buffer: McpLogBuffer) -> void:
	_log_buffer = log_buffer


## Register a command handler. The callable receives (params: Dictionary) -> Dictionary.
func register(command_name: String, handler: Callable) -> void:
	_handlers[command_name] = handler


## Invoke a registered handler directly by name. Returns the handler's raw
## response dict (no request_id or status wrapping). Returns an UNKNOWN_COMMAND
## error dict if the command is not registered. Used by batch_execute.
func dispatch_direct(command: String, params: Dictionary) -> Dictionary:
	if not _handlers.has(command):
		return McpErrorCodes.make(McpErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)
	return _handlers[command].call(params)


## Whether a command is registered.
func has_command(command: String) -> bool:
	return _handlers.has(command)


## Enqueue a raw command dict received from the WebSocket.
func enqueue(cmd: Dictionary) -> void:
	_command_queue.append(cmd)


## Process queued commands within a frame budget (milliseconds).
## Returns an array of response dictionaries to send back.
func tick(budget_ms: float = 4.0) -> Array[Dictionary]:
	var responses: Array[Dictionary] = []
	var start := Time.get_ticks_msec()
	var idx := 0

	while idx < _command_queue.size() and (Time.get_ticks_msec() - start) < budget_ms:
		var cmd: Dictionary = _command_queue[idx]
		var response := _dispatch(cmd)
		responses.append(response)
		idx += 1

	if idx > 0:
		_command_queue = _command_queue.slice(idx)

	return responses


func _dispatch(cmd: Dictionary) -> Dictionary:
	var request_id: String = cmd.get("request_id", "")
	var command: String = cmd.get("command", "")
	var params: Dictionary = cmd.get("params", {})

	if mcp_logging:
		_log_buffer.log("[recv] %s(%s)" % [command, JSON.stringify(params)])

	var result: Dictionary

	if _handlers.has(command):
		result = _handlers[command].call(params)
		## Detect handler crash: if .call() returned empty dict (GDScript default
		## on unhandled error), report it so the caller sees a real error instead
		## of silent empty data.
		if result.is_empty():
			result = McpErrorCodes.make("HANDLER_CRASH",
				"Handler for '%s' returned empty dict (likely crashed)" % command)
	else:
		result = McpErrorCodes.make(McpErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)

	result["request_id"] = request_id
	if not result.has("status"):
		result["status"] = "ok"

	if mcp_logging:
		var status: String = result.get("status", "ok")
		if status == "ok":
			_log_buffer.log("[send] %s -> ok" % command)
		else:
			var err_msg: String = result.get("error", {}).get("message", "unknown")
			_log_buffer.log("[send] %s -> error: %s" % [command, err_msg])

	return result
