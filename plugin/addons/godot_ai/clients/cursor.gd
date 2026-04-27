@tool
extends McpClient


func _init() -> void:
	id = "cursor"
	display_name = "Cursor"
	config_type = "json"
	doc_url = "https://docs.cursor.com/context/model-context-protocol"
	path_template = {"unix": "~/.cursor/mcp.json", "windows": "$USERPROFILE/.cursor/mcp.json"}
	server_key_path = PackedStringArray(["mcpServers"])
	detect_paths = PackedStringArray(path_template.values())
