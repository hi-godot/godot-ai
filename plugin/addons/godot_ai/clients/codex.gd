@tool
extends McpClient


func _init() -> void:
	id = "codex"
	display_name = "Codex"
	config_type = "toml"
	path_template = {"unix": "~/.codex/config.toml", "windows": "$USERPROFILE/.codex/config.toml"}
	## Documented: when $CODEX_HOME is set, Codex reads config.toml directly
	## from it instead of ~/.codex (#617).
	config_home_env = "CODEX_HOME"
	config_home_env_subpath = "config.toml"
	toml_section_path = PackedStringArray(["mcp_servers", "godot-ai"])
	# Older Codex builds used the unquoted form with underscore-substituted ids.
	toml_legacy_section_aliases = PackedStringArray(["mcp_servers.godot_ai"])
	toml_body_template = PackedStringArray([
		"url = \"{url}\"",
		"enabled = true",
	])
	detect_paths = PackedStringArray(path_template.values())
