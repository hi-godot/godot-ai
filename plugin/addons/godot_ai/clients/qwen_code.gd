@tool
extends McpClient


func _init() -> void:
	id = "qwen_code"
	display_name = "Qwen Code"
	config_type = "json"
	doc_url = "https://github.com/QwenLM/qwen-code"
	path_template = {
		"unix": "~/.qwen/settings.json",
		"windows": "$USERPROFILE/.qwen/settings.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "httpUrl"
	detect_paths = PackedStringArray(path_template.values())
