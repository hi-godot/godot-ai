@tool
extends McpClient

## Claude Desktop's mcpServers entries are stdio-only, so we bridge our HTTP
## server through `npx mcp-remote <url>`.


func _init() -> void:
	id = "claude_desktop"
	display_name = "Claude Desktop"
	config_type = "json"
	doc_url = "https://claude.ai/download"
	path_template = {
		"darwin": "~/Library/Application Support/Claude/claude_desktop_config.json",
		"windows": "$APPDATA/Claude/claude_desktop_config.json",
		"linux": "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"command": "npx", "args": ["-y", "mcp-remote", url]}
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		# Accept both the bridge form we write and a future url-style entry.
		if entry.get("url", "") == url:
			return true
		var args = entry.get("args", [])
		return entry.get("command", "") == "npx" and args is Array and args.has(url)
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"command\": \"npx\", \"args\": [\"-y\", \"mcp-remote\", \"%s\"] }" % [path, name, url]
