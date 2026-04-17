@tool
extends McpClient


func _init() -> void:
	id = "roo_code"
	display_name = "Roo Code"
	config_type = "json"
	doc_url = "https://docs.roocode.com/features/mcp/using-mcp-in-roo"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url, "disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\", \"disabled\": false, \"alwaysAllow\": [] }" % [path, name, url]
