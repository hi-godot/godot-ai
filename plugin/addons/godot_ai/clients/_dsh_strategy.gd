@tool
class_name McpDshStrategy
extends RefCounted

## Configure / status / remove for DeepSeek Harness (dsh) MCP servers.
##
## DeepSeek Harness has no `mcp` CLI verb (verified against dsh
## 0.1.0-rc.6 — `dsh --help` exposes only `web` and `plugin`). MCP servers
## register as `@deepseek-ai/dsh-mcp-client` plugin entries in the HOME patch
## layer `$DSH_HOME/cordis.patch.yml` — the machine-local layer dsh applies
## over EVERY profile's own patch layer (the web GUI included), so one entry
## covers every profile the user boots.
##
## The patch file is a top-level YAML array of loader patch entries
## (`@deepseek-ai/cordis-plugin-include`'s `applyEntryPatches`). A non-insert
## row only OVERRIDES an existing bundle row (a new id is skipped with a
## warning), so a brand-new server must be added with an `insert` row:
##
##     - insert:
##         - id: mcp-godot-ai
##           name: '@deepseek-ai/dsh-mcp-client'
##           config:
##             serverName: godot-ai
##             transport: stdio
##             command: "..."
##             args: [...]
##
## Both shapes verified live against the dsh loader
## (`dsh --profile web --dump-config` composes the inserted entry; a plain
## row for a new id warns "patch: entry not found" and is skipped). We write
## one dedicated insert row per server, preserve every other row byte-for-byte
## (including other users' insert rows, overrides, comments, and `!!js`
## expressions), and status-verify the entry we wrote — the same file-read
## drift contract the JSON/TOML/YAML strategies use.
##
## The entry's `config` nests the launch under `serverName`/`transport`/
## `command`/`args`; `serverName` is the model-facing tool namespace
## (`mcp__godot-ai__<tool>`), so it carries the server name like the
## `server_key_path` map key does for the other strategies.

## Loader entry id prefix inside the patch list. The full id is
## `<prefix><server_name>` — "mcp-godot-ai" for the godot-ai server.
const ENTRY_ID_PREFIX := "mcp-"
## The loader plugin that bridges MCP servers into the harness. Must be
## installed in the profile's node_modules (dsh ships it as a dependency of
## the CLI package). Quoted in the file: `@` is a reserved YAML indicator and
## cannot start a plain scalar.
const PLUGIN_NAME := "@deepseek-ai/dsh-mcp-client"
## Indent of a nested entry header under `- insert:` (children step 2 spaces
## deeper), matching the shipped profile patch files.
const ENTRY_INDENT := 4


static func entry_id(server_name: String) -> String:
	return ENTRY_ID_PREFIX + server_name


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
	## Fail closed before touching the file — same contract as JSON/TOML/YAML.
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}

	var read := _read(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}
	## Fail closed on content that is not a loader patch list: dsh's patch
	## parser rejects a non-array file at boot, so appending our row to a
	## top-level mapping would hand the user a broken file (#867 review).
	## `[]` is a valid empty sequence meaning "no rows"; the literal must not
	## survive an append (block rows after `[]` are malformed YAML), so only
	## that line is dropped — comments around it belong to the user and stay.
	var text := String(read["data"])
	text = _strip_empty_flow_sequence(text)
	if not _is_patch_sequence(text):
		return {
			"status": "error",
			"message": "Refusing to overwrite %s: it is not a top-level YAML list of loader entries. Fix or remove the file, then re-run Configure." % path,
		}

	var existing_config: Variant = null
	var lines := _split_lines(text)
	var found := _find_entry_block(lines, entry_id(server_name), true)
	if found.is_empty():
		var plain := _find_entry_block(lines, entry_id(server_name), false)
		if not plain.is_empty():
			## A plain `- id: mcp-godot-ai` row is inert for a new id — the
			## loader skips it with a warning and never registers the server.
			## Replacing the whole row with the insert form migrates it.
			found = plain
	if not found.is_empty():
		## Pass the parsed config through so user-mutable fields (env,
		## toolCallTimeoutMs, reconnect) survive a reconfigure.
		existing_config = _extract_config(lines, found)
	var new_entry := build_entry(client, server_name, server_url, existing_config, launch)
	## Nested replacement must keep the sequence's existing header indent —
	## items of one block sequence share indentation, so a hand-written
	## 2-space file re-emitted at 4 spaces would no longer parse (#867
	## review). Fresh rows and plain-row migrations keep the 4-space style.
	var base_indent := ENTRY_INDENT
	if not found.is_empty():
		var header_indent := int(found.get("indent", 0))
		if header_indent > 0:
			base_indent = header_indent
	var rendered := render_nested_entry(entry_id(server_name), new_entry, base_indent)
	var out := ""
	if found.is_empty():
		out = _append_row(lines, rendered)
	else:
		out = _replace_lines(lines, found, rendered)
	if not McpAtomicWrite.write(path, out):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": McpClient.configured_message(client, server_url)}


static func check_status(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch)["status"]


## Same contract as the other strategies (#711): {status, error_msg}. An
## existing-but-unreadable config is ERROR with the diagnostic — not
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
	var text := String(read["data"])
	if not _is_patch_sequence(text):
		## A top-level mapping/scalar is not a dsh patch list: nothing in it
		## can be "configured", and a nested `- id:` inside a mapping must
		## not read as ours (#867 review).
		return {
			"status": McpClient.Status.ERROR,
			"error_msg": "%s is not a top-level YAML list of loader entries; fix or remove the file." % path,
		}
	var lines := _split_lines(text)
	var found := _find_entry_block(lines, entry_id(server_name), true)
	if found.is_empty():
		## A plain row for our id is inert (the loader skips unknown ids), so
		## the server is NOT registered no matter what the file says. It only
		## becomes registered once Configure rewrites it as an insert row.
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var config := _extract_config(lines, found)
	if config.is_empty():
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	## An entry exists but no verified launcher does — mirror the other
	## strategies: this is an environment ERROR, not entry drift.
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": launch_error}
	if verify_entry(client, config, server_name, server_url, launch):
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	return {
		"status": McpClient.Status.CONFIGURED_MISMATCH,
		"error_msg": "",
		"owned": McpClient.launch_mentions_godot_ai(McpClient.entry_launch_text(config)),
	}


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
	var text := String(read["data"])
	if not _is_patch_sequence(text):
		## Same fail-closed contract as configure (#867 review): never modify
		## a file that dsh cannot load as a patch list.
		return {
			"status": "error",
			"message": "Refusing to rewrite %s: it is not a top-level YAML list of loader entries. Fix or remove the file, then re-run Remove." % path,
		}
	var lines := _split_lines(text)
	var found := _find_entry_block(lines, entry_id(server_name), true)
	if found.is_empty():
		found = _find_entry_block(lines, entry_id(server_name), false)
	if found.is_empty():
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	var out := _remove_lines(lines, found)
	if _is_blank_or_comment_only(out):
		## dsh's patch parser requires a top-level YAML array: an empty or
		## comment-only patch file FAILS BOOT (`loadOptionalPatches` throws on
		## a non-array file), while an absent file means "no layer". After our
		## row is gone, an all-blank file must therefore be deleted, not
		## written back.
		if FileAccess.file_exists(path):
			var remove_err := DirAccess.remove_absolute(path)
			if remove_err != OK:
				return {"status": "error", "message": "Cannot remove %s (error %d)" % [path, remove_err]}
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	if not McpAtomicWrite.write(path, out):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Build the `config` dict written inside the loader entry. Command mode
## (FLAT, #838) nests `serverName`/`transport`/`command`/`args`; URL mode nests
## `serverName`/`transport`/`url`. Existing user state (env, timeouts,
## reconnect) survives a reconfigure via the deep copy.
static func build_entry(
	client: McpClient,
	server_name: String,
	server_url: String,
	existing: Variant = null,
	launch: Dictionary = {},
) -> Dictionary:
	var entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
	entry["serverName"] = server_name
	if client.command_shape == McpClient.CommandShape.FLAT:
		entry["command"] = str(launch.get("command", ""))
		entry["args"] = _array_copy(launch.get("args", []))
		if not client.command_transport_key.is_empty():
			entry[client.command_transport_key] = client.command_transport_value
		for key in client.command_initial_fields:
			if not entry.has(key):
				entry[key] = client.command_initial_fields[key]
		for key in client.command_legacy_keys:
			entry.erase(String(key))
		return entry
	if client.command_shape == McpClient.CommandShape.NONE:
		## Single URL-mode source of truth (#867 review): build_entry's URL
		## branch delegates to build_url_entry so the two can never drift.
		return build_url_entry(client, server_name, server_url, existing)
	return {}


## URL-mode sibling for the manual-instruction fallback text and the
## build_entry URL branch. DeepSeek Harness' mcp-client bridge accepts
## `transport: streamable-http` with a `url`, so the entry keeps the same
## `serverName` namespace with an HTTP transport instead of the stdio attach
## bridge. Existing user state survives via the deep copy.
static func build_url_entry(
	client: McpClient, server_name: String, server_url: String, existing: Variant = null
) -> Dictionary:
	var entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
	entry["serverName"] = server_name
	entry["transport"] = "streamable-http"
	if not client.entry_url_field.is_empty():
		entry[client.entry_url_field] = server_url
	return entry


## Verify a stored `config` dict matches the current launch. Command mode
## checks every launch-affecting value exactly and requires legacy URL keys
## gone; serverName must match the pinned namespace. URL mode checks the url
## and the streamable-http pin.
static func verify_entry(
	client: McpClient,
	config: Dictionary,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> bool:
	if config.get("serverName") != server_name:
		return false
	if client.command_shape != McpClient.CommandShape.NONE:
		if client.command_shape != McpClient.CommandShape.FLAT or not bool(launch.get("ok", false)):
			return false
		for key in client.command_legacy_keys:
			if config.has(String(key)):
				return false
		if config.get("command") != launch.get("command"):
			return false
		if not _arrays_equal(config.get("args", null), launch.get("args", null)):
			return false
		if not client.command_transport_key.is_empty():
			if config.get(client.command_transport_key, null) != client.command_transport_value:
				return false
		return true
	if config.get(client.entry_url_field, "") != server_url:
		return false
	return config.get("transport", "") == "streamable-http"


## Empty string when this client's launch requirements are satisfied.
## Mirrors `McpYamlStrategy.command_launch_error`; the patch-list dialect
## supports FLAT (and the URL fallback) only.
static func command_launch_error(client: McpClient, launch: Dictionary) -> String:
	if client.command_shape == McpClient.CommandShape.NONE:
		return ""
	if client.command_shape != McpClient.CommandShape.FLAT:
		return "%s uses a command shape not supported by DeepSeek Harness config yet" % client.display_name
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


# --- Rendering --------------------------------------------------------------

## Render a full `- insert:` row containing one nested loader entry. Public
## seam for the dock's manual-instruction text so the pasted YAML matches
## what Configure would write byte-for-byte.
static func render_insert_row(entry_id_value: String, config: Dictionary) -> PackedStringArray:
	var lines: PackedStringArray = ["- insert:"]
	lines.append_array(render_nested_entry(entry_id_value, config))
	return lines


## Render one nested loader entry (the `- id:` block inside an `insert`
## list). `base_indent` defaults to the 4-space style used by the shipped
## patch files; a nested replacement reuses the indent the existing entry was
## found at so the block sequence keeps a single indentation (#867 review).
static func render_nested_entry(
	entry_id_value: String, config: Dictionary, base_indent: int = ENTRY_INDENT
) -> PackedStringArray:
	var lines: PackedStringArray = []
	lines.append("%s- id: %s" % [_indent_str(base_indent), entry_id_value])
	lines.append("%sname: '%s'" % [_indent_str(base_indent + 2), PLUGIN_NAME])
	lines.append("%sconfig:" % _indent_str(base_indent + 2))
	for key in config:
		lines.append_array(_emit_field(String(key), config[key], base_indent + 4))
	return lines


## Emit one `key: value` line (or a nested block for Dictionary values) at
## the given indent. Arrays render in flow style; scalars through the shared
## YAML emitter so quoting rules stay identical across the two YAML dialects.
static func _emit_field(key: String, value: Variant, indent: int) -> PackedStringArray:
	var lines: PackedStringArray = []
	var prefix := _indent_str(indent)
	if value is Dictionary:
		lines.append("%s%s:" % [prefix, key])
		for sub_key in value:
			lines.append_array(_emit_field(String(sub_key), value[sub_key], indent + 2))
	elif value is Array or value is PackedStringArray:
		lines.append("%s%s: %s" % [prefix, key, McpYamlStrategy.emit_flow_array(_array_copy(value))])
	else:
		lines.append("%s%s: %s" % [prefix, key, McpYamlStrategy.emit_scalar(value)])
	return lines


# --- Line-level parsing (no YAML parser in Godot) ---------------------------

## Split file text into lines, dropping only a single trailing newline so the
## remainder round-trips byte-for-byte. `text` is never split on the empty
## string, so an empty file yields an empty array.
static func _split_lines(text: String) -> PackedStringArray:
	if text.is_empty():
		return PackedStringArray()
	var lines := text.split("\n")
	if lines.size() > 0 and String(lines[lines.size() - 1]).is_empty():
		lines.remove_at(lines.size() - 1)
	return lines


## Locate the block owned by our loader entry:
##   require_nested=true  — the `- id: <entry_id>` line inside an `insert`
##                         list (indent > 0), plus its indented children.
##   require_nested=false — a plain top-level `- id: <entry_id>` row (indent
##                         0), plus its indented children.
## Returns {"start": int, "end": int, "indent": int} (end exclusive) or {}
## when absent. The header indent is detected dynamically so a hand-written
## file using non-2-space indentation is still found; children are lines
## deeper than the header. `end` stops right AFTER the last content line:
## trailing blank and comment lines between our entry and the next sibling
## belong to the file, not to our block, so `_replace_lines` / `_remove_lines`
## (which splice [start, end)) never delete them (#867 review).
static func _find_entry_block(lines: PackedStringArray, entry_id_value: String, require_nested: bool) -> Dictionary:
	for i in range(lines.size()):
		var indent := _indent_of(lines[i])
		if require_nested and indent <= 0:
			continue
		if not require_nested and indent != 0:
			continue
		var parsed := _parse_entry_header(lines[i])
		if parsed.is_empty() or parsed.get("id") != entry_id_value:
			continue
		## A nested match must actually live inside an `- insert:` row: a
		## `- id:` list under some other top-level row (an override row's own
		## sequence, say) is not a loader entry and is not ours to touch.
		if require_nested and not _under_insert_row(lines, i):
			continue
		var j := i + 1
		var last_content := i
		while j < lines.size():
			var l := lines[j]
			if _is_blank_or_comment(l):
				j += 1
				continue
			if _indent_of(l) <= indent:
				break
			last_content = j
			j += 1
		return {"start": i, "end": last_content + 1, "indent": indent}
	return {}


## True when the nearest preceding 0-indent content line above `index` is an
## `- insert:` row header. Blank and comment lines are skipped; hitting the
## top of the file without a header means the nested line is orphaned and
## cannot be a loader entry.
static func _under_insert_row(lines: PackedStringArray, index: int) -> bool:
	for i in range(index - 1, -1, -1):
		if _is_blank_or_comment(lines[i]):
			continue
		if _indent_of(lines[i]) == 0:
			return lines[i].strip_edges().begins_with("- insert:")
	return false


## Parse a `- id: <value>` header line into {"id": String}. Returns {} for
## any other line. The value may be plain or single/double-quoted.
static func _parse_entry_header(line: String) -> Dictionary:
	var stripped := line.strip_edges()
	if not stripped.begins_with("- "):
		return {}
	var body := stripped.substr(2).strip_edges()
	if not body.begins_with("id:"):
		return {}
	var value := body.substr(3).strip_edges()
	if value.begins_with("\"") and value.ends_with("\"") and value.length() >= 2:
		var parsed: Variant = JSON.parse_string(value)
		if parsed is String:
			value = parsed
	elif value.begins_with("'") and value.ends_with("'") and value.length() >= 2:
		value = value.substr(1, value.length() - 2)
	return {"id": value}


## Extract the `config:` sub-dict from a found entry block. Fields may nest
## (env, reconnect); deeper values are parsed with the same scalar coercion
## the YAML strategy uses. Returns {} when the block has no config block.
static func _extract_config(lines: PackedStringArray, block: Dictionary) -> Dictionary:
	var start := int(block.get("start", -1))
	var end := int(block.get("end", -1))
	if start < 0:
		return {}
	var config_indent := -1
	var config_start := -1
	for i in range(start, end):
		var stripped := lines[i].strip_edges()
		if _is_blank_or_comment(lines[i]):
			continue
		if stripped == "config:":
			config_indent = _indent_of(lines[i])
			config_start = i
			break
	if config_start < 0:
		return {}
	return _parse_block_lines(lines, config_start + 1, end, config_indent)


## Parse sibling `key: value` lines at a fixed minimum indent into a
## Dictionary. Nested blocks (a key with no inline value) recurse and their
## child lines are consumed by the recursion — the parent index advances past
## them so they are never re-parsed as top-level config fields (#867 review).
## Flow arrays parse back into Arrays via JSON. Quoted and plain scalars
## strip via the YAML strategy's shared `coerce_scalar`.
static func _parse_block_lines(lines: PackedStringArray, start: int, end: int, min_indent: int) -> Dictionary:
	var out: Dictionary = {}
	var i := start
	while i < end:
		var l := lines[i]
		if _is_blank_or_comment(l):
			i += 1
			continue
		var indent := _indent_of(l)
		if indent <= min_indent:
			break
		var stripped := l.strip_edges()
		var colon := stripped.find(":")
		if colon < 0:
			i += 1
			continue
		var key := stripped.substr(0, colon).strip_edges()
		var value := stripped.substr(colon + 1).strip_edges()
		if value.is_empty():
			## Nested block: find where its children end (a line at or above
			## the block key's indent), parse only that span, and jump past it.
			var child_end := i + 1
			while child_end < end:
				if not _is_blank_or_comment(lines[child_end]) and _indent_of(lines[child_end]) <= indent:
					break
				child_end += 1
			out[key] = _parse_block_lines(lines, i + 1, child_end, indent)
			i = child_end
		else:
			## Shared with the YAML strategy so the two dialects can never
			## drift on quoting/typing rules (#867 review).
			out[key] = McpYamlStrategy.coerce_scalar(value)
			i += 1
	return out


# --- Rewrites ---------------------------------------------------------------

## Append a new `- insert:` row at the end of the file. A blank separator
## line keeps rows visually distinct; the file always ends with a newline.
static func _append_row(lines: PackedStringArray, nested_lines: PackedStringArray) -> String:
	var parts: Array[String] = []
	for l in lines:
		parts.append(l)
	## Collapse trailing blank lines so the appended row is not orphaned
	## below stray empties; one separator blank keeps rows readable.
	while parts.size() > 0 and String(parts[parts.size() - 1]).strip_edges().is_empty():
		parts.remove_at(parts.size() - 1)
	if parts.size() > 0:
		parts.append("")
	parts.append("- insert:")
	for l in nested_lines:
		parts.append(l)
	return _join_lines(parts)


## Replace the lines owned by our entry. When the found block is a plain
## top-level row (indent 0 header), the whole row — including its children —
## is replaced by the insert form. When it is a nested block inside an
## insert row, only that block's lines are replaced, leaving sibling entries
## and comments in the same row byte-for-byte intact.
static func _replace_lines(lines: PackedStringArray, block: Dictionary, nested_lines: PackedStringArray) -> String:
	var start := int(block.get("start", -1))
	var end := int(block.get("end", -1))
	var parts: Array[String] = []
	for i in range(lines.size()):
		if i == start:
			## A nested block keeps the surrounding `- insert:` row, so only
			## the nested entry lines (indent > 0) are spliced in.
			if _indent_of(lines[start]) > 0:
				for l in nested_lines:
					parts.append(l)
			else:
				parts.append("- insert:")
				for l in nested_lines:
					parts.append(l)
		if i >= start and i < end:
			continue
		parts.append(lines[i])
	return _join_lines(parts)


## Remove our entry. A nested block is spliced out; if its enclosing insert
## row is left without any nested entries (only the bare `- insert:` header,
## blanks, and comments), the row header goes too so the file stays a valid
## patch list. A plain row for our id is removed wholesale.
static func _remove_lines(lines: PackedStringArray, block: Dictionary) -> String:
	var start := int(block.get("start", -1))
	var end := int(block.get("end", -1))
	var nested := _indent_of(lines[start]) > 0
	var parts: Array[String] = []
	if nested:
		## Find the enclosing `- insert:` row header: the nearest preceding
		## 0-indent `- ` line.
		var row_start := -1
		for i in range(start - 1, -1, -1):
			if _indent_of(lines[i]) == 0 and lines[i].strip_edges().begins_with("- "):
				row_start = i
				break
		## Row end: first 0-indent non-blank/comment line after the block.
		var row_end := lines.size()
		for i in range(end, lines.size()):
			if _indent_of(lines[i]) == 0 and not _is_blank_or_comment(lines[i]):
				row_end = i
				break
		var has_other_entries := false
		for i in range(row_start + 1, row_end):
			if i >= start and i < end:
				continue
			if _is_blank_or_comment(lines[i]):
				continue
			if _indent_of(lines[i]) > 0 and lines[i].strip_edges().begins_with("- "):
				has_other_entries = true
				break
		if has_other_entries or row_start < 0:
			## Only our block goes; sibling entries and any trailing
			## comments in the same row survive.
			for i in range(lines.size()):
				if i >= start and i < end:
					continue
				parts.append(lines[i])
		else:
			## The row held only our entry: drop the `- insert:` header and
			## our block, but keep trailing blank/comment lines — a comment
			## the user wrote above the next row must survive (#867 review).
			for i in range(lines.size()):
				if i >= row_start and i < end:
					continue
				parts.append(lines[i])
			parts = _trim_trailing_blanks(parts)
	else:
		## Plain top-level row for our id: drop the whole block.
		for i in range(lines.size()):
			if i >= start and i < end:
				continue
			parts.append(lines[i])
		parts = _trim_trailing_blanks(parts)
	return _join_lines(parts)


## Remove trailing blank lines left behind by a removal.
static func _trim_trailing_blanks(parts: Array[String]) -> Array[String]:
	while parts.size() > 0 and String(parts[parts.size() - 1]).strip_edges().is_empty():
		parts.remove_at(parts.size() - 1)
	return parts


## True when the text holds no patch rows at all — blank lines and comments
## only. Such a file cannot be written back (see `remove`), because dsh's
## patch parser rejects a non-array file at boot.
static func _is_blank_or_comment_only(text: String) -> bool:
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if not stripped.is_empty() and not stripped.begins_with("#"):
			return false
	return true


## When the document's only content line is the empty flow sequence `[]`,
## return the text with that one line removed — blanks and comments stay,
## because they belong to the user. Any other document comes back unchanged;
## a `[]` mixed with real rows is left for `_is_patch_sequence` to refuse.
static func _strip_empty_flow_sequence(text: String) -> String:
	var lines := _split_lines(text)
	var bracket_line := -1
	for i in range(lines.size()):
		if _is_blank_or_comment(lines[i]):
			continue
		if bracket_line < 0 and lines[i].strip_edges() == "[]":
			bracket_line = i
			continue
		return text
	if bracket_line < 0:
		return text
	var parts: Array[String] = []
	for i in range(lines.size()):
		if i != bracket_line:
			parts.append(lines[i])
	if parts.is_empty():
		return ""
	return _join_lines(parts)


## True when the text is a valid loader patch list (or empty/comment-only /
## the empty flow sequence `[]`, which all mean "no layer"). Anything else —
## a top-level mapping or scalar — would make dsh fail boot, so Configure
## refuses to write into it instead of producing a broken file (#867 review).
## Only 0-indent content lines define the top-level structure: they must all
## be `- ` rows. Deeper lines are row children and are not inspected. `[]` is
## valid only as the COMPLETE document — appending rows after the empty flow
## sequence would produce malformed YAML, so a mixed `[]` + rows file fails
## the check too.
static func _is_patch_sequence(text: String) -> bool:
	if text.strip_edges().is_empty():
		return true
	var saw_brackets := false
	var content_count := 0
	for line in text.split("\n"):
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		content_count += 1
		if stripped == "[]":
			saw_brackets = true
			continue
		if _indent_of(line) == 0 and not stripped.begins_with("- "):
			return false
	if saw_brackets and content_count > 1:
		return false
	return true


static func _join_lines(parts: Array) -> String:
	if parts.is_empty():
		return ""
	var lines: Array[String] = []
	for p in parts:
		lines.append(String(p))
	return "\n".join(lines) + "\n"


# --- Small helpers ----------------------------------------------------------

static func _indent_str(n: int) -> String:
	var out := ""
	for i in range(n):
		out += " "
	return out


static func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == " " or line[n] == "\t"):
		n += 1
	return n


static func _is_blank_or_comment(line: String) -> bool:
	var stripped := line.strip_edges()
	return stripped.is_empty() or stripped.begins_with("#")


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


## Returns {"ok": true, "data": String} when the file is absent or readable,
## and {"ok": false, "error": String} when unreadable. Callers must NOT fall
## back to an empty string on the error path — doing so blows away the user's
## other patch rows on the next write.
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
