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
	toml_body_builder = func(url: String) -> PackedStringArray:
		return PackedStringArray([
			"url = \"%s\"" % url,
			"enabled = true",
		])
	detect_paths = PackedStringArray(path_template.values())
	manual_command_builder = func(name: String, url: String, path: String) -> String:
		return "Edit %s and add:\n  [mcp_servers.\"%s\"]\n  url = \"%s\"\n  enabled = true" % [path, name, url]
