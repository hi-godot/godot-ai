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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "streamableHttp", "url": url, "isActive": true}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"type\": \"streamableHttp\", \"url\": \"%s\", \"isActive\": true }" % [path, name, url]
