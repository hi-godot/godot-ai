@tool
class_name McpManualCommand
extends RefCounted

const SHELL_POSIX := "posix"
const SHELL_POWERSHELL := "powershell"
## Keep this intersection deliberately small. PowerShell treats a leading `@`
## as splatting syntax and commas as list separators, while POSIX shells accept
## both literally; quoting either is safer than trying to infer token position.
const _SHELL_BARE_SAFE_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+=:./-"

## Synthesize the "Run this manually" string the dock surfaces when
## auto-configure can't find a CLI / write a file. Generated from the
## descriptor's declarative fields — there is no per-client builder
## Callable. See `_base.gd` for why descriptors are data-only.


static func build(
	client: McpClient,
	server_name: String,
	server_url: String,
	resolved_path: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> String:
	match client.config_type:
		"cli":
			return _build_cli(client, server_name, server_url, resolved_path, launch, project_roots)
		"json":
			return _build_json(client, server_name, server_url, resolved_path, launch, project_roots)
		"toml":
			return _build_toml(client, server_name, server_url, resolved_path, launch)
		"yaml":
			return _build_yaml(client, server_name, server_url, resolved_path, launch)
		"dsh":
			return _build_dsh(client, server_name, server_url, resolved_path, launch)
	return ""


## CLI clients: format the register template against the *short* CLI name so
## the user can paste it into a terminal regardless of where their binary
## lives. (The auto-configure path resolves to an absolute uvx-style path;
## that's noise for a paste-into-terminal hint. The attach launcher path
## inside a command-shape line stays absolute — status verification compares
## the registered command against the resolved launcher verbatim.)
static func _build_cli(
	client: McpClient,
	server_name: String,
	server_url: String,
	resolved_path: String = "",
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> String:
	if client.cli_register_template.is_empty() or client.cli_names.is_empty():
		return ""
	var shell_kind := _shell_kind_for_platform()
	var short_name: String = String(client.cli_names[0])
	# Prefer the non-.exe form for a cross-platform-looking command line.
	for n in client.cli_names:
		if not String(n).ends_with(".exe"):
			short_name = String(n)
			break
	var cmd := ""
	if client.command_shape != McpClient.CommandShape.NONE:
		var launch_error := McpCliStrategy.command_launch_error(client, launch)
		if not launch_error.is_empty():
			cmd = "Attach launch command unavailable: %s" % launch_error
		else:
			var args := McpCliStrategy.format_args(client.cli_register_template, server_name, server_url, launch)
			var parts: Array[String] = [short_name]
			for arg in args:
				parts.append(String(arg))
			var lines := _sweep_lines(client, server_name, server_url, short_name, shell_kind)
			lines.append(_render_command_line(parts, shell_kind))
			cmd = _format_shell_block(lines, shell_kind) + _sweep_caveat(client)
	else:
		var args := McpCliStrategy.format_args(client.cli_register_template, server_name, server_url)
		var parts: Array[String] = [short_name]
		for arg in args:
			parts.append(String(arg))
		var lines := _sweep_lines(client, server_name, server_url, short_name, shell_kind)
		lines.append(_render_command_line(parts, shell_kind))
		cmd = _format_shell_block(lines, shell_kind) + _sweep_caveat(client)
	# #463: a CLI client with a JSON fallback (Claude Code) may have no `claude`
	# binary at all — e.g. installed only as a VS Code/Cursor extension. The CLI
	# line above is useless to that user, so also show the config-file edit that
	# auto-configure falls back to writing.
	if client.has_json_fallback() and not resolved_path.is_empty():
		return "%s\n\nNo `%s` CLI (e.g. installed as a VS Code/Cursor extension)? %s" % [
			cmd, short_name, _build_json(client, server_name, server_url, resolved_path, launch, project_roots),
		]
	return cmd


## #877: Configure's first act is the pre-cleanup — it runs the unregister
## template once per scope the descriptor can write to (`_cli_strategy.gd`
## `configure`) before registering. Rendering only the register line made this
## hint disagree with what the button does, which is the worst property a
## "run this manually" string can have. The removes go in the SAME shell block
## as the register, in the order Configure runs them, so the whole thing stays
## one copy-paste rather than a labelled command plus loose prose.
static func _sweep_lines(
	client: McpClient,
	server_name: String,
	server_url: String,
	short_name: String,
	shell_kind: String,
) -> Array[String]:
	var lines: Array[String] = []
	if client.cli_unregister_template.is_empty():
		return lines
	for pre_scope in McpCliStrategy.cleanup_scopes(client):
		var args := McpCliStrategy.format_args(
			client.cli_unregister_template, server_name, server_url, {}, pre_scope
		)
		var parts: Array[String] = [short_name]
		for arg in args:
			parts.append(String(arg))
		lines.append(_render_command_line(parts, shell_kind))
	return lines


## The one thing the commands themselves cannot show: that the project pass
## resolves `.mcp.json` against the CLI's cwd, so it can delete an entry from a
## repository that has nothing to do with this project. Only for `{scope}`
## descriptors — a single implicit-scope pass removes exactly the entry the
## register is about to rewrite, which needs no warning. Kept outside the shell
## block so pasting the block never picks up prose.
static func _sweep_caveat(client: McpClient) -> String:
	if client.cli_unregister_template.is_empty() or not McpCliStrategy.uses_scope_token(client):
		return ""
	return (
		"\n\nThe project-scope remove rewrites the .mcp.json in the directory the"
		+ " editor was launched from — not necessarily this project — so it drops a"
		+ " hand-maintained godot-ai entry there. Other servers in that file are left"
		+ " alone."
	)


static func _shell_kind_for_platform() -> String:
	return SHELL_POWERSHELL if OS.get_name() == "Windows" else SHELL_POSIX


## Render a command for one explicitly named shell. The label is load-bearing:
## POSIX and PowerShell use different escaping for embedded single quotes, so
## presenting the command without its target shell invites a bad copy/paste.
static func _format_shell_command(parts: Array[String], shell_kind: String) -> String:
	return _format_shell_block([_render_command_line(parts, shell_kind)], shell_kind)


## One label over N command lines. The label is per-block, not per-line:
## repeating "Run in PowerShell:" four times would bury the single line that
## actually registers.
static func _format_shell_block(lines: Array[String], shell_kind: String) -> String:
	var label := "Run in PowerShell:" if shell_kind == SHELL_POWERSHELL else "Run in a POSIX shell:"
	return "%s\n%s" % [label, "\n".join(lines)]


static func _render_command_line(parts: Array[String], shell_kind: String) -> String:
	var rendered: Array[String] = []
	for part in parts:
		rendered.append(_shell_display_arg(part, shell_kind))
	return " ".join(rendered)


## Quote one argv element for the paste-into-terminal hint. Single-quoted
## strings are literal in both supported shells, but embedded single quotes
## have shell-specific spellings. Backslashes, double quotes, dollar signs,
## and PowerShell backticks remain byte-for-byte unchanged inside the quotes.
static func _shell_display_arg(arg: String, shell_kind: String) -> String:
	if arg.is_empty():
		return "''"
	var stays_bare := true
	for index in range(arg.length()):
		if _SHELL_BARE_SAFE_CHARS.find(arg.substr(index, 1)) < 0:
			stays_bare = false
			break
	if stays_bare:
		return arg
	if shell_kind == SHELL_POWERSHELL:
		return "'%s'" % arg.replace("'", "''")
	return "'%s'" % arg.replace("'", "'\"'\"'")


static func _build_json(
	client: McpClient,
	server_name: String,
	server_url: String,
	resolved_path: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> String:
	var target := McpJsonStrategy.manual_target_details(client, server_name, resolved_path, project_roots)
	var target_note := ""
	if not target.get("ok", false):
		target_note = "Target inspection failed: %s" % str(target.get("error", "cannot inspect config"))
		target = {"path": resolved_path, "key_path": client.server_key_path}
	var target_path := str(target.get("path", resolved_path))
	var key_path: PackedStringArray = target.get("key_path", client.server_key_path)
	var key := key_path[0] if key_path.size() > 0 else "mcpServers"
	if client.command_shape != McpClient.CommandShape.NONE:
		var lines: Array[String] = []
		var launch_error := McpJsonStrategy.command_launch_error(client, launch)
		if launch_error.is_empty():
			var command_entry := McpJsonStrategy.build_entry(client, server_url, null, launch)
			lines.append("Edit %s and add under \"%s\":" % [target_path, key])
			lines.append("  \"%s\": %s" % [server_name, _format_entry_inline(command_entry)])
		else:
			lines.append("Attach launch command unavailable: %s" % launch_error)
		if client.command_supports_url_fallback:
			lines.append("")
			lines.append("Advanced fallback — use this URL-mode entry instead; never configure both shapes together. URL mode depends on your client's own reconnect behavior. If the server is down when the client starts, restarting the client may be required.")
			lines.append("Edit %s and add under \"%s\":" % [target_path, key])
			var fallback_entry := McpJsonStrategy.build_url_entry(client, server_url)
			lines.append("  \"%s\": %s" % [server_name, _format_entry_inline(fallback_entry)])
		if not target_note.is_empty():
			lines.append("")
			lines.append(target_note)
		return "\n".join(lines)
	var entry := McpJsonStrategy.build_entry(client, server_url)
	var instructions := "Edit %s and add under \"%s\":\n  \"%s\": %s" % [target_path, key, server_name, _format_entry_inline(entry)]
	if not target_note.is_empty():
		instructions += "\n\n" + target_note
	return instructions


static func _build_toml(
	client: McpClient,
	_server_name: String,
	server_url: String,
	resolved_path: String,
	launch: Dictionary = {},
) -> String:
	var header := _toml_header(client)
	if client.command_shape != McpClient.CommandShape.NONE:
		var lines: Array[String] = []
		var rendered := McpTomlStrategy.render_body(client, server_url, launch)
		if bool(rendered.get("ok", false)):
			lines.append("Edit %s and add:" % resolved_path)
			lines.append("  %s" % header)
			for body_line in rendered.get("lines", []):
				lines.append("  %s" % str(body_line))
		else:
			lines.append("Attach launch command unavailable: %s" % str(rendered.get("error", "no compatible launcher found")))
		if client.command_supports_url_fallback:
			lines.append("")
			lines.append("Advanced fallback — replace the command/args block above with this URL-mode block; never configure both shapes together. URL mode depends on your client's own reconnect behavior. If the server is down when the client starts, restarting the client may be required.")
			lines.append("Edit %s and add:" % resolved_path)
			lines.append("  %s" % header)
			lines.append("  url = %s" % McpTomlStrategy.encode_basic_string(server_url))
		return "\n".join(lines)
	var body := McpTomlStrategy.format_body(client.toml_body_template, server_url)
	var lines: Array[String] = ["Edit %s and add:" % resolved_path, "  %s" % header]
	for b in body:
		lines.append("  %s" % String(b))
	return "\n".join(lines)


static func _build_yaml(
	client: McpClient,
	server_name: String,
	server_url: String,
	resolved_path: String,
	launch: Dictionary = {},
) -> String:
	var key := client.server_key_path[0] if client.server_key_path.size() > 0 else "mcp_servers"
	if client.command_shape != McpClient.CommandShape.NONE:
		var lines: Array[String] = []
		var launch_error := McpYamlStrategy.command_launch_error(client, launch)
		if launch_error.is_empty():
			var command_entry := McpYamlStrategy.build_entry(client, server_url, null, launch)
			lines.append("Edit %s and add under '%s':" % [resolved_path, key])
			for entry_line in McpYamlStrategy.render_entry_lines(server_name, command_entry):
				lines.append(String(entry_line))
		else:
			lines.append("Attach launch command unavailable: %s" % launch_error)
		if client.command_supports_url_fallback:
			lines.append("")
			lines.append("Advanced fallback — use this URL-mode entry instead; never configure both shapes together. URL mode depends on your client's own reconnect behavior. If the server is down when the client starts, restarting the client may be required.")
			lines.append("Edit %s and add under '%s':" % [resolved_path, key])
			var fallback_entry := {client.entry_url_field: server_url}
			for entry_line in McpYamlStrategy.render_entry_lines(server_name, fallback_entry):
				lines.append(String(entry_line))
		return "\n".join(lines)
	var entry := McpYamlStrategy.build_entry(client, server_url)
	var lines: Array[String] = [
		"Edit %s and add under '%s':" % [resolved_path, key],
		"  %s:" % server_name,
	]
	for k in entry:
		lines.append("    %s: %s" % [k, str(entry[k])])
	return "\n".join(lines)


## DeepSeek Harness: the user pastes a loader `insert` row into the home
## patch layer (`$DSH_HOME/cordis.patch.yml`). Auto-configure writes exactly
## these lines, so the manual text matches the file Configure would produce
## byte-for-byte.
static func _build_dsh(
	client: McpClient,
	server_name: String,
	server_url: String,
	resolved_path: String,
	launch: Dictionary = {},
) -> String:
	var lines: Array[String] = ["Edit %s and add this loader entry (an `insert` row; a plain `- id:` row only overrides an existing bundle id and would be skipped):" % resolved_path]
	var entry_id_value := McpDshStrategy.entry_id(server_name)
	if client.command_shape != McpClient.CommandShape.NONE:
		var launch_error := McpDshStrategy.command_launch_error(client, launch)
		if launch_error.is_empty():
			var command_entry := McpDshStrategy.build_entry(client, server_name, server_url, null, launch)
			for row_line in McpDshStrategy.render_insert_row(entry_id_value, command_entry):
				lines.append(String(row_line))
		else:
			lines.append("Attach launch command unavailable: %s" % launch_error)
		if client.command_supports_url_fallback:
			lines.append("")
			## No command/args block was rendered on the launch-error path, so
			## "replace the block above" would point at nothing.
			var fallback_lead := (
				"replace the command/args block above with this URL-mode entry"
				if launch_error.is_empty()
				else "use this URL-mode entry instead"
			)
			lines.append("Advanced fallback — %s; never configure both shapes together. URL mode depends on the harness' own reconnect behavior. If the server is down when the harness starts, restarting the harness may be required." % fallback_lead)
			var fallback_entry := McpDshStrategy.build_url_entry(client, server_name, server_url)
			for row_line in McpDshStrategy.render_insert_row(entry_id_value, fallback_entry):
				lines.append(String(row_line))
		return "\n".join(lines)
	var url_entry := McpDshStrategy.build_url_entry(client, server_name, server_url)
	for row_line in McpDshStrategy.render_insert_row(entry_id_value, url_entry):
		lines.append(String(row_line))
	return "\n".join(lines)


## Mirrors the [section."name"] header `_toml_strategy._primary_header`
## emits, kept here so the manual-command text matches the file we'd write.
static func _toml_header(client: McpClient) -> String:
	var parts := client.toml_section_path
	if parts.size() < 2:
		return "[%s]" % ".".join(parts)
	var section := ".".join(McpClient._array_from_packed(McpClient._packed_slice(parts, 0, parts.size() - 1)))
	var name := parts[parts.size() - 1]
	return "[%s.\"%s\"]" % [section, name]


## Format an entry dict as a single inline JSON-ish string, matching the
## pre-refactor manual-command style: `{ "k": v, "k": v }` with spaces.
## Pre-existing manual-command tests assert the exact substring shape; this
## keeps them stable.
##
## Uses `JSON.stringify` for every leaf String (key OR value) so paths
## containing backslashes / quotes / newlines render as syntactically valid
## JSON. A Windows uvx path like `C:\Users\foo\uvx.exe` would otherwise be
## emitted as `"C:\Users\foo\uvx.exe"` — invalid JSON, unsafe to paste.
static func _format_entry_inline(entry: Dictionary) -> String:
	var parts: Array[String] = []
	for k in entry:
		parts.append("%s: %s" % [JSON.stringify(String(k)), _format_value(entry[k])])
	if parts.is_empty():
		return "{}"
	return "{ %s }" % ", ".join(parts)


static func _format_value(value: Variant) -> String:
	# Strings, bools, numbers, null all round-trip correctly through JSON.stringify
	# without spurious quoting of non-string scalars (true → `true`, 5 → `5`).
	# Arrays and Dictionaries are formatted manually so the inline ` { k: v } `
	# spacing matches the pre-refactor manual-command output shape that tests
	# pin with assert_contains.
	if value is Array:
		var arr_parts: Array[String] = []
		for v in value:
			arr_parts.append(_format_value(v))
		return "[%s]" % ", ".join(arr_parts)
	if value is Dictionary:
		var d_parts: Array[String] = []
		for k in value:
			d_parts.append("%s: %s" % [JSON.stringify(String(k)), _format_value(value[k])])
		if d_parts.is_empty():
			return "{}"
		return "{ %s }" % ", ".join(d_parts)
	return JSON.stringify(value)
