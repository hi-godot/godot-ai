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


static func configure(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}
	## Fail closed before touching the file — same contract as JSON/TOML.
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}

	var seed_path := str(resolution.get("seed_path", ""))
	var read_path := seed_path if not FileAccess.file_exists(path) and not seed_path.is_empty() else path
	var read := _read(read_path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [read_path, read["error"]]}

	var text: String = read["data"]
	var block := _extract_block(text)
	var entries: Dictionary = block["entries"]

	# Preserve existing entry's user-mutable keys; force the transport keys.
	var existing: Dictionary = entries.get(server_name, {})
	var new_entry := build_entry(client, server_url, existing, launch)
	entries[server_name] = new_entry

	var out := _assemble(text, block["prefix_lines"], entries, block["suffix_lines"])
	if not McpAtomicWrite.write(path, out):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": McpClient.configured_message(client, server_url)}


static func check_status(
	client: McpClient, server_name: String, server_url: String, launch: Dictionary = {}
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch)["status"]


## Same contract as the JSON/TOML strategies (#711): {status, error_msg}.
## An existing-but-unreadable config is ERROR with the diagnostic — not
## NOT_CONFIGURED — so the dock row can tell "no config" from "config the
## editor can't read" instead of offering a Configure that would fail.
static func check_status_details(
	client: McpClient, server_name: String, server_url: String, launch: Dictionary = {}
) -> Dictionary:
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
	## An entry exists but no verified launcher does — mirror JSON/TOML: this
	## is an environment ERROR, not entry drift.
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": launch_error}
	if verify_entry(client, entry, server_url, launch):
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
##
## URL mode (`CommandShape.NONE`): Hermes HTTP entries are transport-inferred
## — { url: <url> } plus whatever user-mutable keys (headers, enabled, tools,
## ...) the existing entry carries. Stdio-bridge keys are the one exception
## (see _STDIO_BRIDGE_KEYS). No `type` field.
##
## Command mode (`CommandShape.FLAT`, #838): flat `command` + `args` keys,
## transport inferred the same way — which is exactly why the descriptor's
## `command_legacy_keys` (url, headers) must be scrubbed: a Hermes entry with
## both a url and a command picks the wrong transport. User keys survive.
static func build_entry(
	client: McpClient,
	server_url: String,
	existing: Variant = null,
	launch: Dictionary = {},
) -> Dictionary:
	if client.command_shape == McpClient.CommandShape.FLAT:
		var command_entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
		command_entry["command"] = str(launch.get("command", ""))
		command_entry["args"] = _array_copy(launch.get("args", []))
		if not client.command_transport_key.is_empty():
			command_entry[client.command_transport_key] = client.command_transport_value
		for key in client.command_initial_fields:
			if not command_entry.has(key):
				command_entry[key] = client.command_initial_fields[key]
		for key in client.command_legacy_keys:
			command_entry.erase(String(key))
		return command_entry
	if client.command_shape != McpClient.CommandShape.NONE:
		## Every production caller checks command_launch_error first. Keep this
		## builder defensive too so a future unsupported shape cannot silently
		## degrade into a flat YAML entry.
		return {}
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
## These must NOT survive a URL reconfigure: a Hermes entry with both a url
## and a command picks the wrong transport.
const _STDIO_BRIDGE_KEYS := ["command", "args", "env"]


## Empty string when this client's launch requirements are satisfied.
## Mirrors `McpJsonStrategy.command_launch_error`; YAML supports FLAT only.
static func command_launch_error(client: McpClient, launch: Dictionary) -> String:
	if client.command_shape == McpClient.CommandShape.NONE:
		return ""
	if client.command_shape != McpClient.CommandShape.FLAT:
		return "%s uses a command shape not supported by YAML yet" % client.display_name
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


## Verify a stored entry matches.
##
## URL mode: Hermes entries have no transport type pin, so verification is:
## url matches. Extra keys (headers, enabled, tools) are user-mutable and
## intentionally NOT checked (mirrors json entry_initial_fields).
##
## Command mode: every launch-affecting value must match exactly and legacy
## URL-transport keys must be gone — their presence is migration drift.
static func verify_entry(
	client: McpClient,
	entry: Dictionary,
	server_url: String,
	launch: Dictionary = {},
) -> bool:
	if client.command_shape != McpClient.CommandShape.NONE:
		if client.command_shape != McpClient.CommandShape.FLAT or not bool(launch.get("ok", false)):
			return false
		for key in client.command_legacy_keys:
			if entry.has(String(key)):
				return false
		if entry.get("command") != launch.get("command"):
			return false
		if not _arrays_equal(entry.get("args", null), launch.get("args", null)):
			return false
		if not client.command_transport_key.is_empty():
			if entry.get(client.command_transport_key, null) != client.command_transport_value:
				return false
		return true
	return entry.get(client.entry_url_field, "") == server_url


static func _array_copy(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	if value is PackedStringArray:
		return McpClient._array_from_packed(value)
	return []


static func _arrays_equal(left: Variant, right: Variant) -> bool:
	if not (left is Array or left is PackedStringArray):
		return false
	if not (right is Array or right is PackedStringArray):
		return false
	var left_array := _array_copy(left)
	var right_array := _array_copy(right)
	if left_array.size() != right_array.size():
		return false
	for i in range(left_array.size()):
		if left_array[i] != right_array[i]:
			return false
	return true


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
			data[key] = coerce_scalar(val)
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
		sub[key] = coerce_scalar(val)
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


## Public rendering seam for the dock's manual-instruction text, so the
## pasted YAML matches what Configure would write byte-for-byte.
static func render_entry_lines(name: String, data: Dictionary) -> PackedStringArray:
	return _emit_entry(name, data)


## Emit one `  name:` entry with its scalar keys (top level only; headers
## sub-dict is re-emitted as nested scalars; arrays — the command entry's
## `args` — are emitted in flow style on one line).
static func _emit_entry(name: String, data: Dictionary) -> PackedStringArray:
	var lines: PackedStringArray = []
	lines.append(INDENT + "%s:" % name)
	for key in data:
		var val = data[key]
		if val is Dictionary:
			lines.append(INDENT + INDENT + "%s:" % key)
			for sk in val:
				lines.append(INDENT + INDENT + INDENT + "%s: %s" % [sk, emit_scalar(val[sk])])
		elif val is Array or val is PackedStringArray:
			lines.append(INDENT + INDENT + "%s: %s" % [key, emit_flow_array(_array_copy(val))])
		else:
			lines.append(INDENT + INDENT + "%s: %s" % [key, emit_scalar(val)])
	return lines


## Flow-style sequence with every item double-quoted. JSON string quoting is
## valid YAML double-quote style (shared escape set), so the same encoding
## both writes the file and — via JSON.parse_string in `coerce_scalar` —
## reads it back for verification. Shared with `McpDshStrategy` for the
## DeepSeek Harness patch-list `args` lines.
static func emit_flow_array(values: Array) -> String:
	var parts: Array[String] = []
	for v in values:
		parts.append(JSON.stringify(str(v)))
	return "[%s]" % ", ".join(parts)


static func emit_scalar(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_INT:
			return str(int(v))
		TYPE_FLOAT:
			return str(float(v))
		_:
			return emit_string_scalar(str(v))


## Plain YAML scalars cannot safely carry ": ", " #", quotes, flow
## indicators, or leading indicator characters — a Windows launcher path with
## spaces would silently corrupt the entry. Quote exactly when needed so
## existing plain values (urls, bools-as-strings) keep their current
## byte-shape on rewrite. Backslashes are quoted too: a Windows path parses
## either way, but quoting makes the written shape unambiguous for any
## consumer. Shared with `McpDshStrategy` for DeepSeek Harness patch entries.
static func emit_string_scalar(s: String) -> String:
	if s.is_empty():
		return "\"\""
	var needs_quote := s.begins_with(" ") or s.ends_with(" ")
	if not needs_quote:
		for needle in [": ", " #", "\"", "'", "\n", "\t", "\\", "{", "}", "[", "]", ","]:
			if s.contains(needle):
				needs_quote = true
				break
	if not needs_quote:
		for prefix in ["#", "-", "?", "&", "*", "!", "|", ">", "%", "@", "`"]:
			if s.begins_with(prefix):
				needs_quote = true
				break
	return JSON.stringify(s) if needs_quote else s


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
## bare true/false/numbers are typed; double-quoted flow sequences (the
## command entry's `args`) parse back into an Array. Good enough for Hermes'
## url/headers/command/args. A hand-edited args in block style or with
## unquoted items doesn't JSON-parse — it stays a raw string, compares
## unequal, and surfaces as CONFIGURED_MISMATCH, which Reconfigure
## normalizes back to the flow form. Public: the dsh strategy parses its
## patch-list scalars with the same rules, so both YAML dialects share one
## coercion (#867 review).
static func coerce_scalar(s: String) -> Variant:
	var t := s.strip_edges()
	if t.begins_with("[") and t.ends_with("]"):
		var parsed_array: Variant = JSON.parse_string(t)
		if parsed_array is Array:
			return parsed_array
		return t
	if t.begins_with("\"") and t.ends_with("\""):
		var parsed_string: Variant = JSON.parse_string(t)
		if parsed_string is String:
			return parsed_string
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
