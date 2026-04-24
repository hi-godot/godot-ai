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
	## recommended remote transport). See issue #189.
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "streamable-http", "url": url, "disabled": false, "alwaysAllow": []}
	## Flag pre-#189 entries (correct URL, missing or wrong "type") as drift so
	## the dock nudges the user to re-configure after upgrading. Without this,
	## the URL-only default verifier says CONFIGURED and the broken SSE
	## negotiation is invisible until Roo fails at connect time.
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		return entry.get("url", "") == url and entry.get("type", "") == "streamable-http"
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"type\": \"streamable-http\", \"url\": \"%s\", \"disabled\": false, \"alwaysAllow\": [] }" % [path, name, url]
