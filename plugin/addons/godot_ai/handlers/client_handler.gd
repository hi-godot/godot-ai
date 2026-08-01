@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles MCP client configuration commands.

var _connection
var _fallback_launch_context := {}


func _init(connection = null, fallback_launch_context = null) -> void:
	_connection = connection
	# Lazy-loading this handler can reload ClientConfigurator's static script and
	# clear its warmed snapshot. Retain the plugin-start capture as a safe
	# fallback; the worker still prefers capture_launch_context()'s live snapshot.
	if fallback_launch_context is Dictionary:
		_fallback_launch_context = fallback_launch_context.duplicate(true)


func configure_client(params: Dictionary) -> Dictionary:
	var client_id: String = params.get("client", "")
	if not McpClientConfigurator.has_client(client_id):
		var valid := ", ".join(McpClientConfigurator.client_ids())
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown client: %s. Use one of: %s" % [client_id, valid])
	var result := McpClientConfigurator.configure(client_id)
	if result.get("status") == "error":
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			result.get("message", "Configuration failed for '%s'" % client_id))
	return {"data": result}


func remove_client(params: Dictionary) -> Dictionary:
	var client_id: String = params.get("client", "")
	if not McpClientConfigurator.has_client(client_id):
		var valid := ", ".join(McpClientConfigurator.client_ids())
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown client: %s. Use one of: %s" % [client_id, valid])
	var result := McpClientConfigurator.remove(client_id)
	if result.get("status") == "error":
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			result.get("message", "Removal failed for '%s'" % client_id))
	return {"data": result}


func check_client_status(params: Dictionary) -> Dictionary:
	var request_id: String = params.get("_request_id", "")
	if _connection == null or request_id.is_empty():
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Client status requires a deferred request context.",
		)
	# Match the dock refresh worker's cold-load guard. This is pure-memory and
	# performs no launcher discovery, CLI lookup, or config/status probe.
	McpClientConfigurator.warm_status_worker_bytecode()
	# The aggregate command has a 30-second budget. Its worker resolves the
	# shared Claude Desktop/Codex attach launch once, then reuses it for every
	# command-shaped client instead of repeating cold launcher discovery.
	# Start the worker from the deferred finisher after its first frame. That
	# lets the dispatcher register this request before any probe can complete.
	_finish_client_status_deferred(
		McpClientConfigurator.run_client_status_sweep.bind(_fallback_launch_context),
		request_id,
		_connection,
	)
	return McpDispatcher.DEFERRED_RESPONSE


## Static so the coroutine can safely outlive this lazily-created handler.
## The first-frame yield is load-bearing: check_client_status() must return the
## deferred sentinel before the worker starts and can produce a response.
static func _finish_client_status_deferred(
	worker_callable: Callable, request_id: String, connection
) -> void:
	if not is_instance_valid(connection):
		return
	var tree: SceneTree = connection.get_tree()
	if tree == null:
		return
	await tree.process_frame
	if not is_instance_valid(connection):
		return
	var worker := Thread.new()
	var start_error := worker.start(worker_callable)
	if start_error != OK:
		connection.send_deferred_response(request_id, ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Could not start client status worker (error %d)." % start_error,
		))
		return
	while worker.is_alive():
		await tree.process_frame
	var payload: Variant = worker.wait_to_finish()
	if not is_instance_valid(connection):
		return
	if not payload is Dictionary:
		payload = ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Client status worker returned an invalid response.",
		)
	elif payload.has("worker_error"):
		payload = ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			str(payload.get("worker_error", "Client status worker failed.")),
		)
	connection.send_deferred_response(request_id, payload)
