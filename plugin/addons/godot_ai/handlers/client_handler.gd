@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles MCP client configuration commands.


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


func check_client_status(_params: Dictionary) -> Dictionary:
	var clients := []
	# Claude Desktop and Codex share the same attach launch. Resolve it once for
	# the aggregate status command instead of repeating the cold discovery path
	# per command-shaped client and exhausting the command's 5-second budget.
	var launch_context := McpClientConfigurator.capture_launch_context()
	var server_url := McpClientConfigurator.server_url_from(launch_context)
	var resolved_launch := McpClientConfigurator.resolve_attach_launch(launch_context)
	for client_id in McpClientConfigurator.client_ids():
		var details := McpClientConfigurator.check_status_details_for_url_with_cli_path(
			client_id, server_url, "", launch_context, resolved_launch
		)
		var status = details.get("status", McpClient.Status.NOT_CONFIGURED)
		clients.append({
			"id": client_id,
			"display_name": McpClientConfigurator.client_display_name(client_id),
			"status": McpClient.status_label(status),
			"installed": McpClientConfigurator.is_installed(client_id),
		})
	return {"data": {"clients": clients}}
