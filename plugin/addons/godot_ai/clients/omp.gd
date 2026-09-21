@tool
extends McpClient

## Oh My Pi (omp): https://github.com/can1357/oh-my-pi
## omp keeps the FIRST definition of a duplicated server: project
## `.omp/mcp.json` shadows `.omp/.mcp.json`, then the active user scope's
## `mcp.json` shadows its `.mcp.json`. The tiers below are declared in that
## read order with `config_merge_first_wins`, so Configure updates the file
## that already owns the server instead of shadowing a compatibility
## entry's user state (#1085). omp never writes the compatibility files
## itself; the write fold landing on `mcp.json` keeps that true here too —
## a fresh entry is created only on tiers[0].
##
## The user scope can be relocated per launch (`omp --profile`,
## OMP_PROFILE/PI_PROFILE). `config_scope_globs` fails Configure/Remove
## closed while any named profile exists, because the active profile is
## chosen at client launch and is not persisted anywhere the editor can
## read — status reports the ambiguity instead of green-lighting the
## default file.


func _init() -> void:
	id = "omp"
	display_name = "Oh My Pi"
	config_type = "json"
	path_template = {
		"unix": "~/.omp/agent/mcp.json",
		"windows": "$USERPROFILE/.omp/agent/mcp.json",
	}
	## Declared in omp's read order (primary first, compatibility second);
	## `_first_wins` folds stop at the first tier defining the server, so a
	## write updates the effective file and a fresh entry lands on the
	## primary. Status still verifies against every existing tier.
	config_merge_path_templates = {
		"unix": PackedStringArray([
			"~/.omp/agent/mcp.json",
			"~/.omp/agent/.mcp.json",
		]),
		"windows": PackedStringArray([
			"$USERPROFILE/.omp/agent/mcp.json",
			"$USERPROFILE/.omp/agent/.mcp.json",
		]),
	}
	config_merge_project_paths = PackedStringArray([".omp/mcp.json", ".omp/.mcp.json"])
	config_merge_first_wins = true
	config_scope_globs = PackedStringArray(["~/.omp/profiles/*"])
	## A stale `disabledServers` name hides the server whatever the entry
	## says; Configure scrubs it from the file it writes, like omp's own
	## writer. Other names are preserved.
	config_denylist_key = "disabledServers"
	server_key_path = PackedStringArray(["mcpServers"])
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "type"])
	## Seeded only on a fresh entry; reconfigure preserves the effective
	## entry's values. OMP_MCP_TIMEOUT_MS may override this per-server
	## timeout.
	command_initial_fields = {"enabled": true, "timeout": 300000}
	command_timeout_fields = PackedStringArray(["timeout"])
	command_user_fields = PackedStringArray(["enabled", "timeout", "env", "cwd"])
	## omp creates `~/.omp/agent` on first launch (agent.db and friends)
	## before any MCP server is configured, so the directory is the honest
	## install signal — the config leaf may not exist yet.
	detect_paths = PackedStringArray(["~/.omp/agent"])
