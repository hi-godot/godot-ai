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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "remote", "url": url, "enabled": true}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcp\":\n  \"%s\": { \"type\": \"remote\", \"url\": \"%s\", \"enabled\": true }" % [path, name, url]
