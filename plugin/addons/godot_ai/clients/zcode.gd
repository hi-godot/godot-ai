@tool
extends McpClient

## ZCode (Z.AI's GLM coding agent): https://zcode.z.ai/en/docs/mcp-services
## User-scope MCP servers live in `~/.zcode/cli/config.json` under the nested
## `mcp.servers` map; the workspace scope is `<project>/.zcode/config.json`,
## which this descriptor does not target because the client's working directory
## is unknown to the editor. Entries are flat command/args/env, and
## `type: "stdio"` is what the settings form, the bundled plugin manifest, and
## working third-party integrations write - it also repins a stale
## `type: "http"` left on a hand-added remote entry. `enable` (singular) is
## ZCode's documented user-state key (absence means enabled), so it is
## preserved rather than written. Adding any `.zcode` server makes ZCode skip
## `~/.agents/mcp.json` entirely (documented `.zcode`-first rule), which is why
## this writes the native config rather than the `.agents` fallback.


func _init() -> void:
	id = "zcode"
	display_name = "ZCode"
	config_type = "json"
	path_template = {
		"unix": "~/.zcode/cli/config.json",
		"windows": "$USERPROFILE/.zcode/cli/config.json",
	}
	server_key_path = PackedStringArray(["mcp", "servers"])
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	command_legacy_keys = PackedStringArray(["url", "headers"])
	command_user_fields = PackedStringArray(["env", "enable"])
	## ZCode creates `~/.zcode` on first launch; the config leaf may not exist
	## yet, so the directory is the installed signal.
	detect_paths = PackedStringArray(["~/.zcode"])
