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
	entry_extra_fields = {"type": "streamable-http"}
	## `disabled` and `alwaysAllow` are user-state (they may have flipped the
	## entry off, or auto-approved specific tools like `session_manage`).
	## Seed on first Configure but preserve across reconfigure — without this
	## split, the Configure-All-Mismatched sweep silently wipes the user's
	## auto-approval list every time the type pin or URL drifts.
	entry_initial_fields = {"disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
