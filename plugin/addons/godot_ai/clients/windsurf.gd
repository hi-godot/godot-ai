@tool
extends McpClient


func _init() -> void:
	id = "windsurf"
	display_name = "Windsurf"
	config_type = "json"
	doc_url = "https://docs.codeium.com/windsurf/mcp"
	path_template = {
		"unix": "~/.codeium/windsurf/mcp_config.json",
		"windows": "$USERPROFILE/.codeium/windsurf/mcp_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "serverUrl"
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"serverUrl": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"serverUrl\": \"%s\" }" % [path, name, url]
