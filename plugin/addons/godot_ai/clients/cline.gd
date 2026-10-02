@tool
extends McpClient

## Cline is a VS Code extension. Its MCP settings live in VS Code's
## globalStorage under the extension id `saoudrizwan.claude-dev`.


func _init() -> void:
	id = "cline"
	display_name = "Cline"
	config_type = "json"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
	}
	## globalStorage follows VS Code's user data, which the Flathub build keeps
	## in its own app directory (see vscode.gd).
	config_path_candidates = {
		"linux": [
			path_template["linux"],
			"~/.var/app/com.visualstudio.code/config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
		],
	}
	server_key_path = PackedStringArray(["mcpServers"])
	## Cline (like Roo) defaults a typeless entry to SSE transport, which
	## returns HTTP 400 against our streamable-http endpoint on `/mcp`. Pin
	## the type explicitly. Cline's schema uses "streamableHttp" (camelCase,
	## see src/services/mcp/schemas.ts in the cline repo) — distinct from
	## Roo's "streamable-http" string. Parallel to the Roo fix in #190.
	entry_extra_fields = {"type": "streamableHttp"}
	## `disabled` and `autoApprove` are user-state (they may have flipped the
	## entry off, or auto-approved specific tools). Seed on first Configure
	## but preserve across reconfigure — see `entry_initial_fields` in `_base.gd`.
	entry_initial_fields = {"disabled": false, "autoApprove": []}
	## Attach migration (#838). Cline stdio entries are flat command/args/env;
	## its schema accepts `type: "stdio"` and normalizes typeless command
	## entries to it (apps/vscode/src/services/mcp/schemas.ts), so pin the
	## type — that also repins the legacy "streamableHttp" value instead of
	## letting it survive the deep-copy and misroute the transport.
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	command_legacy_keys = PackedStringArray(["url", "headers"])
	command_initial_fields = {"disabled": false, "autoApprove": []}
	command_user_fields = PackedStringArray([
		"disabled", "autoApprove", "timeout", "oauth", "metadata",
		"remoteConfigured", "env", "cwd",
	])
	command_timeout_fields = PackedStringArray(["timeout"])
