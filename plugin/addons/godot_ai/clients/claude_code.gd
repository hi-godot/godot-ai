@tool
extends McpClient


func _init() -> void:
	id = "claude_code"
	display_name = "Claude Code"
	config_type = "cli"
	cli_names = PackedStringArray(["claude", "claude.exe"] if OS.get_name() == "Windows" else ["claude"])
	## Stdio registration through the client-owned `godot-ai attach` bridge
	## (#838). `--` stops claude's own flag parsing so the attach argv passes
	## through verbatim; stdio is the CLI's default transport. Scope comes from
	## the `godot_ai/mcp_client_scope` EditorSetting via the `{scope}` token; it
	## defaults to `user` — the same ~/.claude.json the pre-attach HTTP entry
	## lived in — and can be set to `project` to write <project>/.mcp.json so the
	## server is not loaded in every unrelated workspace.
	cli_register_template = PackedStringArray(
		["mcp", "add", "--scope", "{scope}", "{name}", "--", "{command}", "{args...}"]
	)
	## Explicit scope: an unscoped `mcp remove` deletes from whichever scope
	## matches first, which could eat a project-local entry the user made.
	cli_unregister_template = PackedStringArray(["mcp", "remove", "--scope", "{scope}", "{name}"])
	cli_status_args = PackedStringArray(["mcp", "list"])
	## #463: JSON fallback for when the `claude` binary isn't on PATH — e.g.
	## Claude Code installed only as a VS Code / Cursor extension. The CLI is
	## still preferred for Configure whenever it resolves; this is what gets
	## written otherwise. `claude mcp add --scope user <name> -- <cmd> <args>`
	## produces exactly this shape under `mcpServers` in ~/.claude.json
	## (verified live against claude CLI in an isolated CLAUDE_CONFIG_DIR):
	##   "godot-ai": { "type": "stdio", "command": "<cmd>", "args": [...], "env": {} }
	## The fallback writer omits the empty `env`; the verifier accepts both.
	## Status always reads this file — it is the CLI's own store for user
	## scope, and file reads give exact launch-drift detection that `mcp list`
	## stdout scanning cannot.
	path_template = {"unix": "~/.claude.json", "windows": "~/.claude.json"}
	server_key_path = PackedStringArray(["mcpServers"])
	## URL-mode shape, used only for the manual-instruction fallback text —
	## `claude mcp add --scope user --transport http` writes {type: http, url}.
	entry_extra_fields = {"type": "http"}
	command_shape = McpClient.CommandShape.FLAT
	command_transport_key = "type"
	command_transport_value = "stdio"
	## Legacy HTTP entries carried a `url`; Claude Code rejects an entry mixing
	## url with command fields, and the stale `type: "http"` is repinned to
	## "stdio" by the transport key above.
	command_legacy_keys = PackedStringArray(["url"])
	command_user_fields = PackedStringArray(["env"])
	command_supports_url_fallback = true
	## Documented: $CLAUDE_CONFIG_DIR relocates Claude Code's config home,
	## including .claude.json ($CLAUDE_CONFIG_DIR/.claude.json). The preferred
	## CLI path needs no help — the spawned `claude` binary inherits the
	## editor's environment and resolves the dir itself — but the JSON
	## fallback above would otherwise write ~/.claude.json that a relocated
	## install never reads (#617).
	config_home_env = "CLAUDE_CONFIG_DIR"
	config_home_env_subpath = ".claude.json"
