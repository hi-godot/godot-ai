@tool
class_name McpYamlStrategy
extends RefCounted

## Minimal YAML upsert for Hermes Agent MCP config.
##
## Hermes reads MCP servers from ~/.hermes/config.yaml under the
## `mcp_servers` key (snake_case, YAML). HTTP entries are transport-inferred:
## just `url` (plus optional `headers`), no `type` field. We only parse the
## `mcp_servers` block and re-emit it; other top-level keys in the user's
## config.yaml are preserved verbatim by round-tripping the raw lines around
## that block. No general YAML parser — Godot has none in stdlib, and Hermes
## only needs this one shape. See issue #640.

const INDENT := "  "  # YAML forbids tab indentation; match the 2-space style of ~/.hermes/config.yaml


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var read := _read(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}

	var text: String = read["data"]
	var block := _extract_block(text)
	var entries: Dictionary = block["entries"]

	# Preserve existing entry's user-mutable keys; force url.
	var existing: Dictionary = entries.get(server_name, {})
	var new_entry := build_entry(client, server_url, existing)
	entries[server_name] = new_entry

	var out := _assemble(text, block["prefix_lines"], entries, block["suffix_lines"])
	if not McpAtomicWrite.write(path, out):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	return check_status_details(client, server_name, server_url)["status"]


## Same contract as the JSON/TOML strategies (#711): {status, error_msg}.
## An existing-but-unreadable config is ERROR with the diagnostic — not
## NOT_CONFIGURED — so the dock row can tell "no config" from "config the
## editor can't read" instead of offering a Configure that would fail.
static func check_status_details(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var read := _read(path)
	if not read["ok"]:
		return {
			"status": McpClient.Status.ERROR,
			"error_msg": "Cannot read %s: %s" % [path, read["error"]],
		}
	var block := _extract_block(String(read["data"]))
	var entries: Dictionary = block["entries"]
	if not entries.has(server_name):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var entry: Variant = entries[server_name]
	if not (entry is Dictionary):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	if verify_entry(client, entry, server_url):
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var read := _read(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var text: String = read["data"]
	var block := _extract_block(text)
	var entries: Dictionary = block["entries"]
	if not entries.has(server_name):
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	entries.erase(server_name)
	var out := _assemble(text, block["prefix_lines"], entries, block["suffix_lines"])
	if not McpAtomicWrite.write(path, out):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Build the entry dict written under mcp_servers[server_name].
## Hermes HTTP entries are transport-inferred — { url: <url> } plus whatever
## user-mutable keys (headers, enabled, tools, ...) the existing entry
## carries. Stdio-bridge keys are the one exception (see _STDIO_BRIDGE_KEYS).
## No `type` field.
static func build_entry(client: McpClient, server_url: String, existing: Variant = null) -> Dictionary:
	var entry: Dictionary = {}
	if existing is Dictionary:
		## User-mutable keys (headers, enabled, tools, ...) survive a
		## reconfigure — the same preservation contract the JSON strategy's
		## entry_initial_fields split implements. Only the stdio-bridge keys
		## are scrubbed (see _STDIO_BRIDGE_KEYS), then the url is repointed.
		entry = (existing as Dictionary).duplicate(true)
		for stale_key in _STDIO_BRIDGE_KEYS:
			entry.erase(stale_key)
	entry[client.entry_url_field] = server_url
	return entry


## Keys a prior stdio-bridge entry (e.g. `command: uvx mcp-proxy`) may carry.
## These must NOT survive a reconfigure: a Hermes entry with both a url and a
## command picks the wrong transport.
const _STDIO_BRIDGE_KEYS := ["command", "args", "env"]


## Verify a stored entry matches. Hermes entries have no transport type pin,
## so verification is: url matches. Extra keys (headers, enabled, tools) are
## user-mutable and intentionally NOT checked (mirrors json entry_initial_fields).
static func verify_entry(client: McpClient, entry: Dictionary, server_url: String) -> bool:
	return entry.get(client.entry_url_field, "") == server_url


# --- YAML block handling (scoped to mcp_servers) -------------------------

## Parse the file into three regions:
##   prefix_lines  — everything before `mcp_servers:` (may be empty)
##   entries       — the map of server_name -> {url, ...} under mcp_servers
##   suffix_lines  — everything after the mcp_servers block (may be empty)
## This lets us rewrite only the mcp_servers block and keep the rest of the
## user's config.yaml byte-for-byte intact.
static func _extract_block(text: String) -> Dictionary:
	## allow_empty must stay true: dropping empty splits would silently strip
	## the user's blank lines from the preserved prefix/suffix regions on
	## every rewrite. The parse loops below already skip blank lines.
	var lines := text.split("\n")
	var prefix: PackedStringArray = []
	var entries: Dictionary = {}
	var suffix: PackedStringArray = []
	var header_idx := -1
	for i in range(lines.size()):
		if lines[i].strip_edges().begins_with("mcp_servers:"):
			header_idx = i
			break
	if header_idx < 0:
		# No mcp_servers yet — whole file is prefix; block will be appended.
		prefix = lines.duplicate()
		return {"prefix_lines": prefix, "entries": entries, "suffix_lines": [], "header_idx": -1}

	for i in range(0, header_idx):
		prefix.append(lines[i])

	# Determine the indent of the first entry so we can tell sibling
	# entries (same indent) apart from nested keys (deeper indent) and
	# parent-level keys (less indent). All server entries under
	# `mcp_servers:` share one indent level; breaking on 0-indent alone
	# mis-nests 2-space-indented siblings under the first entry.
	var entry_indent := -1
	var probe := header_idx + 1
	while probe < lines.size() and _is_blank_or_comment(lines[probe]):
		probe += 1
	if probe < lines.size():
		entry_indent = _indent_of(lines[probe])

	# Empty block guard: the first nonblank line after the header must sit
	# DEEPER than the header itself to be an entry. At or above the header's
	# indent it is a sibling/parent key — parsing it as an entry would
	# swallow the user's next top-level key and re-emit it nested under
	# mcp_servers, corrupting the file.
	if probe < lines.size() and entry_indent <= _indent_of(lines[header_idx]):
		for j in range(header_idx + 1, lines.size()):
			suffix.append(lines[j])
		return {"prefix_lines": prefix, "entries": entries, "suffix_lines": suffix, "header_idx": header_idx}

	var i := header_idx + 1
	while i < lines.size():
		var raw := lines[i]
		## Comment-only lines inside the block are skipped like blanks —
		## treating one as an entry header would re-emit it as a bogus
		## `# comment:` server on rewrite. (Comments INSIDE the rewritten
		## block are consequently dropped; comments outside the block live
		## in prefix/suffix and survive verbatim.)
		if _is_blank_or_comment(raw):
			i += 1
			continue
		# Stop at any line indented less than a sibling entry (parent key
		# or a new top-level section), or at the header's own level.
		if _indent_of(raw) < entry_indent:
			break
		var entry := _parse_entry(raw, lines, i, entry_indent)
		if not entry["name"].is_empty():
			entries[entry["name"]] = entry["data"]
		i = entry["next_idx"]

	for j in range(i, lines.size()):
		suffix.append(lines[j])

	return {"prefix_lines": prefix, "entries": entries, "suffix_lines": suffix, "header_idx": header_idx}


## Parse one `  name:` entry starting at `lines[start]`. Consumes all deeper-
## indented sublines (url, headers, etc.) and returns the next sibling index.
static func _parse_entry(raw: String, lines: PackedStringArray, start: int, entry_indent: int) -> Dictionary:
	var name := raw.strip_edges().trim_suffix(":").strip_edges()
	var data: Dictionary = {}
	var i := start + 1
	while i < lines.size():
		var l := lines[i]
		## Comments inside an entry (e.g. `    # auth for CI`) would parse
		## as a `# auth for CI` key — skip them like blanks.
		if _is_blank_or_comment(l):
			i += 1
			continue
		# A line at or above the entry's indent is a sibling/parent key.
		if _indent_of(l) <= entry_indent:
			break
		var stripped := l.strip_edges()
		var colon := stripped.find(":")
		if colon < 0:
			i += 1
			continue
		var key := stripped.substr(0, colon).strip_edges()
		var val := stripped.substr(colon + 1).strip_edges()
		if val.is_empty():
			# Nested block (e.g. headers:). Parse as raw sub-dict lines for
			# preservation; we don't introspect deeper than url at the top.
			var sub := _parse_subblock(lines, i + 1, entry_indent)
			data[key] = sub["value"]
			i = sub["next_idx"]
		else:
			data[key] = _coerce_scalar(val)
			i += 1
	return {"name": name, "data": data, "next_idx": i}


## Parse a nested block (e.g. headers:) as a preserved sub-dictionary of
## scalar key/values. Deeper nesting is flattened into scalar strings — fine
## for Hermes' known shape (headers are flat key: value).
static func _parse_subblock(lines: PackedStringArray, start: int, entry_indent: int) -> Dictionary:
	var sub: Dictionary = {}
	var i := start
	while i < lines.size():
		var l := lines[i]
		if _is_blank_or_comment(l):
			i += 1
			continue
		# A line at or above the parent entry's indent ends the nested block.
		if _indent_of(l) <= entry_indent:
			break
		var stripped := l.strip_edges()
		var colon := stripped.find(":")
		if colon < 0:
			i += 1
			continue
		var key := stripped.substr(0, colon).strip_edges()
		var val := stripped.substr(colon + 1).strip_edges()
		if val.is_empty():
			i += 1
			continue
		sub[key] = _coerce_scalar(val)
		i += 1
	return {"value": sub, "next_idx": i}


## Reassemble the full file text from prefix + a freshly built mcp_servers
## block + suffix. If the block didn't exist before, it is appended.
static func _assemble(_text: String, prefix: PackedStringArray, entries: Dictionary, suffix: PackedStringArray) -> String:
	var out: PackedStringArray = []
	for l in prefix:
		out.append(l)
	# Trim trailing blank lines from prefix so we don't stack double blanks.
	while out.size() > 0 and out[out.size() - 1].strip_edges().is_empty():
		out.remove_at(out.size() - 1)

	if not _text.contains("mcp_servers:"):
		# File existed but had no mcp_servers block — append it.
		if out.size() > 0:
			out.append("")
		out.append("mcp_servers:")
		for name in entries:
			out.append_array(_emit_entry(name, entries[name]))
	else:
		out.append("mcp_servers:")
		for name in entries:
			out.append_array(_emit_entry(name, entries[name]))

	# Suffix: keep as-is.
	for l in suffix:
		out.append(l)
	return "\n".join(out)


## Emit one `  name:` entry with its scalar keys (top level only; headers
## sub-dict is re-emitted as nested scalars).
static func _emit_entry(name: String, data: Dictionary) -> PackedStringArray:
	var lines: PackedStringArray = []
	lines.append(INDENT + "%s:" % name)
	for key in data:
		var val = data[key]
		if val is Dictionary:
			lines.append(INDENT + INDENT + "%s:" % key)
			for sk in val:
				lines.append(INDENT + INDENT + INDENT + "%s: %s" % [sk, _emit_scalar(val[sk])])
		else:
			lines.append(INDENT + INDENT + "%s: %s" % [key, _emit_scalar(val)])
	return lines


static func _emit_scalar(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
		TYPE_FLOAT:
			return str(float(v))
		_:
			return str(v)


## Blank and comment-only lines carry no structure — every scan loop skips
## them the same way so a `# comment` can never be mistaken for an entry
## header or a key/value line.
static func _is_blank_or_comment(line: String) -> bool:
	var stripped := line.strip_edges()
	return stripped.is_empty() or stripped.begins_with("#")


## Returns the leading-whitespace indent width of a line (spaces + tabs
## counted as 1 each). Used to distinguish sibling entries (same indent)
## from nested keys (deeper indent) and parent-level keys (less indent).
static func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == " " or line[n] == "\t"):
		n += 1
	return n


## Minimal scalar coercion for parsed YAML values. Quotes are stripped;
## bare true/false/numbers are typed. Good enough for Hermes' url/headers.
static func _coerce_scalar(s: String) -> Variant:
	var t := s.strip_edges()
	if t.begins_with("\"") and t.ends_with("\""):
		return t.substr(1, t.length() - 2)
	if t.begins_with("'") and t.ends_with("'"):
		return t.substr(1, t.length() - 2)
	if t == "true":
		return true
	if t == "false":
		return false
	if t.is_valid_int():
		return t.to_int()
	if t.is_valid_float():
		return t.to_float()
	return t


## Returns {"ok": true, "data": String} when the file is absent or readable,
## and {"ok": false, "error": String} when unreadable. Callers must NOT fall
## back to an empty string on the error path — doing so blows away the user's
## other config.yaml entries on the next write.
static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "error": "could not open for reading (%s)" % error_string(err)}
	var t := f.get_as_text()
	f.close()
	return {"ok": true, "data": t}
