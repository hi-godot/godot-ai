@tool
class_name ClientHandler
extends RefCounted

## Handles MCP client configuration commands.


func configure_client(params: Dictionary) -> Dictionary:
	var client_name: String = params.get("client", "")
	var client_type: int = McpClientConfigurator.client_type_from_string(client_name)
	if client_type < 0:
		var valid_names := ", ".join(McpClientConfigurator.CLIENT_TYPE_MAP.keys())
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Unknown client: %s. Use: %s" % [client_name, valid_names])
	var result := McpClientConfigurator.configure(client_type as McpClientConfigurator.ClientType)
	if result.get("status") == "error":
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR,
			result.get("message", "Configuration failed for '%s' (check logs for details)" % client_name))
	return {"data": result}


func check_client_status(_params: Dictionary) -> Dictionary:
	var results := {}
	for client_name in McpClientConfigurator.CLIENT_TYPE_MAP:
		var client_type: McpClientConfigurator.ClientType = McpClientConfigurator.CLIENT_TYPE_MAP[client_name]
		var status := McpClientConfigurator.check_status(client_type)
		match status:
			McpClientConfigurator.ConfigStatus.CONFIGURED:
				results[client_name] = "configured"
			McpClientConfigurator.ConfigStatus.NOT_CONFIGURED:
				results[client_name] = "not_configured"
			_:
				results[client_name] = "error"
	return {"data": {"clients": results}}
