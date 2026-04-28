@tool
class_name McpCliStrategy
extends RefCounted

## Strategy for MCP clients that own their own state via a CLI (e.g.
## `claude mcp add`). Reads `cli_register_template` / `cli_unregister_template`
## / `cli_status_args` from the descriptor and substitutes `{name}` / `{url}`
## tokens. No descriptor-supplied Callables — see `_base.gd` for why.
##
## Every shell-out goes through `McpCliExec.run`, which wraps the call in a
## wall-clock timeout. A hung CLI (e.g. `claude mcp list` under
## inter-Claude-Code contention) gets killed at the budget instead of
## locking up the caller forever — see issues #238 / #239.

const _CONFIGURE_TIMEOUT_MS := 10000
const _REMOVE_TIMEOUT_MS := 10000
const _STATUS_TIMEOUT_MS := 6000


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}

	# Best-effort prior cleanup so re-configure is idempotent. Bounded to
	# the same budget — a hung unregister shouldn't block the configure
	# that follows.
	if not client.cli_unregister_template.is_empty():
		var pre_args := _format_args(client.cli_unregister_template, server_name, server_url)
		McpCliExec.run(cli, pre_args, _REMOVE_TIMEOUT_MS)

	if client.cli_register_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_register_template" % client.display_name}
	var args := _format_args(client.cli_register_template, server_name, server_url)
	var result := McpCliExec.run(cli, args, _CONFIGURE_TIMEOUT_MS)
	if result.get("timed_out", false):
		return {
			"status": "error",
			"message": "Configure %s timed out after %ds — see 'Run this manually' below to retry by hand" % [
				client.display_name, _CONFIGURE_TIMEOUT_MS / 1000,
			],
		}
	if result.get("spawn_failed", false):
		return {"status": "error", "message": "Failed to spawn %s CLI" % client.display_name}
	if int(result.get("exit_code", -1)) == 0:
		return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}
	## `claude mcp add` writes its real failure diagnostics to stderr, so
	## prefer `output` (stdout + stderr) over `stdout` alone — otherwise
	## the user sees "exit code 1" instead of the actual error.
	var combined := str(result.get("output", "")).strip_edges()
	var err := combined if not combined.is_empty() else "exit code %d" % int(result.get("exit_code", -1))
	return {"status": "error", "message": "Failed to configure %s: %s" % [client.display_name, err]}


## Run the descriptor's `cli_status_args`, scan stdout for `server_name` and
## `server_url`. The matching rule is the only sensible one for "list MCP
## entries" output across CLI clients we currently support: name AND url
## present → CONFIGURED; name only → MISMATCH; neither → NOT_CONFIGURED.
static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	return check_status_with_cli_path(client, server_name, server_url, _resolve_cli(client))


static func check_status_with_cli_path(client: McpClient, server_name: String, server_url: String, cli: String) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, cli).get("status", McpClient.Status.NOT_CONFIGURED)


## Detailed variant used by the dock's refresh worker so it can surface a
## "probe timed out" badge on the affected row instead of silently
## conflating the timeout with NOT_CONFIGURED. Returns
## `{"status": Status, "error_msg": String}`. The caller plumbs
## `error_msg` straight into `_apply_row_status`.
static func check_status_details(client: McpClient, server_name: String, server_url: String, cli: String) -> Dictionary:
	if cli.is_empty():
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	if client.cli_status_args.is_empty():
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	var result := McpCliExec.run(cli, McpClient._array_from_packed(client.cli_status_args), _STATUS_TIMEOUT_MS)
	if result.get("timed_out", false):
		return _status_details(McpClient.Status.ERROR, "probe timed out")
	if result.get("spawn_failed", false):
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	if int(result.get("exit_code", -1)) != 0:
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	var text := str(result.get("stdout", ""))
	if text.find(server_name) < 0:
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	## Server registered, but pointing somewhere else — drift after a
	## port change. Surface as mismatch so the dock offers Reconfigure.
	if text.find(server_url) < 0:
		return _status_details(McpClient.Status.CONFIGURED_MISMATCH)
	return _status_details(McpClient.Status.CONFIGURED)


static func _status_details(status: McpClient.Status, error_msg: String = "") -> Dictionary:
	return {"status": status, "error_msg": error_msg}


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s CLI not found" % client.display_name}
	if client.cli_unregister_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_unregister_template" % client.display_name}
	var args := _format_args(client.cli_unregister_template, server_name, "")
	var result := McpCliExec.run(cli, args, _REMOVE_TIMEOUT_MS)
	if result.get("timed_out", false):
		return {
			"status": "error",
			"message": "Remove %s timed out after %ds — see 'Run this manually' below to retry by hand" % [
				client.display_name, _REMOVE_TIMEOUT_MS / 1000,
			],
		}
	if result.get("spawn_failed", false):
		return {"status": "error", "message": "Failed to spawn %s CLI" % client.display_name}
	if int(result.get("exit_code", -1)) == 0:
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	## `claude mcp add` writes its real failure diagnostics to stderr, so
	## prefer `output` (stdout + stderr) over `stdout` alone — otherwise
	## the user sees "exit code 1" instead of the actual error.
	var combined := str(result.get("output", "")).strip_edges()
	var err := combined if not combined.is_empty() else "exit code %d" % int(result.get("exit_code", -1))
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


static func resolve_cli_path(client: McpClient) -> String:
	return _resolve_cli(client)
