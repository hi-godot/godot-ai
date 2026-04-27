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
	## `disabled` is user-state (they may have flipped the entry off in the
	## UI); seeded on first Configure but preserved across reconfigure.
	entry_initial_fields = {"disabled": false}
	detect_paths = PackedStringArray(path_template.values())
