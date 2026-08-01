@tool
extends McpClient

func _init() -> void:
	id = "hermes"
	display_name = "Hermes Agent"
	config_type = "yaml"

	# Hermes reads MCP config from ~/.hermes/config.yaml (YAML), NOT mcp.json.
	# Verified against the official docs:
	# https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp
	# Windows: Hermes stores config under $LOCALAPPDATA/hermes (NOT $APPDATA,
	# which is Roaming) — confirmed by where the running Hermes process reads.
	# NOTE: _path_template.expand() only substitutes $VAR tokens, not %VAR%.
	path_template = {
		"unix": "~/.hermes/config.yaml",
		"windows": "$LOCALAPPDATA/hermes/config.yaml"
	}

	# Hermes uses the snake_case `mcp_servers` key (not `mcpServers`).
	# PackedStringArray explicitly, matching every other descriptor — an
	# untyped Array literal relies on implicit conversion that newer Godot
	# builds enforce more strictly (the #722 CI lesson for Array[String]).
	server_key_path = PackedStringArray(["mcp_servers"])

	# HTTP entries use `url` (+ optional `headers`); transport is inferred —
	# there is no `type` field in Hermes MCP config.
	entry_url_field = "url"

	# No transport pin: Hermes infers streamable-http from the URL.
	entry_extra_fields = {}
	entry_initial_fields = {}

	# Hermes is HTTP-native; no command shape is needed.

	# Hermes is "installed" wherever the config.yaml lives; presence of the
	# file is sufficient for the dock's installed badge.
	detect_paths = PackedStringArray()
