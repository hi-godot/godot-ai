@tool
extends McpClient

## Claude Desktop's mcpServers entries are stdio-only, so we bridge our HTTP
## server through `uvx mcp-proxy --transport streamablehttp <url>`. `uvx` is
## already a plugin prereq, so this works without requiring Node.js.


func _init() -> void:
	id = "claude_desktop"
	display_name = "Claude Desktop"
	config_type = "json"
	doc_url = "https://claude.ai/download"
	path_template = {
		"darwin": "~/Library/Application Support/Claude/claude_desktop_config.json",
		"windows": "$APPDATA/Claude/claude_desktop_config.json",
		"linux": "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	## FLAT bridge: `{"command": "<uvx>", "args": [...]}`. The default
	## verifier ALSO accepts a future url-style entry (Claude Desktop has
	## been tolerant of both forms since the npx→uvx bridge migration).
	entry_uvx_bridge = McpClient.UvxBridge.FLAT
	detect_paths = PackedStringArray(path_template.values())
