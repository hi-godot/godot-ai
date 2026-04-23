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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {
			"command": {"path": McpClient.resolve_uvx_path(), "args": McpClient.mcp_proxy_bridge_args(url)},
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
		var uvx := McpClient.resolve_uvx_path()
		var proxy_arg := "mcp-proxy==" + McpClient.MCP_PROXY_VERSION
		return "Edit %s and add under \"context_servers\":\n  \"%s\": { \"command\": { \"path\": \"%s\", \"args\": [\"%s\", \"--transport\", \"streamablehttp\", \"%s\"] }, \"settings\": {} }" % [path, name, uvx, proxy_arg, url]
