@tool
extends McpClient

## Zed registers MCP servers under `context_servers.<name>` and only speaks
## stdio, so we bridge through `npx mcp-remote <url>` like Claude Desktop.


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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {
			"command": {"path": "npx", "args": ["-y", "mcp-remote", url]},
			"settings": {},
		}
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		var cmd = entry.get("command", {})
		if not (cmd is Dictionary):
			return false
		var args = cmd.get("args", [])
		return args is Array and args.has(url)
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add under \"context_servers\":\n  \"%s\": { \"command\": { \"path\": \"npx\", \"args\": [\"-y\", \"mcp-remote\", \"%s\"] }, \"settings\": {} }" % [path, name, url]
