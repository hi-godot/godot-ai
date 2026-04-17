@tool
extends McpClient


func _init() -> void:
	id = "trae"
	display_name = "Trae"
	config_type = "json"
	doc_url = "https://docs.trae.ai/ide/model-context-protocol"
	path_template = {
		"darwin": "~/Library/Application Support/Trae/User/mcp.json",
		"windows": "$APPDATA/Trae/User/mcp.json",
		"linux": "$XDG_CONFIG_HOME/Trae/User/mcp.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\" }" % [path, name, url]
