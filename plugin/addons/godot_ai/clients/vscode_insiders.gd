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
	entry_extra_fields = {"type": "http"}
	detect_paths = PackedStringArray(path_template.values())
