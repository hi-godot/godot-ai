@tool
extends McpClient


func _init() -> void:
	id = "kimi_code"
	display_name = "Kimi Code"
	config_type = "cli"
	doc_url = "https://moonshotai.github.io/kimi-cli/"
	cli_names = PackedStringArray(["kimi", "kimi.exe"] if OS.get_name() == "Windows" else ["kimi"])
	cli_register_template = PackedStringArray(
		["mcp", "add", "--transport", "http", "{name}", "{url}"]
	)
	cli_unregister_template = PackedStringArray(["mcp", "remove", "{name}"])
	cli_status_args = PackedStringArray(["mcp", "list"])
