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
	entry_extra_fields = {"disabled": false}
	detect_paths = PackedStringArray(path_template.values())
