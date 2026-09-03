@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles MCP client configuration commands.

var _client_jobs


func _init(client_jobs = null) -> void:
	_client_jobs = client_jobs


func configure_client(params: Dictionary) -> Dictionary:
	return _request_client_action(params, "configure")


func remove_client(params: Dictionary) -> Dictionary:
	return _request_client_action(params, "remove")


func _request_client_action(params: Dictionary, action: String) -> Dictionary:
	var client_id: String = params.get("client", "")
	if not McpClientConfigurator.has_client(client_id):
		var valid := ", ".join(McpClientConfigurator.client_ids())
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Unknown client: %s. Use one of: %s" % [client_id, valid])
	var request_id: String = params.get("_request_id", "")
	if _client_jobs == null or request_id.is_empty():
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Client mutations must run as top-level deferred commands.",
		)
	var started: Dictionary = _client_jobs.request_mcp_action(request_id, client_id, action)
	if not bool(started.get("ok", false)):
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			str(started.get("error", "Client worker is unavailable.")),
		)
	return {
		"_deferred": true,
		"_deferred_timeout_ms": int(started.get("deferred_timeout_ms", 0)),
	}


func check_client_status(params: Dictionary) -> Dictionary:
	var request_id: String = params.get("_request_id", "")
	if _client_jobs == null or request_id.is_empty():
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Client status requires a deferred request context.",
		)
	if not _client_jobs.request_mcp_status(request_id):
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Client status worker is unavailable.",
		)
	return McpDispatcher.DEFERRED_RESPONSE
