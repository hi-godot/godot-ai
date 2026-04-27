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
	entry_extra_fields = {"type": "streamable-http"}
	## `disabled` and `alwaysAllow` are user-state (they may have flipped the
	## entry off, or auto-approved specific tools). Seed on first Configure
	## but preserve across reconfigure — see `entry_initial_fields` in `_base.gd`.
	entry_initial_fields = {"disabled": false, "alwaysAllow": []}
	detect_paths = PackedStringArray(path_template.values())
