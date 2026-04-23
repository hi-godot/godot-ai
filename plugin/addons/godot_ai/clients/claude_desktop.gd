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
	entry_builder = func(_name: String, url: String) -> Dictionary:
		return {"command": McpClient.resolve_uvx_path(), "args": McpClient.mcp_proxy_bridge_args(url)}
	verify_entry = func(entry: Dictionary, url: String) -> bool:
		# Accept both the bridge form we write and a future url-style entry.
		if entry.get("url", "") == url:
			return true
		var cmd: String = entry.get("command", "")
		var uvx_like := cmd.get_file() == "uvx" or cmd.get_file() == "uvx.exe"
		var args = entry.get("args", [])
		return uvx_like and args is Array and args.has(url)
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		var uvx := McpClient.resolve_uvx_path()
		var proxy_arg := "mcp-proxy==" + McpClient.MCP_PROXY_VERSION
		return "Edit %s and add under \"mcpServers\":\n  \"%s\": { \"command\": \"%s\", \"args\": [\"%s\", \"--transport\", \"streamablehttp\", \"%s\"] }" % [path, name, uvx, proxy_arg, url]
