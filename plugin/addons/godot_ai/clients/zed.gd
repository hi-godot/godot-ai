@tool
extends McpClient

## Zed registers MCP servers under `context_servers.<name>` and supports both
## stdio and streamable http transports.


func _init() -> void:
	id = "zed"
	display_name = "Zed"
	config_type = "json"
	## Zed settings are JSONC. Owning a second JSON tokenizer solely to preserve
	## comments would make the shared JSON strategy much harder to trust. Keep
	## status checks read-only and give users the exact manual entry instead.
	automatic_config_edits = false
	## Reads still have to cope with the `//` header Zed ships, or a stock
	## install shows a parse error in the row instead of a status.
	config_allows_comments = true
	path_template = {
		"darwin": "~/.config/zed/settings.json",
		"linux": "$XDG_CONFIG_HOME/zed/settings.json",
		"windows": "$APPDATA/Zed/settings.json",
	}
	## The Flathub build restarts itself on the host with
	## FLATPAK_XDG_CONFIG_HOME set to its own app directory, and reads
	## `$FLATPAK_XDG_CONFIG_HOME/zed` instead of ~/.config/zed
	## (crates/paths/src/paths.rs, crates/cli/src/main.rs).
	config_path_candidates = {
		"linux": [
			path_template["linux"],
			"~/.var/app/dev.zed.Zed/config/zed/settings.json",
		],
	}
	server_key_path = PackedStringArray(["context_servers"])
	## Attach migration (#838). Current Zed's context_servers entries are an
	## untagged serde enum discriminated by shape: `command` (string) + args/env
	## → stdio, `url` → HTTP (zed.dev/docs/ai/mcp; settings_content/project.rs).
	## BECAUSE the enum is untagged, HTTP-only keys left next to `command`
	## (`url`, `headers`, `oauth`) make the entry match no variant and break it —
	## removing them on migration is load-bearing, not cosmetic. `enabled`,
	## `remote`, and `timeout` are user-state on the stdio variant.
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "oauth"])
	command_user_fields = PackedStringArray(["enabled", "remote", "timeout", "env"])
	command_timeout_fields = PackedStringArray(["timeout"])
