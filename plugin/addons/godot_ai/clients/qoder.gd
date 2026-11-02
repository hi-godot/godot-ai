@tool
extends McpClient

## https://docs.qoder.com/cli/mcp-reference


func _init() -> void:
	id = "qoder"
	display_name = "Qoder"
	config_type = "json"
	automatic_config_edits = false
	config_allows_comments = true
	config_scope_envs = PackedStringArray(["QODER_CONFIG_DIR"])
	path_template = {
		"unix": "~/.qoder/settings.json",
		"windows": "$USERPROFILE/.qoder/settings.json",
	}
	config_merge_path_templates = {
		"unix": PackedStringArray(["~/.qoder/settings.json"]),
		"windows": PackedStringArray(["$USERPROFILE/.qoder/settings.json"]),
	}
	# Both editions use .qoder for project-local overrides.
	config_merge_project_paths = PackedStringArray([
		".qoder/settings.json", ".mcp.json", ".qoder/settings.local.json",
	])
	server_key_path = PackedStringArray(["mcpServers"])
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	# The managed gateway takes precedence even over type=stdio.
	command_legacy_keys = PackedStringArray(["url", "headers", "qoder_url", "tcp", "oauth"])
	command_user_fields = PackedStringArray([
		"env", "cwd", "disabled", "timeout", "trust", "alwaysAllow", "includeTools", "excludeTools",
	])
	detect_paths = PackedStringArray(path_template.values())
