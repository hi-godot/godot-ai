@tool
class_name McpManualCommand
extends RefCounted

## Synthesize the "Run this manually" string the dock surfaces when
## auto-configure can't find a CLI / write a file. Generated from the
## descriptor's declarative fields — there is no per-client builder
## Callable. See `_base.gd` for why descriptors are data-only.


static func build(client: McpClient, server_name: String, server_url: String, resolved_path: String) -> String:
	match client.config_type:
		"cli":
			return _build_cli(client, server_name, server_url)
		"json":
			return _build_json(client, server_name, server_url, resolved_path)
		"toml":
			return _build_toml(client, server_name, server_url, resolved_path)
	return ""


## CLI clients: format the register template against the *short* CLI name so
## the user can paste it into a terminal regardless of where their binary
## lives. (The auto-configure path resolves to an absolute uvx-style path;
## that's noise for a paste-into-terminal hint.)
static func _build_cli(client: McpClient, server_name: String, server_url: String) -> String:
	if client.cli_register_template.is_empty() or client.cli_names.is_empty():
		return ""
	var short_name: String = String(client.cli_names[0])
	# Prefer the non-.exe form for a cross-platform-looking command line.
	for n in client.cli_names:
		if not String(n).ends_with(".exe"):
			short_name = String(n)
			break
	var args := McpCliStrategy.format_args(client.cli_register_template, server_name, server_url)
	var parts: Array[String] = [short_name]
	parts.append_array(args)
	return " ".join(parts)


static func _build_json(client: McpClient, server_name: String, server_url: String, resolved_path: String) -> String:
	var entry := McpJsonStrategy.build_entry(client, server_url)
	var entry_text := _format_entry_inline(entry)
	var key := client.server_key_path[0] if client.server_key_path.size() > 0 else "mcpServers"
	return "Edit %s and add under \"%s\":\n  \"%s\": %s" % [resolved_path, key, server_name, entry_text]


static func _build_toml(client: McpClient, _server_name: String, server_url: String, resolved_path: String) -> String:
	var header := _toml_header(client)
	var body := McpTomlStrategy.format_body(client.toml_body_template, server_url)
	var lines: Array[String] = ["Edit %s and add:" % resolved_path, "  %s" % header]
	for b in body:
		lines.append("  %s" % String(b))
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
