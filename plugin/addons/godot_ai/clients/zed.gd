@tool
extends McpClient

## Zed registers MCP servers under `context_servers.<name>` and only speaks
## stdio, so we bridge through `uvx mcp-proxy --transport streamablehttp <url>`
## like Claude Desktop. `uvx` is already a plugin prereq.


func _init() -> void:
	id = "zed"
	display_name = "Zed"
	config_type = "json"
	doc_url = "https://zed.dev/docs/assistant/model-context-protocol"
	path_template = {
		"darwin": "~/.config/zed/settings.json",
		"linux": "$XDG_CONFIG_HOME/zed/settings.json",
		"windows": "$APPDATA/Zed/settings.json",
	}
	server_key_path = PackedStringArray(["context_servers"])
	## NESTED bridge: `{"command": {"path": <uvx>, "args": [...]}, "settings": {}}`.
	## Verifier requires the bridge form (no url-style fallback) — Zed has
	## never spoken HTTP natively.
	entry_uvx_bridge = McpClient.UvxBridge.NESTED
	detect_paths = PackedStringArray(path_template.values())
