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
	## Cline (like Roo) defaults a typeless entry to SSE transport, which
	## returns HTTP 400 against our streamable-http endpoint on `/mcp`. Pin
	## the type explicitly. Cline's schema uses "streamableHttp" (camelCase,
	## see src/services/mcp/schemas.ts in the cline repo) — distinct from
	## Roo's "streamable-http" string. Parallel to the Roo fix in #190.
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"type": "streamableHttp", "url": url, "disabled": false, "autoApprove": []}
	## Flag pre-fix entries (correct URL, missing or wrong "type") as drift so
	## upgrading users get nudged to re-configure rather than silently keeping
	## the broken SSE-default entry.
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		return entry.get("url", "") == url and entry.get("type", "") == "streamableHttp"
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"type\": \"streamableHttp\", \"url\": \"%s\", \"disabled\": false, \"autoApprove\": [] }" % [path, name, url]
