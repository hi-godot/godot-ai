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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "streamable-http", "url": url, "disabled": false, "alwaysAllow": []}
	## Flag pre-fix entries (correct URL, missing or wrong "type") as drift so
	## upgrading users get nudged to re-configure rather than silently keeping
	## the broken SSE-default entry.
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		return entry.get("url", "") == url and entry.get("type", "") == "streamable-http"
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"type\": \"streamable-http\", \"url\": \"%s\", \"disabled\": false, \"alwaysAllow\": [] }" % [path, name, url]
