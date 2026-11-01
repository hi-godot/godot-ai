@tool
extends McpClient


func _init() -> void:
	id = "pi"
	display_name = "Pi Agent"
	config_type = "json"
	# pi-codemode-mcp reads MCP server definitions from ~/.pi/agent/mcp.json
	# (first merge tier; ~/.pi/agent/.mcp.json, .pi/mcp.json, and
	# .mcp.json merge after, project-scope last). Documented at
	# github.com/mitsuhiko/pi-codemode-mcp README "Configuration files"
	# section. Windows path mirrors antigravity's $USERPROFILE choice so
	# the descriptor round-trips on every supported platform.
	path_template = {
		"unix": "~/.pi/agent/mcp.json",
		"windows": "$USERPROFILE/.pi/agent/mcp.json",
	}
	# Pi merges these files in order; later definitions of the same server win.
	# Keep this separate from config_path_candidates, whose entries are alternatives
	# rather than merge tiers.
	config_merge_path_templates = {
		"unix": PackedStringArray([
			"~/.pi/agent/mcp.json",
			"~/.pi/agent/.mcp.json",
		]),
		"windows": PackedStringArray([
			"$USERPROFILE/.pi/agent/mcp.json",
			"$USERPROFILE/.pi/agent/.mcp.json",
		]),
	}
	config_merge_project_paths = PackedStringArray([".pi/mcp.json", ".mcp.json"])
	server_key_path = PackedStringArray(["mcpServers"])
	# pi-codemode-mcp resolves these with nullish precedence:
	# mcpServers ?? mcp-servers ?? servers. Reuse whichever map already exists
	# so Configure cannot shadow and deactivate the user's existing servers.
	var aliases: Array[PackedStringArray] = [
		PackedStringArray(["mcp-servers"]),
		PackedStringArray(["servers"]),
	]
	server_key_path_aliases = aliases
	entry_url_field = "url"
	# pi-codemode-mcp selects stdio from `command` and remote transport from
	# `url`; it ignores `type`. Keep generated stdio entries minimal and typeless.
	entry_extra_fields = {}
	entry_initial_fields = {}
	# Attach migration (#838). Pi stdio entries are flat command/args/env.
	# When Configure replaces a legacy URL entry, remove `url`, `headers`, and
	# any redundant `type` field so the generated stdio entry stays canonical.
	command_shape = McpClient.CommandShape.FLAT
	command_legacy_keys = PackedStringArray(["url", "headers", "type"])
	# Claude Code shares .mcp.json and writes this harmless discriminator.
	command_legacy_key_exceptions = {"type": "stdio"}
	# `env` is the only user-mutable field pi's docs surface. Future
	# fields still survive — the strategy deep-copies unknown keys.
	command_user_fields = PackedStringArray(["env"])
	# Pi's loader also accepts pure-URL entries (the example mcp.json in
	# the pi-codemode-mcp repo ships stdio + URL entries side-by-side).
	# ~/.pi/agent/mcp.json is created by the first pi launch, so its
	# presence is the strongest install signal. Mirror antigravity's
	# `detect_paths = path_template.values()` pattern so the dock shows
	# the installed badge before Configure has run.
	detect_paths = PackedStringArray(path_template.values())
