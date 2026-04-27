@tool
extends McpClient

## OpenCode stores MCP servers under `mcp.<name>` (not the typical mcpServers
## map) and uses `type: "remote"` for HTTP servers.


func _init() -> void:
	id = "opencode"
	display_name = "OpenCode"
	config_type = "json"
	doc_url = "https://opencode.ai/docs/mcp-servers"
	path_template = {
		"unix": "~/.config/opencode/opencode.json",
		"windows": "$HOME/.config/opencode/opencode.json",
	}
	server_key_path = PackedStringArray(["mcp"])
	entry_extra_fields = {"type": "remote"}
	## `enabled` is user-state (they may have toggled the server off).
	entry_initial_fields = {"enabled": true}
	detect_paths = PackedStringArray(path_template.values())
