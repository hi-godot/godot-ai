@tool
extends McpClient


func _init() -> void:
	id = "antigravity"
	display_name = "Antigravity"
	config_type = "json"
	doc_url = "https://www.antigravity.dev/"
	path_template = {
		"unix": "~/.gemini/antigravity/mcp_config.json",
		"windows": "$USERPROFILE/.gemini/antigravity/mcp_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "serverUrl"
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"serverUrl": url, "disabled": false}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"serverUrl\": \"%s\", \"disabled\": false }" % [path, name, url]
