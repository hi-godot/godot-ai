@tool
extends McpClient


func _init() -> void:
	id = "gemini_cli"
	display_name = "Gemini CLI"
	config_type = "json"
	doc_url = "https://github.com/google-gemini/gemini-cli"
	path_template = {
		"unix": "~/.gemini/settings.json",
		"windows": "$USERPROFILE/.gemini/settings.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "httpUrl"
	detect_paths = PackedStringArray(path_template.values())
