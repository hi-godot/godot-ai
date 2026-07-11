@tool
extends McpClient


func _init() -> void:
	# #623: Windsurf was rebranded to Devin Desktop by Cognition (June 2026).
	# The id stays "windsurf" — it is the stable registry key used for
	# configured-status lookups. The MCP config path is unchanged by the
	# rebrand: per the official docs (docs.devin.ai/desktop/cascade/mcp) the
	# global config still lives under the platform's `.codeium/windsurf/`
	# directory (~/.codeium/windsurf/ on unix, $USERPROFILE/.codeium/windsurf/
	# on Windows), and migrated installs carry their settings over in place.
	id = "windsurf"
	display_name = "Devin Desktop (Windsurf)"
	config_type = "json"
	doc_url = "https://docs.devin.ai/desktop/cascade/mcp"
	path_template = {
		"unix": "~/.codeium/windsurf/mcp_config.json",
		"windows": "$USERPROFILE/.codeium/windsurf/mcp_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "serverUrl"
	detect_paths = PackedStringArray(path_template.values())
