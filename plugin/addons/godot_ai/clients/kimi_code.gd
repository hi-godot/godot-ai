@tool
extends McpClient


func _init() -> void:
	id = "kimi_code"
	display_name = "Kimi Code"
	## Kimi Code has no `mcp` CLI subcommand (verified against v0.28.1 —
	## `kimi mcp` falls through to the root --help, and the docs at
	## moonshotai.github.io/kimi-code/en/customization/mcp confirm servers are
	## managed via ~/.kimi-code/mcp.json, not a CLI verb). JSON is therefore
	## the only working config method, not a fallback.
	config_type = "json"
	path_template = {"unix": "~/.kimi-code/mcp.json", "windows": "~/.kimi-code/mcp.json"}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_extra_fields = {"transport": "http"}
