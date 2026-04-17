@tool
extends McpClient

## VS Code (stable) reads MCP servers from per-user mcp.json under
## `servers.<name>` with `{ "type": "http", "url": ... }`.


func _init() -> void:
	id = "vscode"
	display_name = "VS Code"
	config_type = "json"
	doc_url = "https://code.visualstudio.com/docs/copilot/chat/mcp-servers"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/mcp.json",
		"windows": "$APPDATA/Code/User/mcp.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/mcp.json",
	}
	server_key_path = PackedStringArray(["servers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "http", "url": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"servers\":\n  \"%s\": { \"type\": \"http\", \"url\": \"%s\" }" % [path, name, url]
