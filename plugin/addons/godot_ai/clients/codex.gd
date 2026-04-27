@tool
extends McpClient


func _init() -> void:
	id = "codex"
	display_name = "Codex"
	config_type = "toml"
	doc_url = "https://openai.com/index/codex/"
	path_template = {"unix": "~/.codex/config.toml", "windows": "$USERPROFILE/.codex/config.toml"}
	toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	# Older Codex builds used the unquoted form with underscore-substituted ids.
	toml_legacy_section_aliases = PackedStringArray(["mcp_servers.godot_ai"])
	toml_body_template = PackedStringArray([
		"url = \"{url}\"",
		"enabled = true",
	])
	detect_paths = PackedStringArray(path_template.values())
