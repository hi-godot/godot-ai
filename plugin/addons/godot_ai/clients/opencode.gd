@tool
extends McpClient

## OpenCode stores MCP servers under `mcp.<name>` (not the typical mcpServers
## map) and uses `type: "remote"` for HTTP servers.


func _init() -> void:
	id = "opencode"
	display_name = "OpenCode"
	config_type = "json"
	## `$HOME` on Windows is deliberate: OpenCode reads ~/.config/... on ALL
	## platforms (verified via `opencode debug paths`), and
	## McpPathTemplate._home() falls back to USERPROFILE when HOME is unset —
	## pinned by test_opencode_client_uses_home_config_on_windows. The documented
	## `OPENCODE_CONFIG` override names an exact file and must win over this
	## default for configure, status, remove, and manual instructions.
	path_template = {
		"unix": "~/.config/opencode/opencode.json",
		"windows": "$HOME/.config/opencode/opencode.json",
	}
	config_file_env = "OPENCODE_CONFIG"
	## OpenCode loads BOTH opencode.json and opencode.jsonc from its config
	## directory and merges them, later file winning per key
	## (anomalyco/opencode#32447). Writing only opencode.json therefore
	## leaves a stale `godot-ai` entry in an existing opencode.jsonc in
	## charge (#1011). Declaring the merge order makes Configure update the
	## effective last definition, status verify it, and Remove clear both.
	config_merge_path_templates = {
		"unix": PackedStringArray([
			"~/.config/opencode/opencode.json",
			"~/.config/opencode/opencode.jsonc",
		]),
		"windows": PackedStringArray([
			"$HOME/.config/opencode/opencode.json",
			"$HOME/.config/opencode/opencode.jsonc",
		]),
	}
	server_key_path = PackedStringArray(["mcp"])
	entry_extra_fields = {"type": "remote"}
	## `enabled` is user-state (they may have toggled the server off).
	entry_initial_fields = {"enabled": true}
	## Attach migration (#838). OpenCode local entries carry the launch as ONE
	## argv array — `"command": ["uvx", …]` with no separate args key — plus a
	## schema-REQUIRED `type: "local"` (McpLocalConfig in opencode.ai/config.json;
	## env lives under `environment`, not `env`). The pin rewrites the legacy
	## `type: "remote"` in place; url/headers are remote-only and must go.
	command_shape = McpClient.CommandShape.COMMAND_ARRAY
	command_transport_key = "type"
	command_transport_value = "local"
	command_legacy_keys = PackedStringArray(["url", "headers"])
	command_initial_fields = {"enabled": true}
	command_user_fields = PackedStringArray(["enabled", "timeout", "environment", "cwd"])
	command_timeout_fields = PackedStringArray(["timeout"])
