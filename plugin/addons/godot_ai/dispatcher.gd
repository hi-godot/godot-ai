@tool
class_name McpDispatcher
extends RefCounted

## Routes incoming commands to handlers and manages the command queue.
##
## Handlers may be synchronous or awaitable. Because a single awaitable
## handler can span multiple frames, tick() kicks off a fire-and-forget
## drain that delivers responses through `_response_sink`. Only one drain
## runs at a time so ordering is preserved across `await` boundaries.

var _command_queue: Array[Dictionary] = []
var _handlers: Dictionary = {}  # command_name -> Callable
var _log_buffer: McpLogBuffer
var _response_sink: Callable = Callable()
var _draining := false
var mcp_logging := true


func _init(log_buffer: McpLogBuffer) -> void:
	_log_buffer = log_buffer


func set_response_sink(sink: Callable) -> void:
	_response_sink = sink


## Register a command handler. The callable receives (params: Dictionary) -> Dictionary
## or an awaitable that eventually returns one.
func register(command_name: String, handler: Callable) -> void:
	_handlers[command_name] = handler


## Invoke a registered handler directly by name. Returns the handler's raw
## response dict (no request_id or status wrapping). Returns an UNKNOWN_COMMAND
## error dict if the command is not registered. Used by batch_execute.
func dispatch_direct(command: String, params: Dictionary) -> Dictionary:
	if not _handlers.has(command):
		return McpErrorCodes.make(McpErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)
	return await _call_handler(command, params)


## Whether a command is registered.
func has_command(command: String) -> bool:
	return _handlers.has(command)


## Rank registered commands by similarity to `cmd_name` and return the top `limit`
## matches. Uses Godot's built-in String.similarity() (0.0–1.0). Returns an empty
## array if no candidates clear the threshold. Used by batch_execute to surface
## "did you mean" suggestions when an unknown command is passed.
func suggest_similar(cmd_name: String, limit: int = 3, threshold: float = 0.5) -> Array[String]:
	if cmd_name.is_empty() or _handlers.is_empty():
		return []
	var scored: Array = []
	for name in _handlers.keys():
		var score: float = cmd_name.similarity(name)
		if score >= threshold:
			scored.append([score, name])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var result: Array[String] = []
	for i in range(min(limit, scored.size())):
		result.append(scored[i][1])
	return result


## Enqueue a raw command dict received from the WebSocket.
func enqueue(cmd: Dictionary) -> void:
	_command_queue.append(cmd)


## Handlers whose response flows out-of-band (e.g. debugger-channel capture)
## return this marker so tick() skips auto-sending a response. The handler is
## responsible for pushing the final response via Connection._send_json when
## the async operation completes. The request_id is threaded through params
## under the "_request_id" key so the handler can correlate the response.
const DEFERRED_RESPONSE := {"_deferred": true}


## Start draining the queue. No-op if a drain is already in flight.
func tick(budget_ms: float = 4.0) -> void:
	if _draining or _command_queue.is_empty():
		return
	_drain(budget_ms)


## Budget only bounds how many new commands we *start* in one window;
## once a handler awaits we always see it through to completion.
func _drain(budget_ms: float) -> void:
	_draining = true
	var start := Time.get_ticks_msec()
	while not _command_queue.is_empty() and (Time.get_ticks_msec() - start) < budget_ms:
		var cmd: Dictionary = _command_queue.pop_front()
		var response: Dictionary = await _dispatch(cmd)
		if response.get("_deferred", false):
			continue
		if _response_sink.is_valid():
			_response_sink.call(response)
	_draining = false


func _dispatch(cmd: Dictionary) -> Dictionary:
	var request_id: String = cmd.get("request_id", "")
	var command: String = cmd.get("command", "")
	var raw_params: Dictionary = cmd.get("params", {})
	## Duplicate so the internal _request_id key we thread through doesn't
	## mutate the queued command's params (which is the same dict we're
	## about to JSON-log below, and which later readers like batch_execute
	## shouldn't see dispatcher-internal metadata from).
	var params: Dictionary = raw_params.duplicate()
	params["_request_id"] = request_id

	if mcp_logging:
		_log_buffer.log("[recv] %s(%s)" % [command, JSON.stringify(raw_params)])

	var result: Dictionary

	if _handlers.has(command):
		result = await _call_handler(command, params)
	else:
		result = McpErrorCodes.make(McpErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)

	if result.get("_deferred", false):
		if mcp_logging:
			_log_buffer.log("[defer] %s (request %s)" % [command, request_id])
		return result

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


func _call_handler(command: String, params: Dictionary) -> Dictionary:
	var result: Dictionary = await _handlers[command].call(params)
	## Handlers must return {"data": ...} on success or {"error": ...} on failure.
	## Anything else (null, empty, missing keys) means the handler crashed
	## mid-call — GDScript swallows the error and returns an empty dict.
	if result == null or not (result.has("data") or result.has("error") or result.has("_deferred")):
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Handler '%s' returned malformed result (likely crashed — check Godot console)" % command,
		)
	return result
