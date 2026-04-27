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
	entry_extra_fields = {"type": "streamableHttp"}
	## `disabled` and `autoApprove` are user-state (they may have flipped the
	## entry off, or auto-approved specific tools). Seed on first Configure
	## but preserve across reconfigure — see `entry_initial_fields` in `_base.gd`.
	entry_initial_fields = {"disabled": false, "autoApprove": []}
	detect_paths = PackedStringArray(path_template.values())
