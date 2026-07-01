@tool
extends McpClient


func _init() -> void:
	id = "antigravity"
	display_name = "Antigravity"
	config_type = "json"
	doc_url = "https://www.antigravity.dev/"
	## Antigravity moved its shared MCP config from `~/.gemini/antigravity/`
	## to `~/.gemini/config/` (IDE + CLI now read the same file there); the
	## old path is left in `detect_paths` below so an existing install is
	## still recognized, but new/updated entries write to the current path.
	path_template = {
		"unix": "~/.gemini/config/mcp_config.json",
		"windows": "$USERPROFILE/.gemini/config/mcp_config.json",
	}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_url_field = "serverUrl"
	## `disabled` is user-state (they may have flipped the entry off in the
	## UI); seeded on first Configure but preserved across reconfigure.
	entry_initial_fields = {"disabled": false}
	detect_paths = PackedStringArray(path_template.values() + [
		"~/.gemini/antigravity/mcp_config.json",
		"$USERPROFILE/.gemini/antigravity/mcp_config.json",
	])
