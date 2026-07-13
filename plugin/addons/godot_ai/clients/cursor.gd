@tool
extends McpClient


func _init() -> void:
	id = "cursor"
	display_name = "Cursor"
	config_type = "json"
	path_template = {"unix": "~/.cursor/mcp.json", "windows": "$USERPROFILE/.cursor/mcp.json"}
	server_key_path = PackedStringArray(["mcpServers"])
