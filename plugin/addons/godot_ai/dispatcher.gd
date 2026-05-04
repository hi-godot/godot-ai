@tool
class_name McpDispatcher
extends RefCounted

## Routes incoming commands to handlers and manages the command queue
## with a per-frame time budget.

var _command_queue: Array[Dictionary] = []
var _handlers: Dictionary = {}  # command_name -> Callable
var _pending_deferred: Dictionary = {}  # request_id -> {command, started_ms, timeout_ms}
var _log_buffer
var mcp_logging := true
var deferred_timeout_overrides_ms: Dictionary = {}

const DEFAULT_DEFERRED_TIMEOUT_MS := 4500
const DEFERRED_TIMEOUT_MS_BY_COMMAND := {
	"create_script": 4500,
	"stop_project": 4500,
	"take_screenshot": 30000,
}
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")


func _init(log_buffer: McpLogBuffer) -> void:
	_log_buffer = log_buffer


## Register a command handler. The callable receives (params: Dictionary) -> Dictionary.
func register(command_name: String, handler: Callable) -> void:
	_handlers[command_name] = handler


## Drop registered handlers, queued commands, and the log buffer ref so
## plugin.gd can release RefCounted handlers before Godot reloads their
## class_name scripts (issue #46). After clear(), the dispatcher is inert.
func clear() -> void:
	_handlers.clear()
	_command_queue.clear()
	_pending_deferred.clear()
	_log_buffer = null


## Invoke a registered handler directly by name. Returns the handler's raw
## response dict (no request_id or status wrapping). Returns an UNKNOWN_COMMAND
## error dict if the command is not registered. Used by batch_execute.
func dispatch_direct(command: String, params: Dictionary) -> Dictionary:
	if not _handlers.has(command):
		return ErrorCodes.make(ErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)
	return _call_handler(command, params)


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


func pending_deferred_count() -> int:
	return _pending_deferred.size()


func clear_deferred_responses() -> void:
	_pending_deferred.clear()


func has_pending_deferred_response(request_id: String) -> bool:
	return request_id.is_empty() or _pending_deferred.has(request_id)


func complete_deferred_response(request_id: String) -> bool:
	if request_id.is_empty():
		return true
	if not _pending_deferred.has(request_id):
		return false
	_pending_deferred.erase(request_id)
	return true


## Handlers whose response flows out-of-band (e.g. debugger-channel capture)
## return this marker so tick() skips auto-sending a response. The handler is
## responsible for pushing the final response via McpConnection._send_json when
## the async operation completes. The dispatcher tracks the request_id and emits
## DEFERRED_TIMEOUT if the out-of-band response never arrives. The request_id is
## threaded through params under the "_request_id" key so the handler can
## correlate the response.
const DEFERRED_RESPONSE := {"_deferred": true}


## Process queued commands within a frame budget (milliseconds).
## Returns an array of response dictionaries to send back.
func tick(budget_ms: float = 4.0) -> Array[Dictionary]:
	var responses: Array[Dictionary] = _collect_deferred_timeouts()
	var start := Time.get_ticks_msec()
	var idx := 0

	while idx < _command_queue.size() and (Time.get_ticks_msec() - start) < budget_ms:
		var cmd: Dictionary = _command_queue[idx]
		var response := _dispatch(cmd)
		if not response.get("_deferred", false):
			responses.append(response)
		idx += 1

	if idx > 0:
		_command_queue = _command_queue.slice(idx)

	return responses


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
		result = _call_handler(command, params)
	else:
		result = ErrorCodes.make(ErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)

	if result.get("_deferred", false):
		_register_deferred(request_id, command)
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


## Truncate JSON-stringified args at this many chars when stuffing them into
## a malformed-result error message — large dicts shouldn't bloat the
## response, but a few hundred chars usually pinpoints which param was the
## wrong shape.
const _MALFORMED_ARGS_MAX := 400


func _call_handler(command: String, params: Dictionary) -> Dictionary:
	var result: Dictionary = _handlers[command].call(params)
	## Handlers must return {"data": ...} on success or {"error": ...} on failure.
	## Anything else (null, empty, missing keys) means the handler crashed
	## mid-call — GDScript swallows the error and returns an empty dict.
	if result == null or not (result.has("data") or result.has("error") or result.has("_deferred")):
		var safe_params := params.duplicate()
		safe_params.erase("_request_id")
		var args_json := JSON.stringify(safe_params)
		if args_json.length() > _MALFORMED_ARGS_MAX:
			args_json = args_json.substr(0, _MALFORMED_ARGS_MAX) + "..."
		var backtrace := _capture_compact_backtrace()
		var msg := (
			"Handler '%s' returned malformed result — likely a runtime error in the handler "
			+ "(e.g. param type mismatch). Args received: %s"
		) % [command, args_json]
		if not backtrace.is_empty():
			msg += "\nBacktrace:\n%s" % backtrace
		if mcp_logging and _log_buffer != null:
			var compact_backtrace := backtrace.replace("\n", " | ")
			_log_buffer.log(
				"[error] %s -> malformed result; args=%s; backtrace=%s"
				% [command, args_json, compact_backtrace]
			)
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, msg)
	return result


func _register_deferred(request_id: String, command: String) -> void:
	if request_id.is_empty():
		return
	_pending_deferred[request_id] = {
		"command": command,
		"started_ms": Time.get_ticks_msec(),
		"timeout_ms": _deferred_timeout_ms_for_command(command),
	}


func _deferred_timeout_ms_for_command(command: String) -> int:
	if deferred_timeout_overrides_ms.has(command):
		return int(deferred_timeout_overrides_ms[command])
	return int(DEFERRED_TIMEOUT_MS_BY_COMMAND.get(command, DEFAULT_DEFERRED_TIMEOUT_MS))


func _collect_deferred_timeouts() -> Array[Dictionary]:
	var responses: Array[Dictionary] = []
	if _pending_deferred.is_empty():
		return responses
	var now := Time.get_ticks_msec()
	for request_id in _pending_deferred.keys():
		var entry: Dictionary = _pending_deferred[request_id]
		var timeout_ms: int = entry.get("timeout_ms", DEFAULT_DEFERRED_TIMEOUT_MS)
		var elapsed_ms := now - int(entry.get("started_ms", now))
		if elapsed_ms < timeout_ms:
			continue
		_pending_deferred.erase(request_id)
		var command: String = entry.get("command", "")
		var response := ErrorCodes.make(
			ErrorCodes.DEFERRED_TIMEOUT,
			"Deferred response for '%s' timed out after %dms" % [command, timeout_ms]
		)
		response["request_id"] = request_id
		response["error"]["data"] = {
			"command": command,
			"elapsed_ms": elapsed_ms,
			"timeout_ms": timeout_ms,
		}
		responses.append(response)
		if mcp_logging and _log_buffer != null:
			_log_buffer.log("[defer] %s (request %s) -> timeout" % [command, request_id])
	return responses


static func _capture_compact_backtrace(max_frames: int = 8) -> String:
	if Engine.has_method("capture_script_backtraces"):
		var traces: Array = Engine.capture_script_backtraces(false)
		for bt in traces:
			if bt != null and not bt.is_empty():
				return _trim_backtrace_string(bt.format(0, 2), max_frames)
	return _format_stack_frames(get_stack(), max_frames)


static func _trim_backtrace_string(text: String, max_frames: int) -> String:
	var lines := text.strip_edges().split("\n")
	var kept: Array[String] = []
	for i in range(min(lines.size(), max_frames)):
		kept.append(lines[i].strip_edges())
	return "\n".join(kept)


static func _format_stack_frames(frames: Array, max_frames: int) -> String:
	var lines: Array[String] = []
	for i in range(min(frames.size(), max_frames)):
		var frame: Dictionary = frames[i]
		lines.append(
			"%s:%s in %s"
			% [
				frame.get("source", "?"),
				frame.get("line", 0),
				frame.get("function", "?"),
			]
		)
	return "\n".join(lines)
