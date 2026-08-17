@tool
extends McpClient


func _init() -> void:
	id = "deepseek_harness"
	display_name = "DeepSeek Harness"
	## DeepSeek Harness (dsh) has no `mcp` CLI verb — MCP servers register as
	## `@deepseek-ai/dsh-mcp-client` plugin entries in the HOME patch layer
	## `$DSH_HOME/cordis.patch.yml`, which dsh applies over every profile's
	## own patch layer (the web GUI included). config_type "dsh" routes to
	## `McpDshStrategy`. Verified live against dsh 0.1.0-rc.6: new entries
	## must be `insert` rows; plain rows only override existing bundle ids.
	config_type = "dsh"
	## Home patch layer, not a per-profile file: one entry covers the web
	## GUI, headless, tui, and any custom profile.
	path_template = {
		"unix": "~/.dsh/cordis.patch.yml",
		"windows": "~/.dsh/cordis.patch.yml",
	}
	## Documented: `$DSH_HOME` relocates the whole harness home, and the
	## loader reads `$DSH_HOME/cordis.patch.yml` (homePatchPath) — same
	## false-success-write class as CODEX_HOME (#617), so the override must
	## be declared.
	config_home_env = "DSH_HOME"
	config_home_env_subpath = "cordis.patch.yml"
	## Installed detection: the harness home directory itself (dsh GUI and
	## CLI both live there), or the config file once one exists.
	detect_paths = PackedStringArray(["~/.dsh"])
	## Attach migration (#838). The loader entry nests the launch under
	## `config`; the mcp-client plugin requires `transport` next to
	## command/args, and a `url` must never coexist with command fields.
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "transport"
	command_transport_value = "stdio"
	command_legacy_keys = PackedStringArray(["url"])
	## Fields the mcp-client plugin documents as user-owned; preserved on
	## reconfigure and never drift-checked.
	command_user_fields = PackedStringArray([
		"env", "cwd", "toolCallTimeoutMs", "failOnStartupError", "reconnect",
	])
	command_timeout_fields = PackedStringArray(["toolCallTimeoutMs"])
	## The bridge accepts `transport: streamable-http` with a `url`, so the
	## manual instructions may offer the HTTP alternative.
	command_supports_url_fallback = true
