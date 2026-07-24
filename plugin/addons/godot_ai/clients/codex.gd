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
	command_shape = McpClient.CommandShape.COMMAND_ARRAY
	command_legacy_keys = PackedStringArray(["url"])
	## Initial-only: users may disable the entry or tune either timeout and
	## Configure preserves that choice. Codex currently defaults to 10s for
	## startup and 60s per tool; test_run legitimately has a 300s server
	## budget, so the generated config leaves transport margin at the client.
	command_initial_fields = {
		"enabled": true,
		"startup_timeout_sec": 60,
		"tool_timeout_sec": 360,
	}
	command_timeout_fields = PackedStringArray([
		"startup_timeout_sec",
		"tool_timeout_sec",
	])
	command_user_fields = PackedStringArray([
		"enabled",
		"required",
		"startup_timeout_sec",
		"tool_timeout_sec",
		"enabled_tools",
		"disabled_tools",
		"default_tools_approval_mode",
		"env",
		"env_vars",
		"cwd",
	])
	detect_paths = PackedStringArray(path_template.values())
