@tool
extends McpClient


func _init() -> void:
	id = "cherry_studio"
	display_name = "Cherry Studio"
	config_type = "json"
	doc_url = "https://docs.cherry-ai.com/advanced-basic/mcp"
	path_template = {
		"darwin": "~/Library/Application Support/CherryStudio/mcp_servers.json",
		"windows": "$APPDATA/CherryStudio/mcp_servers.json",
		"linux": "$XDG_CONFIG_HOME/CherryStudio/mcp_servers.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_extra_fields = {"type": "streamableHttp"}
	## `isActive` is user-state (they may have toggled the server off in the UI).
	## Seed on first Configure but preserve across reconfigure.
	entry_initial_fields = {"isActive": true}
	detect_paths = PackedStringArray(path_template.values())
