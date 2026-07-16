@tool
extends McpClient


func _init() -> void:
	id = "grok"
	display_name = "Grok Build"
	config_type = "toml"
	# Grok Build reads MCP servers from ~/.grok/config.toml
	# (https://x.ai / Grok user guide: MCP servers section).
	path_template = {
		"unix": "~/.grok/config.toml",
		"windows": "$USERPROFILE/.grok/config.toml",
	}
	toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	# Some docs / older notes used an underscore form.
	toml_legacy_section_aliases = PackedStringArray(["mcp_servers.godot_ai"])
	toml_body_template = PackedStringArray([
		"url = \"{url}\"",
		"enabled = true",
	])
	detect_paths = PackedStringArray(path_template.values())
