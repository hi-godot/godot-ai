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
	## Kilo Code (like Roo) defaults a typeless entry to SSE transport, which
	## returns HTTP 400 against our streamable-http endpoint on `/mcp`. Pin
	## the type explicitly. Parallel to the Roo fix in #190.
	entry_extra_fields = {"type": "streamable-http", "disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
