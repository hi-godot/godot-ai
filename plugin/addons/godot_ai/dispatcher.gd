@tool
class_name McpDispatcher
extends RefCounted

## Routes incoming commands to handlers and manages the command queue
## with a per-frame time budget.

var _command_queue: Array[Dictionary] = []
var _handlers: Dictionary = {}  # command_name -> Callable
## Lazy handler registration (#736): plugin.gd registers command names
## against a handler key plus a per-handler script path and constructor
## args, and the handler script is load()ed and instantiated at the FIRST
## dispatch of one of its commands. This keeps the ~30 handler scripts
## (and everything they preload) out of plugin.gd's eager compile
## closure, which stalled "Initializing plugins" on every editor boot.
## Materialized commands are promoted into `_handlers`, so the lazy dicts
## are only consulted on the first call per command.
var _lazy_handler_specs: Dictionary = {}  # handler_key -> {path: String, args: Array}
var _lazy_handler_cache: Dictionary = {}  # handler_key -> handler instance
var _lazy_commands: Dictionary = {}  # command_name -> {handler: String, method: StringName}
var _pending_deferred: Dictionary = {}  # request_id -> {command, started_ms, timeout_ms}
var _log_buffer
var _surfaced_error_tracker
## The McpConnection whose pause_processing handlers flip around unsafe
## editor operations (#288 guard). Set by plugin.gd; untyped to honor the
## self-update field-storage policy. When set, _call_handler restores the
## pause depth a crashed handler left unbalanced (#712) — without this a
## single handler crash inside a pause window freezes the transport
## forever (pause has no watchdog or disconnect reset by design).
var pause_target
var mcp_logging := true
var deferred_timeout_overrides_ms: Dictionary = {}

const DEFAULT_DEFERRED_TIMEOUT_MS := 4500
const DEFERRED_TIMEOUT_MS_BY_COMMAND := {
	"create_script": 4500,
	## Fresh-`.gd` writes defer through the same import-settle window as
	## create_script (#714) — same headroom over IMPORT_SETTLE_MAX_MSEC.
	"write_file": 4500,
	"stop_project": 4500,
	"run_project": 6000,
	"take_screenshot": 30000,
	"game_eval": 15000,
	"game_command": 15000,
	"scan_filesystem": 30000,
}
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const FuzzySuggestions := preload("res://addons/godot_ai/utils/fuzzy_suggestions.gd")


func _init(log_buffer: McpLogBuffer, surfaced_error_tracker = null) -> void:
	_log_buffer = log_buffer
	_surfaced_error_tracker = surfaced_error_tracker


## Register a command handler. The callable receives (params: Dictionary) -> Dictionary.
func register(command_name: String, handler: Callable) -> void:
	_handlers[command_name] = handler


## Declare a lazily-constructed handler (#736). `script_path` is load()ed
## and instantiated with `ctor_args` at the first dispatch of any command
## registered against `handler_key` via register_lazy. `ctor_args` may hold
## plugin-lifetime objects (connection, buffers, the dispatcher itself for
## batch); clear() drops them so teardown ordering matches the old eager
## registration (#46).
func register_lazy_handler(handler_key: String, script_path: String, ctor_args: Array) -> void:
	_lazy_handler_specs[handler_key] = {"path": script_path, "args": ctor_args}


## Register a command that resolves to `method` on the lazily-constructed
## handler declared under `handler_key`. Same dispatch semantics as
## register(); only construction timing differs.
func register_lazy(command_name: String, handler_key: String, method: StringName) -> void:
	_lazy_commands[command_name] = {"handler": handler_key, "method": method}


## Drop registered handlers, queued commands, and the log buffer ref so
## plugin.gd can release RefCounted handlers before Godot reloads their
## class_name scripts (issue #46). After clear(), the dispatcher is inert.
func clear() -> void:
	_handlers.clear()
	## Release lazily-constructed handler instances (and the ctor args that
	## reference plugin-lifetime objects) at the same teardown point where
	## eager handler Callables used to be dropped — their destructors must
	## run while their scripts are still loaded (#46). This also breaks the
	## dispatcher -> batch handler -> dispatcher ref cycle.
	_lazy_handler_specs.clear()
	_lazy_handler_cache.clear()
	_lazy_commands.clear()
	_command_queue.clear()
	_pending_deferred.clear()
	_log_buffer = null
	_surfaced_error_tracker = null
	pause_target = null


## Drop queued-but-unexecuted commands. Called by the connection on
## disconnect (#712): commands queued by the previous connection must not
## execute under the next one — the requester is gone, its in-flight
## futures were already failed server-side, and a mutation landing after
## reconnect is a surprise write nobody can correlate. Deferred bookkeeping
## has its own reset (clear_deferred_responses).
func clear_command_queue() -> void:
	_command_queue.clear()


## Invoke a registered handler directly by name. Returns the handler's raw
## response dict (no request_id or status wrapping). Returns an UNKNOWN_COMMAND
## error dict if the command is not registered. Used by batch_execute.
func dispatch_direct(command: String, params: Dictionary) -> Dictionary:
	if not has_command(command):
		return ErrorCodes.make(ErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)
	## Strip the reserved deferred-reply key: only _dispatch may thread it.
	## A caller-supplied _request_id (e.g. inside a batch_execute
	## sub-command's params) would flip a deferred-capable handler into
	## deferred mode against a request id the dispatcher never registered —
	## the direct caller would get the DEFERRED sentinel instead of a result
	## and the out-of-band reply would be dropped as expired.
	if params.has("_request_id"):
		params = params.duplicate()
		params.erase("_request_id")
	return _call_handler(command, params)


## Whether a command is registered (eagerly or lazily).
func has_command(command: String) -> bool:
	return _handlers.has(command) or _lazy_commands.has(command)


## Rank registered commands by similarity to `cmd_name` and return the top `limit`
## matches. Uses Godot's built-in String.similarity() (0.0–1.0). Returns an empty
## array if no candidates clear the threshold. Used by batch_execute to surface
## "did you mean" suggestions when an unknown command is passed.
func suggest_similar(cmd_name: String, limit: int = 3, threshold: float = 0.5) -> Array[String]:
	return FuzzySuggestions.rank(cmd_name, _registered_command_names(), limit, threshold, 0.0, 0.0)


## Union of eagerly-registered and lazily-registered command names.
## Materialized lazy commands live in both dicts, so dedupe via keys.
func _registered_command_names() -> Array:
	var names: Dictionary = {}
	for command in _handlers:
		names[command] = true
	for command in _lazy_commands:
		names[command] = true
	return names.keys()


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

	if has_command(command):
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
	## Stamp live editor readiness onto every command-response envelope so
	## the server's `Session.readiness` cache self-heals on the very next
	## tool call. Without this, a single dropped `readiness_changed` event
	## (or a one-frame race around `pause_processing`) leaves the cache
	## stuck at "playing" / "importing" long after the editor has settled,
	## and write tools fail with EDITOR_NOT_READY against a writable editor.
	## See connection.gd::send_deferred_response for the deferred-response
	## counterpart, which stamps the same field.
	result["readiness"] = McpConnection.get_readiness()
	_stamp_error_watermark(result)

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
	if not _handlers.has(command):
		var materialize_error := _materialize_lazy_command(command)
		if not materialize_error.is_empty():
			return materialize_error
	## #712: a handler that crashes between pause_processing = true and its
	## matching false leaves the pause depth unbalanced — GDScript swallows
	## the error, the dispatcher reports "malformed result", and the
	## transport stays paused FOREVER (no watchdog, no disconnect reset).
	## Restore balance at this boundary: the depth a handler leaves behind
	## must equal the depth it started with.
	var pause_depth_before: int = pause_target.pause_depth() if pause_target != null else 0
	var result: Dictionary = _handlers[command].call(params)
	if pause_target != null and pause_target.pause_depth() > pause_depth_before:
		var leaked: int = pause_target.pause_depth() - pause_depth_before
		while pause_target.pause_depth() > pause_depth_before:
			pause_target.resume()
		if mcp_logging and _log_buffer != null:
			_log_buffer.log(
				"[error] %s leaked %d pause_processing level(s) — restored (handler crash?)"
				% [command, leaked]
			)
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


## Resolve a lazily-registered command into a live Callable in `_handlers`.
## Loads + constructs the owning handler on first use (cached per handler
## key, so one load() covers every command the handler serves). Returns an
## empty dict on success or a protocol error dict on failure — a missing
## script or method is a plugin packaging bug and must surface loudly, not
## as a silent no-op.
func _materialize_lazy_command(command: String) -> Dictionary:
	var command_spec: Dictionary = _lazy_commands.get(command, {})
	if command_spec.is_empty():
		return ErrorCodes.make(ErrorCodes.UNKNOWN_COMMAND, "Unknown command: %s" % command)
	var handler_key: String = command_spec["handler"]
	var instance = _lazy_handler_cache.get(handler_key)
	if instance == null:
		var handler_spec: Dictionary = _lazy_handler_specs.get(handler_key, {})
		if handler_spec.is_empty():
			return ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				"No lazy handler '%s' declared for command '%s'" % [handler_key, command]
			)
		## Existence-check first so a missing script surfaces as one clean
		## protocol error instead of also spraying engine load errors.
		if not ResourceLoader.exists(handler_spec["path"]):
			return ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				"Missing handler script '%s' for command '%s'" % [handler_spec["path"], command]
			)
		var script := load(handler_spec["path"]) as GDScript
		if script == null:
			return ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				"Failed to load handler script '%s' for command '%s'" % [handler_spec["path"], command]
			)
		instance = script.callv("new", handler_spec["args"])
		if instance == null:
			return ErrorCodes.make(
				ErrorCodes.INTERNAL_ERROR,
				"Failed to construct handler '%s' for command '%s'" % [handler_key, command]
			)
		_lazy_handler_cache[handler_key] = instance
	var method: StringName = command_spec["method"]
	if not instance.has_method(method):
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Handler '%s' has no method '%s' for command '%s'" % [handler_key, method, command]
		)
	_handlers[command] = Callable(instance, method)
	return {}


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
		## Same envelope-level readiness stamp as `_dispatch` — keep the
		## self-heal channel symmetric across every reply shape the
		## dispatcher emits so the server cache can't drift just because
		## the editor happened to time out a deferred command.
		response["readiness"] = McpConnection.get_readiness()
		_stamp_error_watermark(response)
		responses.append(response)
		if mcp_logging and _log_buffer != null:
			_log_buffer.log("[defer] %s (request %s) -> timeout" % [command, request_id])
	return responses


func _stamp_error_watermark(response: Dictionary) -> void:
	McpSurfacedErrorTracker.stamp_watermark(response, _surfaced_error_tracker)


static func _capture_compact_backtrace(max_frames: int = 8) -> String:
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
