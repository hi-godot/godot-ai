@tool
extends McpClient

## Cline is a VS Code extension. Its MCP settings live in VS Code's
## globalStorage under the extension id `saoudrizwan.claude-dev`.


func _init() -> void:
	id = "cline"
	display_name = "Cline"
	config_type = "json"
	doc_url = "https://github.com/cline/cline"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"url": url, "disabled": false, "autoApprove": []}
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"url\": \"%s\", \"disabled\": false, \"autoApprove\": [] }" % [path, name, url]
