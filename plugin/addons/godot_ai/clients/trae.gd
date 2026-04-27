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
	detect_paths = PackedStringArray(path_template.values())
