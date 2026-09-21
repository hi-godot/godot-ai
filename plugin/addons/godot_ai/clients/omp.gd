@tool
extends McpClient

## Oh My Pi (omp): https://github.com/can1357/oh-my-pi
## User-scope MCP servers live in `~/.omp/agent/mcp.json` under the standard
## `mcpServers` map. Entries are flat command/args/env; stdio is the default
## when `type` is omitted, and omp rejects an entry carrying both `command`
## and `url`, so `url`, `headers`, and a leftover `type` are scrubbed on
## reconfigure — generated entries stay canonical and typeless (the Pi
## shape). `enabled` and `timeout` (milliseconds) are omp's documented
## user-state fields. `PI_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, and named
## profiles can relocate the omp user root in ways this descriptor cannot
## verify, so no env override is declared: a wrong mapping writes a file omp
## never reads and Configure false-succeeds.


func _init() -> void:
	id = "omp"
	display_name = "Oh My Pi"
	config_type = "json"
	path_template = {
		"unix": "~/.omp/agent/mcp.json",
		"windows": "$USERPROFILE/.omp/agent/mcp.json",
	}
	## omp reads project `.omp/mcp.json` then `.omp/.mcp.json` before the
	## user file, and the first definition of a name wins, so a project entry
	## overrides whatever Configure writes — declared here so the dock fails
	## closed on plausible roots instead of mutating an inferred project
	## directory. The strategy folds last-wins, so the project list is
	## reversed to land that fold on omp's actual project winner. Only the
	## primary user file is a declared global tier: omp reads
	## `~/.omp/agent/.mcp.json` and root `mcp.json`/`.mcp.json` for
	## compatibility but never writes them, and a hand-placed entry there is
	## shadowed by this file under first-definition-wins.
	config_merge_path_templates = {
		"unix": PackedStringArray(["~/.omp/agent/mcp.json"]),
		"windows": PackedStringArray(["$USERPROFILE/.omp/agent/mcp.json"]),
	}
	config_merge_project_paths = PackedStringArray([".omp/.mcp.json", ".omp/mcp.json"])
	server_key_path = PackedStringArray(["mcpServers"])
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "type"])
	## Initial-only: users may disable the entry or tune the request timeout
	## and Configure preserves that choice. omp's 30s default undercuts
	## test_run's 300s server budget, so a fresh entry seeds transport
	## margin (the Codex descriptor does the same for its tool timeout).
	command_initial_fields = {"enabled": true, "timeout": 300000}
	command_timeout_fields = PackedStringArray(["timeout"])
	command_user_fields = PackedStringArray(["enabled", "timeout", "env", "cwd"])
	## omp creates `~/.omp/agent` on first launch (agent.db and friends)
	## before any MCP server is configured, so the directory is the honest
	## install signal — the config leaf may not exist yet.
	detect_paths = PackedStringArray(["~/.omp/agent"])
