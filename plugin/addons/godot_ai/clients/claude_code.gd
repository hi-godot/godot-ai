@tool
extends McpClient


func _init() -> void:
	id = "claude_code"
	display_name = "Claude Code"
	config_type = "cli"
	cli_names = PackedStringArray(["claude", "claude.exe"] if OS.get_name() == "Windows" else ["claude"])
	cli_register_template = PackedStringArray(
		["mcp", "add", "--scope", "user", "--transport", "http", "{name}", "{url}"]
	)
	cli_unregister_template = PackedStringArray(["mcp", "remove", "{name}"])
	cli_status_args = PackedStringArray(["mcp", "list"])
	## #463: JSON fallback for when the `claude` binary isn't on PATH — e.g.
	## Claude Code installed only as a VS Code / Cursor extension. The CLI is
	## still preferred whenever it resolves; this is what gets written
	## otherwise. `claude mcp add --scope user --transport http` produces
	## exactly this shape under `mcpServers` in ~/.claude.json:
	##   "godot-ai": { "type": "http", "url": "<url>" }
	path_template = {"unix": "~/.claude.json", "windows": "~/.claude.json"}
	server_key_path = PackedStringArray(["mcpServers"])
	entry_extra_fields = {"type": "http"}
	## Documented: $CLAUDE_CONFIG_DIR relocates Claude Code's config home,
	## including .claude.json ($CLAUDE_CONFIG_DIR/.claude.json). The preferred
	## CLI path needs no help — the spawned `claude` binary inherits the
	## editor's environment and resolves the dir itself — but the JSON
	## fallback above would otherwise write ~/.claude.json that a relocated
	## install never reads (#617).
	config_home_env = "CLAUDE_CONFIG_DIR"
	config_home_env_subpath = ".claude.json"
