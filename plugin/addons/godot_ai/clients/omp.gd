@tool
extends McpClient

## Oh My Pi (omp): https://github.com/can1357/oh-my-pi
## The default profile reads ~/.omp/agent/mcp.json. Automatic edits could
## shadow a compatibility entry's user state or target the wrong profile;
## use the existing manual-only flow until the effective destination is known.


func _init() -> void:
	id = "omp"
	display_name = "Oh My Pi"
	config_type = "json"
	automatic_config_edits = false
	path_template = {
		"unix": "~/.omp/agent/mcp.json",
		"windows": "$USERPROFILE/.omp/agent/mcp.json",
	}
	## Status inspects the default primary file and plausible project roots.
	## Reverse project precedence for the strategy's last-wins read fold.
	config_merge_path_templates = {
		"unix": PackedStringArray(["~/.omp/agent/mcp.json"]),
		"windows": PackedStringArray(["$USERPROFILE/.omp/agent/mcp.json"]),
	}
	config_merge_project_paths = PackedStringArray([".omp/.mcp.json", ".omp/mcp.json"])
	server_key_path = PackedStringArray(["mcpServers"])
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "type"])
	## Suggested manual entry default; existing primary-file user fields survive
	## rendering. OMP_MCP_TIMEOUT_MS may override this per-server timeout.
	command_initial_fields = {"enabled": true, "timeout": 300000}
	command_timeout_fields = PackedStringArray(["timeout"])
	command_user_fields = PackedStringArray(["enabled", "timeout", "env", "cwd"])
	## omp creates `~/.omp/agent` on first launch (agent.db and friends)
	## before any MCP server is configured, so the directory is the honest
	## install signal — the config leaf may not exist yet.
	detect_paths = PackedStringArray(["~/.omp/agent"])
