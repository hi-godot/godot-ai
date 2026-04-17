@tool
class_name McpCliStrategy
extends RefCounted

## Strategy for MCP clients that own their own state via a CLI (e.g.
## `claude mcp add`). Descriptors supply the arg lists; this just runs them.


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}

	# Best-effort prior cleanup so re-configure is idempotent.
	if client.cli_unregister_args.is_valid():
		var pre_args = client.cli_unregister_args.call(server_name)
		OS.execute(cli, pre_args, [], true)

	var args = client.cli_register_args.call(server_name, server_url)
	var output: Array = []
	var exit_code := OS.execute(cli, args, output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}
	var err: String = output[0].strip_edges() if output.size() > 0 else "exit code %d" % exit_code
	return {"status": "error", "message": "Failed to configure %s: %s" % [client.display_name, err]}


static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return McpClient.Status.NOT_CONFIGURED
	if not client.cli_status_check.is_valid():
		return McpClient.Status.NOT_CONFIGURED
	return client.cli_status_check.call(cli, server_name, server_url)


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}
	if not client.cli_unregister_args.is_valid():
		return {"status": "error", "message": "%s descriptor missing cli_unregister_args" % client.display_name}
	var args = client.cli_unregister_args.call(server_name)
	var output: Array = []
	var exit_code := OS.execute(cli, args, output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	var err: String = output[0].strip_edges() if output.size() > 0 else "exit code %d" % exit_code
	return {"status": "error", "message": "Failed to remove %s: %s" % [client.display_name, err]}


static func _resolve_cli(client: McpClient) -> String:
	return McpCliFinder.find(McpClient._array_from_packed(client.cli_names))
