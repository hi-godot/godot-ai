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
	detect_paths = PackedStringArray(path_template.values())
