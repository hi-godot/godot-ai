@tool
extends McpClient


func _init() -> void:
	id = "kiro"
	display_name = "Kiro"
	config_type = "json"
	doc_url = "https://kiro.dev/docs/mcp"
	path_template = {
		"unix": "~/.kiro/settings/mcp.json",
		"windows": "$USERPROFILE/.kiro/settings/mcp.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url, "disabled": false}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\", \"disabled\": false }" % [path, name, url]
