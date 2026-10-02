@tool
extends McpClient

## VS Code (stable) reads MCP servers from per-user mcp.json under
## `servers.<name>` with `{ "type": "http", "url": ... }`.


func _init() -> void:
	id = "vscode"
	display_name = "VS Code"
	config_type = "json"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/mcp.json",
		"windows": "$APPDATA/Code/User/mcp.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/mcp.json",
	}
	## The Flathub build keeps its user data in the app's own directory and
	## never reads ~/.config/Code. Verified against com.visualstudio.code
	## 1.139.1: `code --add-mcp` writes the second path, under `servers`.
	config_path_candidates = {
		"linux": [
			path_template["linux"],
			"~/.var/app/com.visualstudio.code/config/Code/User/mcp.json",
		],
	}
	server_key_path = PackedStringArray(["servers"])
	entry_extra_fields = {"type": "http"}
	## Attach migration (#838). VS Code stdio entries are flat command/args/env
	## under `servers` with a documented `type: "stdio"` discriminator
	## (code.visualstudio.com/docs/agents/reference/mcp-configuration). The
	## stdio schema is `additionalProperties: false` (mcpConfiguration.ts), so
	## removing the legacy url/headers is load-bearing — leftovers invalidate
	## the whole entry, and the pin flips the legacy `type: "http"` in place.
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	command_legacy_keys = PackedStringArray(["url", "headers"])
	command_user_fields = PackedStringArray(["env", "envFile", "cwd", "sandboxEnabled", "dev"])
