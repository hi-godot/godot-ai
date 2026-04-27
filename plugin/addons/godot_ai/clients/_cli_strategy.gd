@tool
class_name McpCliStrategy
extends RefCounted

## Strategy for MCP clients that own their own state via a CLI (e.g.
## `claude mcp add`). Reads `cli_register_template` / `cli_unregister_template`
## / `cli_status_args` from the descriptor and substitutes `{name}` / `{url}`
## tokens. No descriptor-supplied Callables — see `_base.gd` for why.


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}

	# Best-effort prior cleanup so re-configure is idempotent.
	if not client.cli_unregister_template.is_empty():
		var pre_args := _format_args(client.cli_unregister_template, server_name, server_url)
		OS.execute(cli, pre_args, [], true)

	if client.cli_register_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_register_template" % client.display_name}
	var args := _format_args(client.cli_register_template, server_name, server_url)
	var output: Array = []
	var exit_code := OS.execute(cli, args, output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}
	var err: String = output[0].strip_edges() if output.size() > 0 else "exit code %d" % exit_code
	return {"status": "error", "message": "Failed to configure %s: %s" % [client.display_name, err]}


## Run the descriptor's `cli_status_args`, scan stdout for `server_name` and
## `server_url`. The matching rule is the only sensible one for "list MCP
## entries" output across CLI clients we currently support: name AND url
## present → CONFIGURED; name only → MISMATCH; neither → NOT_CONFIGURED.
static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return McpClient.Status.NOT_CONFIGURED
	if client.cli_status_args.is_empty():
		return McpClient.Status.NOT_CONFIGURED
	var output: Array = []
	var exit_code := OS.execute(cli, McpClient._array_from_packed(client.cli_status_args), output, true)
	if exit_code != 0 or output.is_empty():
		return McpClient.Status.NOT_CONFIGURED
	var text: String = output[0]
	if text.find(server_name) < 0:
		return McpClient.Status.NOT_CONFIGURED
	## Server registered, but pointing somewhere else — drift after a
	## port change. Surface as mismatch so the dock offers Reconfigure.
	if text.find(server_url) < 0:
		return McpClient.Status.CONFIGURED_MISMATCH
	return McpClient.Status.CONFIGURED


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}
	if client.cli_unregister_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_unregister_template" % client.display_name}
	var args := _format_args(client.cli_unregister_template, server_name, "")
	var output: Array = []
	var exit_code := OS.execute(cli, args, output, true)
	if exit_code == 0:
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	var err: String = output[0].strip_edges() if output.size() > 0 else "exit code %d" % exit_code
	return {"status": "error", "message": "Failed to remove %s: %s" % [client.display_name, err]}


## Substitute `{name}` and `{url}` tokens in every template entry.
## Tokens match verbatim — `{name_suffix}` is NOT touched, so callers don't
## have to worry about partial-token collisions in their argv.
static func format_args(template: PackedStringArray, server_name: String, server_url: String) -> Array[String]:
	return _format_args(template, server_name, server_url)


static func _format_args(template: PackedStringArray, server_name: String, server_url: String) -> Array[String]:
	var out: Array[String] = []
	for arg in template:
		var s := String(arg)
		s = s.replace("{name}", server_name)
		s = s.replace("{url}", server_url)
		out.append(s)
	return out


static func _resolve_cli(client: McpClient) -> String:
	return McpCliFinder.find(McpClient._array_from_packed(client.cli_names))
