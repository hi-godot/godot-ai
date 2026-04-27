@tool
extends McpClient


func _init() -> void:
	id = "claude_code"
	display_name = "Claude Code"
	config_type = "cli"
	doc_url = "https://docs.anthropic.com/en/docs/claude-code"
	cli_names = PackedStringArray(["claude", "claude.exe"] if OS.get_name() == "Windows" else ["claude"])
	cli_register_template = PackedStringArray(
		["mcp", "add", "--scope", "user", "--transport", "http", "{name}", "{url}"]
	)
	cli_unregister_template = PackedStringArray(["mcp", "remove", "{name}"])
	cli_status_args = PackedStringArray(["mcp", "list"])
