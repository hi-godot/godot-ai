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
	## Roo defaults an entry with no "type" to SSE transport — which returns
	## HTTP 400 against our streamable-http endpoint on `/mcp`. Pin the type
	## explicitly so Roo negotiates streamable-http (the current MCP spec's
	## recommended remote transport). See issue #189. The default verifier
	## requires every entry_extra_fields key to match, so a pre-#189 typeless
	## entry surfaces as drift instead of silently passing as configured.
	entry_extra_fields = {"type": "streamable-http", "disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
