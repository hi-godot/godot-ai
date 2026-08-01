@tool
extends McpClient

## Claude Desktop's mcpServers entries launch a local stdio process. The
## client-owned `godot-ai attach` bridge keeps that stdio session stable while
## adopting or starting the shared HTTP backend as Godot editors come and go.


func _init() -> void:
	id = "claude_desktop"
	display_name = "Claude Desktop"
	config_type = "json"
	path_template = {
		"darwin": "~/Library/Application Support/Claude/claude_desktop_config.json",
		"windows": "$APPDATA/Claude/claude_desktop_config.json",
		"linux": "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json",
	}
	## Store-installed Claude runs inside MSIX AppData virtualization. Godot is
	## outside that container, so `%APPDATA%` names a different physical file
	## once Claude has created its private copy. A unique Store package root is
	## authoritative even before the config leaf exists: create the private file
	## directly so a later copy-on-write cannot hide an entry written to roaming.
	## With no Store package, use the conventional roaming path. The wildcard
	## avoids coupling to the publisher-hash suffix.
	config_path_candidates = {
		"windows": [
			"$LOCALAPPDATA/Packages/Claude_*/LocalCache/Roaming/Claude/claude_desktop_config.json",
			"$APPDATA/Claude/claude_desktop_config.json",
		],
	}
	detect_paths = PackedStringArray([
		"$LOCALAPPDATA/Packages/Claude_*",
	])
	server_key_path = PackedStringArray(["mcpServers"])
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url"])
	command_env_legacy_keys = PackedStringArray(["UV_LINK_MODE"])
	command_user_fields = PackedStringArray(["env", "disabled"])
