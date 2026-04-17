@tool
extends McpClient


func _init() -> void:
	id = "claude_code"
	display_name = "Claude Code"
	config_type = "cli"
	doc_url = "https://docs.anthropic.com/en/docs/claude-code"
	cli_names = PackedStringArray(["claude", "claude.exe"] if OS.get_name() == "Windows" else ["claude"])
	cli_register_args = func(name: String, url: String) -> Array[String]:
		return ["mcp", "add", "--scope", "user", "--transport", "http", name, url]
	cli_unregister_args = func(name: String) -> Array[String]:
		return ["mcp", "remove", name]
	cli_status_check = func(cli: String, name: String, url: String) -> McpClient.Status:
		var output: Array = []
		var exit_code := OS.execute(cli, ["mcp", "list"], output, true)
		if exit_code != 0 or output.is_empty():
			return McpClient.Status.NOT_CONFIGURED
		var text: String = output[0]
		if text.find(name) < 0 or text.find(url) < 0:
			return McpClient.Status.NOT_CONFIGURED
		return McpClient.Status.CONFIGURED
	manual_command_builder = func(name: String, url: String, _path: String) -> String:
		return "claude mcp add --scope user --transport http %s %s" % [name, url]
