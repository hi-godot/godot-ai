@tool
extends McpClient


func _init() -> void:
	id = "cursor"
	display_name = "Cursor"
	config_type = "json"
	doc_url = "https://docs.cursor.com/context/model-context-protocol"
	path_template = {"unix": "~/.cursor/mcp.json", "windows": "$USERPROFILE/.cursor/mcp.json"}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\" }" % [path, name, url]
