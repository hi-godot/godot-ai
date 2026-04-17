@tool
extends McpClient


func _init() -> void:
	id = "vscode_insiders"
	display_name = "VS Code Insiders"
	config_type = "json"
	doc_url = "https://code.visualstudio.com/docs/copilot/chat/mcp-servers"
	path_template = {
		"darwin": "~/Library/Application Support/Code - Insiders/User/mcp.json",
		"windows": "$APPDATA/Code - Insiders/User/mcp.json",
		"linux": "$XDG_CONFIG_HOME/Code - Insiders/User/mcp.json",
	}
	server_key_path = PackedStringArray(["servers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "http", "url": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"servers\":\n  \"%s\": { \"type\": \"http\", \"url\": \"%s\" }" % [path, name, url]
