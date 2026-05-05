@tool
class_name McpTomlStrategy
extends RefCounted

## Minimal TOML upsert: replace or insert one [section."name"] block whose body
## comes from substituting `{url}` in `client.toml_body_template`. No
## descriptor-supplied Callables — see `_base.gd`.


static func configure(client: McpClient, _server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s" % client.display_name}

	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}
	if client.toml_body_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing toml_body_template" % client.display_name}
	var lines: Array[String] = _split_lines(String(read["data"]))
	var body: PackedStringArray = format_body(client.toml_body_template, server_url)

	var section := _find_section(lines, _all_headers(client))
	var header := _primary_header(client)
	var new_lines: Array[String] = [header]
	for b in body:
		new_lines.append(b)

	var output: Array[String] = []
	if section.is_empty():
		output.append_array(lines)
		if not output.is_empty() and not output[-1].strip_edges().is_empty():
			output.append("")
		output.append_array(new_lines)
	else:
		output.append_array(_slice(lines, 0, section["start"]))
		output.append_array(new_lines)
		output.append_array(_slice(lines, section["end"], lines.size()))

	if not McpAtomicWrite.write(path, "\n".join(output)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(client: McpClient, _server_name: String, server_url: String) -> McpClient.Status:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return McpClient.Status.NOT_CONFIGURED
	var read := _read_or_init(path)
	if not read["ok"]:
		return McpClient.Status.NOT_CONFIGURED
	var lines: Array[String] = _split_lines(String(read["data"]))
	var section := _find_section(lines, _all_headers(client))
	if section.is_empty():
		return McpClient.Status.NOT_CONFIGURED

	var configured_url := ""
	var enabled := true
	for i in range(section["start"] + 1, section["end"]):
		var trimmed := lines[i].strip_edges()
		if trimmed.begins_with("url ="):
			var first := trimmed.find("\"")
			var last := trimmed.rfind("\"")
			if first >= 0 and last > first:
				configured_url = trimmed.substr(first + 1, last - first - 1)
		elif trimmed.begins_with("enabled ="):
			enabled = trimmed.to_lower().find("false") < 0
	## Section exists with our `SERVER_NAME` header — a URL mismatch (or a
	## disabled entry) is drift, not "never configured". See `_base.gd`.
	if configured_url != server_url or not enabled:
		return McpClient.Status.CONFIGURED_MISMATCH
	return McpClient.Status.CONFIGURED


static func remove(client: McpClient, _server_name: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var lines: Array[String] = _split_lines(String(read["data"]))
	var headers := _all_headers(client)
	## Subtables in the namespace (e.g. [mcp_servers.godot-ai.tools.session_list]
	## that codex users add to set per-tool approval_mode) must be removed
	## too. Leaving them behind keeps `mcp_servers.godot-ai` implicitly
	## defined, so a later configure that writes [mcp_servers."godot-ai"]
	## produces a duplicate-key TOML error.
	var subtable_prefixes := _subtable_prefixes(headers)

	var output: Array[String] = []
	var i := 0
	while i < lines.size():
		if _matches_any_header(lines[i], headers) or _matches_subtable_prefix(lines[i], subtable_prefixes):
			i += 1
			while i < lines.size():
				if _is_any_section_header(lines[i]):
					break
				i += 1
			continue
		output.append(lines[i])
		i += 1

	if not McpAtomicWrite.write(path, "\n".join(output)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Substitute `{url}` in every body-template line.
static func format_body(template: PackedStringArray, server_url: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in template:
		out.append(String(line).replace("{url}", server_url))
	return out


# --- helpers --------------------------------------------------------------

## Returns {"ok": true, "data": String} when the file is absent or readable,
## and {"ok": false, "error": String} when the file exists but cannot be
## opened. Callers must NOT fall back to an empty string on the error path —
## doing so blows away the user's other MCP entries on the next write.
static func _read_or_init(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "error": "could not open for reading (error %d)" % err}
	var t := f.get_as_text()
	f.close()
	return {"ok": true, "data": t}


static func _split_lines(content: String) -> Array[String]:
	var out: Array[String] = []
	for line in content.split("\n"):
		out.append(line)
	return out


static func _slice(lines: Array[String], from: int, to: int) -> Array[String]:
	var out: Array[String] = []
	for i in range(from, to):
		out.append(lines[i])
	return out


static func _primary_header(client: McpClient) -> String:
	# Quoted form: [section."name"] for ids that contain hyphens.
	var parts := client.toml_section_path
	if parts.size() < 2:
		return "[%s]" % ".".join(parts)
	var section := ".".join(McpClient._packed_slice(parts, 0, parts.size() - 1))
	var name := parts[parts.size() - 1]
	return "[%s.\"%s\"]" % [section, name]


static func _all_headers(client: McpClient) -> Array[String]:
	var primary := _primary_header(client)
	var out: Array[String] = [primary]
	## TOML accepts bare keys ([A-Za-z0-9_-]+) unquoted in section headers,
	## so [mcp_servers.godot-ai] is a valid hand-written form of the same
	## logical key we emit as [mcp_servers."godot-ai"]. Match both during
	## reconfigure / status / remove or a hand-edited (or older-plugin)
	## bare-key file gets a duplicate quoted section appended that breaks
	## the user's TOML parser.
	var bare := _bare_key_header(client)
	if not bare.is_empty() and bare != primary:
		out.append(bare)
	for legacy in client.toml_legacy_section_aliases:
		out.append("[%s]" % legacy)
	return out


static func _bare_key_header(client: McpClient) -> String:
	var parts := client.toml_section_path
	if parts.is_empty():
		return ""
	for p in parts:
		if not _is_bare_key(String(p)):
			return ""
	return "[%s]" % ".".join(parts)


static func _is_bare_key(s: String) -> bool:
	if s.is_empty():
		return false
	for i in range(s.length()):
		var c := s.unicode_at(i)
		var alpha := (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		var digit := c >= 48 and c <= 57
		var dash_or_under := c == 45 or c == 95  # '-' or '_'
		if not (alpha or digit or dash_or_under):
			return false
	return true


## Subtable prefixes derived from each header in `headers`. Strips the
## closing `]` and appends `.` so a header `[a.b]` becomes the prefix
## `[a.b.` — matching subtables `[a.b.<rest>]` but NOT siblings like
## `[a.b-other]` (next char must be a dot, not anything bare-key-valid).
static func _subtable_prefixes(headers: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for h in headers:
		if h.length() > 2 and h.ends_with("]"):
			out.append(h.substr(0, h.length() - 1) + ".")
	return out


## Mirror of `_matches_any_header` for subtable prefixes — line must
## start with `[a.b.` and have a closing `]` followed only by whitespace
## or a comment.
static func _matches_subtable_prefix(line: String, prefixes: Array[String]) -> bool:
	var trimmed := line.strip_edges()
	for p in prefixes:
		if not trimmed.begins_with(p):
			continue
		var rest := trimmed.substr(p.length())
		var bracket := rest.find("]")
		if bracket < 0:
			continue
		var remainder := rest.substr(bracket + 1).strip_edges()
		if remainder.is_empty() or remainder.begins_with("#"):
			return true
	return false


## Exact-header match. We cannot use a simple prefix check because
## `[mcp_servers."godot-ai"` is a prefix of `[mcp_servers."godot-ai-dev"]`,
## which would silently delete unrelated sections during remove().
static func _matches_any_header(line: String, headers: Array[String]) -> bool:
	var trimmed := line.strip_edges()
	for h in headers:
		if not trimmed.begins_with(h):
			continue
		var remainder := trimmed.substr(h.length()).strip_edges()
		if remainder.is_empty() or remainder.begins_with("#"):
			return true
	return false


static func _find_section(lines: Array[String], headers: Array[String]) -> Dictionary:
	for i in range(lines.size()):
		if _matches_any_header(lines[i], headers):
			var end := lines.size()
			for j in range(i + 1, lines.size()):
				if _is_any_section_header(lines[j]):
					end = j
					break
			return {"start": i, "end": end}
	return {}


## Generic "is this line a TOML section header" check that tolerates an
## inline comment after the closing `]`, e.g. `[next_section] # note`.
## The pre-fix `nt.begins_with("[") and nt.ends_with("]")` rejected those
## lines, so a hand-written comment after a header would let the
## section-deletion / section-end loops walk straight through into the
## following section and clobber unrelated content.
static func _is_any_section_header(line: String) -> bool:
	var trimmed := line.strip_edges()
	if not trimmed.begins_with("["):
		return false
	var bracket := trimmed.find("]")
	if bracket < 0:
		return false
	var remainder := trimmed.substr(bracket + 1).strip_edges()
	return remainder.is_empty() or remainder.begins_with("#")
