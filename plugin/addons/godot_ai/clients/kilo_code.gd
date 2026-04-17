@tool
extends McpClient


func _init() -> void:
	id = "kilo_code"
	display_name = "Kilo Code"
	config_type = "json"
	doc_url = "https://kilocode.ai/docs/features/mcp/using-mcp-in-kilo-code"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url, "disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\", \"disabled\": false, \"alwaysAllow\": [] }" % [path, name, url]
