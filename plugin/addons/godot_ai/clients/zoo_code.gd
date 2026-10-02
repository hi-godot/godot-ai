@tool
extends McpClient


func _init() -> void:
	id = "zoo_code"
	display_name = "Zoo Code"
	config_type = "json"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/mcp_settings.json",
	}
	## globalStorage follows VS Code's user data, which the Flathub build keeps
	## in its own app directory (see vscode.gd).
	config_path_candidates = {
		"linux": [
			path_template["linux"],
			"~/.var/app/com.visualstudio.code/config/Code/User/globalStorage/zoocodeorganization.zoo-code/settings/mcp_settings.json",
		],
	}
	server_key_path = PackedStringArray(["mcpServers"])
	## Local validation against the installed extension shows Zoo stores MCP
	## entries in `settings/mcp_settings.json` under `mcpServers`, matching Roo's
	## shape. Its changelog also references Streamable HTTP support, so pin the
	## transport explicitly to avoid any typeless entry falling back to SSE.
	entry_extra_fields = {"type": "streamable-http"}
	## Preserve user-controlled state across reconfigure, parallel to Roo/Kilo.
	entry_initial_fields = {"disabled": false, "alwaysAllow": []}
	## Attach migration (#838). Zoo's stdio zod schema is Roo's: flat
	## command/args/env(+cwd), `type: z.enum(["stdio"]).optional()`, and
	## url/headers explicitly forbidden on stdio entries (McpHub.ts) — so both
	## are legacy keys and the documented type pin repins "streamable-http".
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	command_legacy_keys = PackedStringArray(["url", "headers"])
	command_initial_fields = {"disabled": false, "alwaysAllow": []}
	command_user_fields = PackedStringArray([
		"disabled", "alwaysAllow", "timeout", "watchPaths", "disabledTools",
		"env", "cwd",
	])
	command_timeout_fields = PackedStringArray(["timeout"])
