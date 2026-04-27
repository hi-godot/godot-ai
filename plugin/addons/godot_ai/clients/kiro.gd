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
	## `disabled` is user-state — preserved across reconfigure.
	entry_initial_fields = {"disabled": false}
	detect_paths = PackedStringArray(path_template.values())
