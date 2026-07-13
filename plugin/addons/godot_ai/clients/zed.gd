@tool
extends McpClient

## Zed registers MCP servers under `context_servers.<name>` and supports both
## stdio and streamable http transports.


func _init() -> void:
	id = "zed"
	display_name = "Zed"
	config_type = "json"
	path_template = {
		"darwin": "~/.config/zed/settings.json",
		"linux": "$XDG_CONFIG_HOME/zed/settings.json",
		"windows": "$APPDATA/Zed/settings.json",
	}
	server_key_path = PackedStringArray(["context_servers"])
