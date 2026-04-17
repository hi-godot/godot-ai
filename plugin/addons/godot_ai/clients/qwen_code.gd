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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"httpUrl": url}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"httpUrl\": \"%s\" }" % [path, name, url]
