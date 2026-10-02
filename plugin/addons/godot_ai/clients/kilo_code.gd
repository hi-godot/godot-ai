@tool
extends McpClient


func _init() -> void:
	id = "kilo_code"
	display_name = "Kilo Code"
	config_type = "json"
	path_template = {
		"darwin": "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
		"windows": "$APPDATA/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
		"linux": "$XDG_CONFIG_HOME/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
	}
	## globalStorage follows VS Code's user data, which the Flathub build keeps
	## in its own app directory (see vscode.gd).
	config_path_candidates = {
		"linux": [
			path_template["linux"],
			"~/.var/app/com.visualstudio.code/config/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
		],
	}
	server_key_path = PackedStringArray(["mcpServers"])
	## Kilo Code (like Roo) defaults a typeless entry to SSE transport, which
	## returns HTTP 400 against our streamable-http endpoint on `/mcp`. Pin
	## the type explicitly. Parallel to the Roo fix in #190.
	entry_extra_fields = {"type": "streamable-http"}
	## `disabled` and `alwaysAllow` are user-state (they may have flipped the
	## entry off, or auto-approved specific tools). Seed on first Configure
	## but preserve across reconfigure — see `entry_initial_fields` in `_base.gd`.
	entry_initial_fields = {"disabled": false, "alwaysAllow": []}
	## Attach migration (#838). UNLIKE its Roo siblings the stdio entry must be
	## TYPELESS: Kilo's v7 platform treats this file as a migration source and
	## routes on `type` — any http type value sends the entry down the remote
	## branch where it is dropped for lack of a url, and only a bare
	## command/args/env entry is verified to work in BOTH the legacy extension
	## and the v7 migrator (packages/opencode/src/kilocode/mcp-migrator.ts).
	## `type` therefore joins the legacy keys instead of being repinned.
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "type", "headers"])
	command_initial_fields = {"disabled": false, "alwaysAllow": []}
	command_user_fields = PackedStringArray([
		"disabled", "alwaysAllow", "timeout", "cwd", "watchPaths",
		"disabledTools", "env",
	])
	command_timeout_fields = PackedStringArray(["timeout"])
