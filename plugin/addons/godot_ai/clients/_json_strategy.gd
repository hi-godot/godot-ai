@tool
class_name McpJsonStrategy
extends RefCounted

## Read–merge–write strategy for JSON-backed MCP clients.
## All knobs come from the McpClient descriptor as plain data — no Callables.
## See `_base.gd` for why descriptors are data-only.


static func configure(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _configure_merged(client, server_name, server_url, launch, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var seed_path := str(resolution.get("seed_path", ""))
	var read_path := seed_path if not FileAccess.file_exists(path) and not seed_path.is_empty() else path
	var read := _read_or_init(read_path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [read_path, read["error"]]}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var config: Dictionary = read["data"]
	var holder := _ensure_path(config, select_server_key_path(config, client))
	## Pass the existing entry through so `build_entry` can preserve user-mutable
	## state (auto-approval lists, `disabled` toggles) instead of resetting it
	## to descriptor defaults on every Configure click. See `entry_initial_fields`
	## docs in `_base.gd`.
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing, launch)

	# F5: refuse to re-serialize a file whose parsed integers above 2^53 would
	# lose precision. Editing by hand keeps those values intact.
	if _has_lossy_numbers(config):
		return {"status": "error", "message": "Refusing to rewrite %s: contains integers above 2^53 that Godot's JSON parser would re-emit imprecise. Edit the file by hand." % path}
	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": McpClient.configured_message(client, server_url)}

## Pi-style clients merge several global config files. Update the effective
## highest-precedence definition; fail closed when a project override exists
## because Pi's external working directory cannot be inferred safely here.
static func _configure_merged(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary,
	project_roots: PackedStringArray,
) -> Dictionary:
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var project := _load_project_definitions(client, server_name, project_roots)
	if not project.get("ok", false):
		return {"status": "error", "message": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		return {"status": "error", "message": _project_override_message(project_tiers, "update or remove", client.display_name, server_name)}
	var loaded := _load_merge_tiers(client)
	if not loaded.get("ok", false):
		return {"status": "error", "message": str(loaded.get("error", "Cannot read merged config tiers"))}
	var tiers: Array = loaded.get("tiers", [])
	if tiers.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}
	var target_index := 0
	for index in range(tiers.size()):
		var config: Dictionary = tiers[index]["data"]
		var holder := _walk_path(config, select_server_key_path(config, client))
		if holder is Dictionary and holder.has(server_name):
			target_index = index
	var tier: Dictionary = tiers[target_index]
	var config: Dictionary = tier["data"]
	var holder := _ensure_path(config, select_server_key_path(config, client))
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing, launch)
	var path := str(tier["path"])
	# F5: refuse to re-serialize a tier whose parsed integers above 2^53 would
	# lose precision. The same check guards the simple `configure` path.
	if _has_lossy_numbers(config):
		return {"status": "error", "message": "Refusing to rewrite %s: contains integers above 2^53 that Godot's JSON parser would re-emit imprecise. Edit the file by hand." % path}
	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	# Codex F1 caveat: when we wrote a global tier but couldn't find any project
	# override in the roots we probed AND the user hasn't told us where Pi (or any
	# external cwd client) actually runs from, we can't prove this write is the
	# effective config. Surface the actionable hint instead of silently passing.
	# The early `not project_tiers.is_empty()` return above already covers the
	# "project override exists in probed roots" case (we fail closed there), so
	# reaching this point with `project_tiers.is_empty()` means: no probed
	# override was found.
	var message := McpClient.configured_message(client, server_url)
	var external_cwd := str(McpClientConfigurator._editor_setting_lookup(McpClientConfigurator.SETTING_EXTERNAL_CLIENT_CWD))
	if external_cwd.is_empty() and project_tiers.is_empty():
		message += " If %s is launched from a cwd this editor cannot see, the effective entry may still be in a project-tier file — set godot_ai/external_client_cwd to that cwd to verify." % client.display_name
	return {"status": "ok", "message": message}


static func check_status(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch, project_roots).get("status", McpClient.Status.NOT_CONFIGURED)


## Detailed variant feeding the dock's error_msg plumbing (#711): a config
## file that EXISTS but can't be read or parsed is Status.ERROR carrying the
## read/parse error, not NOT_CONFIGURED — the write path refuses to touch
## such a file (see `_read_or_init`), so the status dot must say "broken
## file", not "click Configure".
static func check_status_details(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _check_status_merged(client, server_name, server_url, launch, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var read := _read_or_init(path, _status_allows_comments(client))
	if not read["ok"]:
		return {"status": McpClient.Status.ERROR, "error_msg": String(read["error"])}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, select_server_key_path(config, client))
	if not (holder is Dictionary) or not holder.has(server_name):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	return _entry_status_details(client, holder[server_name], server_url, launch)


## Verify the effective last definition after applying the client's merge order.
static func _check_status_merged(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary,
	project_roots: PackedStringArray,
) -> Dictionary:
	var allow_comments := _status_allows_comments(client)
	var loaded := _load_merge_tiers(client, allow_comments)
	if not loaded.get("ok", false):
		return {"status": McpClient.Status.ERROR, "error_msg": str(loaded.get("error", "Cannot read merged config tiers"))}
	var effective: Variant = null
	for tier in loaded.get("tiers", []):
		var config: Dictionary = tier["data"]
		var holder := _walk_path(config, select_server_key_path(config, client))
		if holder is Dictionary and holder.has(server_name):
			effective = holder[server_name]
	var project := _load_project_definitions(client, server_name, project_roots, allow_comments)
	if not project.get("ok", false):
		return {"status": McpClient.Status.ERROR, "error_msg": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		# Last-definition-wins mirrors the global-tier fold above and how
		# pi-codemode-mcp merges project tiers on disk. Earlier tiers are dead
		# once a later one defines the same server, so an early-stale entry
		# doesn't make Pi's effective config drift (codex-review finding F2).
		# Pass `[latest]` to `_project_override_message` so the error names only
		# the file the user actually has to edit.
		var latest: Dictionary = project_tiers[project_tiers.size() - 1]
		var details := _entry_status_details(client, latest["entry"], server_url, launch)
		if details.get("status") != McpClient.Status.CONFIGURED:
			return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": _project_override_message([latest], "update or remove", client.display_name, server_name)}
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	if effective == null:
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	return _entry_status_details(client, effective, server_url, launch)


static func _entry_status_details(
	client: McpClient,
	entry: Variant,
	server_url: String,
	launch: Dictionary,
) -> Dictionary:
	if not (entry is Dictionary):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": launch_error}
	if verify_entry(client, entry, server_url, launch):
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	return {
		"status": McpClient.Status.CONFIGURED_MISMATCH,
		"error_msg": "",
		"owned": McpClient.launch_mentions_godot_ai(McpClient.entry_launch_text(entry)),
	}


static func remove(
	client: McpClient,
	server_name: String,
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	if _uses_merge_tiers(client):
		return _remove_merged(client, server_name, project_roots)
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	# Token-preserving removal (F5): pull the original file text via
	# `_read_file_text` and edit only the entry's bytes — keeps every other
	# byte, including integers above 2^53, byte-for-byte identical to what
	# the user wrote. The parsed-dict round-trip path is gone.
	var file_read := _read_file_text(path)
	if not file_read.get("ok", false):
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, file_read.get("error", "")]}
	var config: Dictionary = file_read.get("data", {})
	var key_path := select_server_key_path(config, client)
	var original_text: String = str(file_read.get("original_text", ""))
	var updated: String = _text_remove_server_entry(original_text, key_path, server_name)
	if updated == original_text:
		return {"status": "ok", "message": "Not configured"}
	if not McpAtomicWrite.write(path, updated):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


static func _remove_merged(
	client: McpClient, server_name: String, project_roots: PackedStringArray
) -> Dictionary:
	var project := _load_project_definitions(client, server_name, project_roots)
	if not project.get("ok", false):
		return {"status": "error", "message": str(project.get("error", "Cannot inspect project config tiers"))}
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		return {"status": "error", "message": _project_override_message(project_tiers, "remove", client.display_name, server_name)}
	var loaded := _load_merge_tiers(client)
	if not loaded.get("ok", false):
		return {"status": "error", "message": str(loaded.get("error", "Cannot read merged config tiers"))}
	var writes: Array[Dictionary] = []
	for tier in loaded.get("tiers", []):
		if not tier.get("exists", false):
			continue
		var key_path := select_server_key_path(tier["data"], client)
		var original: String = str(tier.get("original_text", ""))
		# Token-preserving removal (F5): edit `original` textually instead of
		# re-serialising the parsed config. This preserves every byte outside
		# the entry block, so unrelated integers (including those above the
		# IEEE-754 exact-int range that `_narrow_integral_numbers` cannot
		# round-trip) keep their original literals.
		var updated: String = _text_remove_server_entry(original, key_path, server_name)
		if updated == original:
			continue  # entry not in this tier; skip
		writes.append({
			"path": tier["path"],
			"text": updated,
			"original_text": original,
		})
	if writes.is_empty():
		return {"status": "ok", "message": "Not configured"}
	var written := _write_transaction(writes)
	if not written.get("ok", false):
		return {"status": "error", "message": written.get("error", "Cannot remove merged configuration")}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Synthesize the entry dict the strategy writes under
## `server_key_path[server_name]`. Both URL and command entries deep-copy the
## existing dict before overwriting strategy-owned fields, preserving unknown
## client additions as well as descriptor-documented user fields.
static func build_entry(
	client: McpClient,
	server_url: String,
	existing: Variant = null,
	launch: Dictionary = {},
) -> Dictionary:
	if _is_supported_command_shape(client.command_shape):
		var command_entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
		if client.command_shape == McpClient.CommandShape.COMMAND_ARRAY:
			## OpenCode-style: the entry's `command` field IS the argv array.
			## A stale sibling `args` from a FLAT-style hand edit would be
			## ambiguous next to it, so it is strategy-owned and removed.
			command_entry["command"] = _launch_argv(launch)
			command_entry.erase("args")
		else:
			command_entry["command"] = str(launch.get("command", ""))
			command_entry["args"] = _array_copy(launch.get("args", []))
		if not client.command_transport_key.is_empty():
			command_entry[client.command_transport_key] = client.command_transport_value
		for key in client.command_initial_fields:
			if not command_entry.has(key):
				command_entry[key] = client.command_initial_fields[key]
		for key in client.command_legacy_keys:
			command_entry.erase(String(key))
		_remove_legacy_env_keys(command_entry, client.command_env_legacy_keys)
		return command_entry
	if client.command_shape != McpClient.CommandShape.NONE:
		return {}
	return build_url_entry(client, server_url, existing)


static func build_url_entry(client: McpClient, server_url: String, existing: Variant = null) -> Dictionary:
	var entry: Dictionary = (existing as Dictionary).duplicate(true) if existing is Dictionary else {}
	entry[client.entry_url_field] = server_url
	for k in client.entry_extra_fields:
		entry[k] = client.entry_extra_fields[k]
	for k in client.entry_initial_fields:
		if not entry.has(k):
			entry[k] = client.entry_initial_fields[k]
	return entry


## Default verifier for a stored entry. Command entries must match every
## launch-affecting value exactly; legacy URL or env keys are migration drift.
## For URL clients, assert `entry[entry_url_field] == url` AND every
## key in `entry_extra_fields` matches verbatim. Type-pinning for Cline /
## Roo / Kilo (`type: "streamable-http"` etc.) falls out of this — pre-fix
## entries that lack the type field fail verification and surface as drift.
static func verify_entry(
	client: McpClient,
	entry: Dictionary,
	server_url: String,
	launch: Dictionary = {},
) -> bool:
	if client.command_shape != McpClient.CommandShape.NONE:
		if not _is_supported_command_shape(client.command_shape) or not bool(launch.get("ok", false)):
			return false
		for key in client.command_legacy_keys:
			if entry.has(String(key)):
				return false
		var env = entry.get("env", null)
		if env is Dictionary:
			for key in client.command_env_legacy_keys:
				if env.has(String(key)):
					return false
		if client.command_shape == McpClient.CommandShape.COMMAND_ARRAY:
			if not _arrays_equal(entry.get("command", null), _launch_argv(launch)):
				return false
			if entry.has("args"):
				return false
		else:
			if entry.get("command") != launch.get("command"):
				return false
			if not _arrays_equal(entry.get("args", null), launch.get("args", null)):
				return false
		if not client.command_transport_key.is_empty():
			if not entry.has(client.command_transport_key):
				return false
			if entry.get(client.command_transport_key) != client.command_transport_value:
				return false
		return true
	if entry.get(client.entry_url_field, "") != server_url:
		return false
	for k in client.entry_extra_fields:
		if entry.get(k) != client.entry_extra_fields[k]:
			return false
	return true


static func command_launch_error(client: McpClient, launch: Dictionary) -> String:
	if client.command_shape == McpClient.CommandShape.NONE:
		return ""
	if not _is_supported_command_shape(client.command_shape):
		return "%s uses a command shape not supported by JSON yet" % client.display_name
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


static func _is_supported_command_shape(shape: McpClient.CommandShape) -> bool:
	return shape == McpClient.CommandShape.FLAT or shape == McpClient.CommandShape.COMMAND_ARRAY


## The full launch argv as one array: launcher path followed by every arg.
static func _launch_argv(launch: Dictionary) -> Array:
	var argv: Array = [str(launch.get("command", ""))]
	argv.append_array(_array_copy(launch.get("args", [])))
	return argv


static func _remove_legacy_env_keys(entry: Dictionary, legacy_keys: PackedStringArray) -> void:
	if legacy_keys.is_empty():
		return
	var existing_env = entry.get("env", null)
	if not (existing_env is Dictionary):
		return
	var env: Dictionary = (existing_env as Dictionary).duplicate(true)
	for key in legacy_keys:
		env.erase(String(key))
	if env.is_empty():
		entry.erase("env")
	else:
		entry["env"] = env


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


## Read a config file once and parse the captured text. Returns
## {"exists": bool, "ok": bool, "data": Dictionary, "original_text": String}
## when the file is absent or parses cleanly, and
## {"exists": true, "ok": false, "error": String, "original_text": String}
## when the file exists with non-empty content we cannot safely round-trip.
## Callers must NOT treat the error path as an empty config — doing so blows
## away the user's other MCP entries on the next write. The `original_text`
## is the exact captured source so transactional rollback can restore
## byte-for-byte; the UTF-8 BOM is stripped only from the parsing copy.
## `allow_comments` also strips JSONC comments from the parsing copy; only
## read-only callers pass it (see `_status_allows_comments`).
static func _read_file_text(path: String, allow_comments: bool = false) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "ok": true, "data": {}, "original_text": ""}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		return {"exists": true, "ok": false, "error": "could not open for reading (error %d)" % open_err, "original_text": ""}
	# Read bytes, not `get_as_text()`. Godot's UTF-8 decoder (both `get_as_text`
	# and `get_string_from_utf8`) silently consumes a leading EF BB BF, so a
	# text-only read dropped the BOM from `original_text` and the next Remove
	# wrote it back out of the user's file — a byte mutation outside the entry
	# we were asked to touch. Detect the marker on the raw buffer and restore
	# U+FEFF when the decoder ate it.
	var buf := file.get_buffer(file.get_length())
	file.close()
	var had_bom := buf.size() >= 3 and buf[0] == 0xEF and buf[1] == 0xBB and buf[2] == 0xBF
	var content := buf.get_string_from_utf8()
	if had_bom and not content.begins_with("﻿"):
		content = "﻿" + content
	# Everything downstream of the BOM parses and measures the body: JSON.parse
	# rejects a leading U+FEFF outright, and a BOM-only file is empty, not
	# broken. `original_text` keeps the marker so writes round-trip it.
	var body := content.substr(1) if content.begins_with("﻿") else content
	if body.strip_edges().is_empty():
		return {"exists": true, "ok": true, "data": {}, "original_text": content}
	var parse_copy := body
	if allow_comments:
		# Parse copy only — `original_text` stays byte-for-byte, and an
		# unterminated block comment fails closed rather than letting the
		# leftover source parse as valid JSON.
		var stripped := _strip_jsonc(parse_copy)
		if not stripped.get("ok", false):
			var strip_msg := str(stripped.get("error", "invalid JSONC"))
			push_warning("MCP | %s in %s" % [strip_msg, path])
			return {"exists": true, "ok": false, "error": strip_msg, "original_text": content}
		parse_copy = str(stripped.get("text", ""))
	var json := JSON.new()
	if json.parse(parse_copy) != OK:
		var msg := "JSON parse error on line %d: %s" % [json.get_error_line(), json.get_error_message()]
		push_warning("MCP | %s in %s" % [msg, path])
		return {"exists": true, "ok": false, "error": msg, "original_text": content}
	if not (json.data is Dictionary):
		return {"exists": true, "ok": false, "error": "top-level value is %s, expected object" % type_string(typeof(json.data)), "original_text": content}
	return {"exists": true, "ok": true, "data": json.data, "original_text": content}


## Read-only by construction: requiring both flags means no Configure/Remove
## can parse a file it would then re-serialize without the discarded comments.
## Re-enabling automatic edits restores the parse error instead of a lossy write.
static func _status_allows_comments(client: McpClient) -> bool:
	return client.config_allows_comments and not client.automatic_config_edits


## Strip `//` and `/* */` comments, leaving sequences inside JSON strings
## intact. Parse copies only.
## Returns `{"ok": true, "text": String}` or `{"ok": false, "error": String}`.
static func _strip_jsonc(text: String) -> Dictionary:
	var parts := PackedStringArray()
	var i := 0
	var n := text.length()
	var in_string := false
	var escape := false
	var run_start := 0
	while i < n:
		var c := text[i]
		if in_string:
			if escape:
				escape = false
			elif c == "\\":
				escape = true
			elif c == '"':
				in_string = false
			i += 1
			continue
		if c == '"':
			in_string = true
			i += 1
			continue
		var skipped := _skip_jsonc_comment_at(text, i)
		if skipped < 0:
			return {"ok": false, "error": "unterminated block comment"}
		if skipped != i:
			if i > run_start:
				parts.append(text.substr(run_start, i - run_start))
			# Re-emit newlines so JSON.parse error lines still match the source.
			var emitted_nl := false
			for j in range(i, skipped):
				if text[j] == "\n":
					parts.append("\n")
					emitted_nl = true
			# A comment must not glue its neighbours (`tru/* x */e` is not
			# `true`). A newline already splits them; otherwise use a space.
			if not emitted_nl:
				parts.append(" ")
			i = skipped
			run_start = i
			continue
		i += 1
	if in_string:
		return {"ok": false, "error": "unterminated string"}
	if n > run_start:
		parts.append(text.substr(run_start, n - run_start))
	return {"ok": true, "text": "".join(parts)}


## Skip a JSONC comment starting at `i`. Returns `i` unchanged when `i` is not
## a comment opener, the index after a consumed comment, or -1 when a block
## comment runs to EOF without `*/`.
static func _skip_jsonc_comment_at(text: String, i: int) -> int:
	var n := text.length()
	if i + 1 >= n or text[i] != "/":
		return i
	if text[i + 1] == "/":
		i += 2
		# `get_string_from_utf8()` keeps CR, so a CR-only file never presents a `\n` and
		# a `\n`-only terminator would swallow the rest of the file.
		while i < n and text[i] != "\n" and text[i] != "\r":
			i += 1
		return i
	if text[i + 1] == "*":
		i += 2
		while i + 1 < n:
			if text[i] == "*" and text[i + 1] == "/":
				return i + 2
			i += 1
		return -1
	return i


## Returns {"ok": true, "data": Dictionary} when the file is absent or parses
## cleanly, and {"ok": false, "error": String} when the file exists with
## non-empty content we cannot safely round-trip. Callers must NOT fall back
## to an empty dict on the error path — doing so blows away the user's other
## MCP entries on the next write.
static func _read_or_init(path: String, allow_comments: bool = false) -> Dictionary:
	var read := _read_file_text(path, allow_comments)
	var result: Dictionary = {"ok": read.get("ok", false), "data": read.get("data", {})}
	if not result.get("ok", false):
		result["error"] = read.get("error", "")
	return result


## Walk a key path, creating intermediate Dicts as needed. Returns the leaf Dict.
static func _ensure_path(root: Dictionary, key_path: PackedStringArray) -> Dictionary:
	var cur := root
	for key in key_path:
		var next = cur.get(key)
		if not (next is Dictionary):
			next = {}
			cur[key] = next
		cur = next
	return cur


## Walk a key path, returning the leaf Dict if all hops exist; else null.
static func _walk_path(root: Dictionary, key_path: PackedStringArray) -> Variant:
	var cur: Variant = root
	for key in key_path:
		if not (cur is Dictionary) or not cur.has(key):
			return null
		cur = cur[key]
	return cur


## Match clients that accept multiple server-map keys without creating a
## higher-precedence canonical map that shadows an existing legacy map. A
## non-null scalar still wins, matching nullish-coalescing parsers; Configure's
## `_ensure_path` then repairs it using the strategy's existing behavior.
static func select_server_key_path(root: Dictionary, client: McpClient) -> PackedStringArray:
	var candidates: Array[PackedStringArray] = [client.server_key_path]
	# Dynamic access keeps mixed-snapshot self-updates parse-safe when a new
	# strategy is briefly loaded with an older McpClient base (#398/#736).
	var aliases = client.get("server_key_path_aliases")
	if aliases is Array:
		for alias in aliases:
			if alias is PackedStringArray:
				candidates.append(alias)
	for key_path in candidates:
		if _walk_path(root, key_path) != null:
			return key_path
	return client.server_key_path


static func _uses_merge_tiers(client: McpClient) -> bool:
	var templates = client.get("config_merge_path_templates")
	return templates is Dictionary and not templates.is_empty()


## Resolve the global config tiers in the client's documented merge order.
static func _merge_paths(client: McpClient) -> PackedStringArray:
	var result := PackedStringArray()
	var templates = client.get("config_merge_path_templates")
	if templates is Dictionary:
		var platform_key := McpPathTemplate.platform_key(templates)
		if not platform_key.is_empty():
			var raw_paths: Variant = templates.get(platform_key, [])
			if raw_paths is Array or raw_paths is PackedStringArray:
				for template in raw_paths:
					var path := McpPathTemplate.expand(str(template)).simplify_path()
					if not path.is_empty() and not result.has(path):
						result.append(path)
	return result


## Pi's project tiers are relative to Pi's process cwd, not Godot's. Inspect
## plausible roots only to detect overrides; callers fail closed rather than
## mutating both guesses.
static func _project_candidate_paths(
	client: McpClient, roots: PackedStringArray
) -> PackedStringArray:
	var result := PackedStringArray()
	var project_paths = client.get("config_merge_project_paths")
	if not (project_paths is PackedStringArray):
		return result
	for project_path in project_paths:
		var absolute_path := String(project_path).simplify_path()
		if absolute_path.is_absolute_path() and FileAccess.file_exists(absolute_path) and not result.has(absolute_path):
			result.append(absolute_path)
	for root in roots:
		if String(root).is_empty():
			continue
		for relative_path in project_paths:
			if String(relative_path).is_absolute_path():
				continue
			var path := String(root).path_join(String(relative_path)).simplify_path()
			if FileAccess.file_exists(path) and not result.has(path):
				result.append(path)
	return result


static func _load_project_definitions(
	client: McpClient,
	server_name: String,
	project_roots: PackedStringArray,
	allow_comments: bool = false,
) -> Dictionary:
	var tiers: Array[Dictionary] = []
	for path in _project_candidate_paths(client, project_roots):
		var read := _read_or_init(path, allow_comments)
		if not read.get("ok", false):
			return {"ok": false, "error": "Cannot inspect project config %s: %s" % [path, read.get("error", "invalid JSON")]}
		var config: Dictionary = read["data"]
		var key_path := select_server_key_path(config, client)
		var holder := _walk_path(config, key_path)
		if holder is Dictionary and holder.has(server_name):
			tiers.append({
				"path": path,
				"data": config,
				"key_path": key_path,
				"entry": holder[server_name],
			})
	return {"ok": true, "tiers": tiers}


static func _project_override_message(
	tiers: Array, action: String, client_name: String, server_name: String
) -> String:
	var paths := PackedStringArray()
	for tier in tiers:
		paths.append(str(tier["path"]))
	return "%s project config overrides %s at %s. %s resolves project files from its own working directory, so the dock cannot safely choose one; %s the entry manually." % [client_name, server_name, ", ".join(paths), client_name, action]


static func _load_merge_tiers(client: McpClient, allow_comments: bool = false) -> Dictionary:
	var tiers: Array[Dictionary] = []
	for path in _merge_paths(client):
		## These templates never pass through `resolved_config_path_details`,
		## so they need its fail-closed gate here: `McpPathTemplate.expand`
		## leaves a token it cannot resolve in place, and the relative survivor
		## would be read — and on Configure, written — against the editor's own
		## working directory. Fail the whole fold rather than dropping the tier:
		## a dropped tier reads as "the user has no config there", which is
		## exactly the wrong thing to conclude when we could not look.
		if not path.is_absolute_path():
			return {
				"ok": false,
				"error": McpClient.unresolved_config_path_error(client.display_name, path),
			}
		var read := _read_file_text(path, allow_comments)
		if not read.get("ok", false):
			return {
				"ok": false,
				"error": "Refusing to rewrite %s: %s. Fix or move the file, then re-run Configure." % [path, read.get("error", "invalid JSON")],
			}
		tiers.append({
			"path": path,
			"exists": read.get("exists", false),
			"original_text": read.get("original_text", ""),
			"data": read.get("data", {}),
		})
	return {"ok": true, "tiers": tiers}


## Commit a multi-file removal with best-effort rollback. Each individual write
## is atomic; this layer restores earlier tiers if a later commit fails.
static func _write_transaction(writes: Array[Dictionary]) -> Dictionary:
	var completed: Array[Dictionary] = []
	for write in writes:
		var path := str(write["path"])
		if McpAtomicWrite.write(path, str(write["text"])):
			completed.append(write)
			continue
		var rollback_failed := PackedStringArray()
		completed.reverse()
		for previous in completed:
			if not McpAtomicWrite.write(str(previous["path"]), str(previous["original_text"])):
				rollback_failed.append(str(previous["path"]))
		var suffix := ""
		if not rollback_failed.is_empty():
			suffix = " Rollback also failed for: %s" % ", ".join(rollback_failed)
		return {"ok": false, "error": "Cannot write to %s; earlier tier changes were rolled back.%s" % [path, suffix]}
	return {"ok": true}
## Path that `_check_status_merged`'s last-wins logic would consider
## authoritative for the server entry, or "" when no entry is found in
## any tier. Mirrors the same project-tier / global-tier resolution the
## status check uses so callers (notably the dock Open/Reveal buttons)
## land on the file that actually drives Pi's effective config.
##
## Resolution order (codex round 3, F-3-4):
##   1. Latest project tier containing the entry — F2 last-wins means the
##      latest of `.pi/mcp.json` and `.mcp.json` wins (matches `_check_status_merged`).
##   2. Latest global tier containing the entry — already iterated in
##      merge order, last-iterated-wins (same loop pattern as
##      `manual_target_details` lines 660-665).
##   3. "" when no tier has the entry — caller decides what fallback
##      (`path_template`) to use.
##
## Returns "" (not `path_template`) on the "nothing anywhere" branch so
## the dock can distinguish "no entry yet" from "entry is at the
## template path" if it wants to.
static func authoritative_tier_path(
	client: McpClient,
	server_name: String,
	project_roots: PackedStringArray,
) -> String:
	if not _uses_merge_tiers(client):
		return ""
	var allow_comments := _status_allows_comments(client)
	var project := _load_project_definitions(client, server_name, project_roots, allow_comments)
	if not bool(project.get("ok", false)):
		return ""
	var project_tiers: Array = project.get("tiers", [])
	if not project_tiers.is_empty():
		# F2 last-wins: latest project tier is authoritative. When there are
		# multiple project tiers, the user-visible status is driven by the
		# latest, so the Open/Reveal buttons should send them there too.
		var latest: Dictionary = project_tiers[project_tiers.size() - 1]
		return str(latest.get("path", ""))
	var loaded := _load_merge_tiers(client, allow_comments)
	if not bool(loaded.get("ok", false)):
		return ""
	var tiers: Array = loaded.get("tiers", [])
	# Iterate in priority order, overwrite `selected_path` each time we
	# find a tier containing the entry. With Pi's merge path order
	# [mcp.json, .mcp.json] this leaves the higher-precedence `.mcp.json`.
	var selected_path: String = ""
	for tier in tiers:
		var data: Dictionary = tier.get("data", {})
		var holder: Variant = _walk_path(data, select_server_key_path(data, client))
		if holder is Dictionary and holder.has(server_name):
			selected_path = str(tier.get("path", ""))
	return selected_path


## Pick the file and top-level map shown by the manual JSON instructions using
## the same merge and alias precedence as automatic Configure.
static func manual_target_details(
	client: McpClient,
	server_name: String,
	fallback_path: String,
	project_roots: PackedStringArray = PackedStringArray(),
) -> Dictionary:
	# A read: the instructions a JSONC client is sent to must not carry
	# "Target inspection failed" for the file its own client ships.
	var allow_comments := _status_allows_comments(client)
	if _uses_merge_tiers(client):
		var project := _load_project_definitions(client, server_name, project_roots, allow_comments)
		if not project.get("ok", false):
			return {"ok": false, "error": project.get("error", "Cannot inspect project config tiers")}
		var project_tiers: Array = project.get("tiers", [])
		if project_tiers.size() > 1:
			return {"ok": false, "error": _project_override_message(project_tiers, "update or remove", client.display_name, server_name)}
		if project_tiers.size() == 1:
			var selected_project: Dictionary = project_tiers[0]
			return {
				"ok": true,
				"path": selected_project["path"],
				"key_path": selected_project["key_path"],
			}
		var loaded := _load_merge_tiers(client, allow_comments)
		if not loaded.get("ok", false):
			return {"ok": false, "error": loaded.get("error", "Cannot read merged config tiers")}
		var tiers: Array = loaded.get("tiers", [])
		var selected: Variant = tiers[0] if not tiers.is_empty() else null
		for tier in tiers:
			var config: Dictionary = tier["data"]
			var holder := _walk_path(config, select_server_key_path(config, client))
			if holder is Dictionary and holder.has(server_name):
				selected = tier
		if selected != null:
			var config: Dictionary = selected["data"]
			return {
				"ok": true,
				"path": selected["path"],
				"key_path": select_server_key_path(config, client),
			}
	var read := _read_or_init(fallback_path, allow_comments)
	if not read.get("ok", false):
		return {"ok": false, "error": "Cannot inspect %s: %s" % [fallback_path, read.get("error", "invalid JSON")]}
	return {
		"ok": true,
		"path": fallback_path,
		"key_path": select_server_key_path(read["data"], client),
	}


## Godot's JSON.parse turns every JSON number into a float, so a later
## JSON.stringify re-emits the user's integer fields as "8080.0" — which strict
## consumers (Go's encoding/json into an int field, etc.) reject, and which
## needlessly rewrites every number across the user's *other* entries. Re-narrow
## exactly-representable integral floats back to int so they serialize without
## the ".0". Walks dicts/arrays in place and returns the (same) value.
##
## Integers above 2^53 already lost precision when Godot parsed them to double,
## so they're left as the float Godot produced rather than faking exactness —
## byte-perfect preservation would require not parsing the file at all, and such
## magnitudes don't occur in MCP client configs.
static func _narrow_integral_numbers(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if is_finite(value) and value == floor(value) and absf(value) <= 9007199254740992.0:
				return int(value)
		TYPE_DICTIONARY:
			for k in value:
				value[k] = _narrow_integral_numbers(value[k])
		TYPE_ARRAY:
			for i in value.size():
				value[i] = _narrow_integral_numbers(value[i])
	return value


## True when `value` contains any float outside the IEEE-754 exact-int range
## (`abs(f) > 2^53`) that would lose precision when JSON.stringify re-emits it.
## The configure path refuses such files instead of silently mutating unrelated
## integers; the remove path never needs this check because it does
## token-preserving surgery (F5).
static func _has_lossy_numbers(value: Variant) -> bool:
	match typeof(value):
		TYPE_FLOAT:
			# `>=` not `>`: `2^53 + 1` rounds down to `2^53.0` when Godot parses
			# the integer to double, so even a "clean" `2^53.0` after parse may
			# have lost a least-significant bit we cannot recover. Refusing at
			# the boundary is conservative but correct — and 2^53+ magnitudes
			# don't appear in real MCP client configs anyway.
			if is_finite(value) and absf(value) >= 9007199254740992.0:
				return true
		TYPE_DICTIONARY:
			for k in value:
				if _has_lossy_numbers(value[k]):
					return true
		TYPE_ARRAY:
			for i in value.size():
				if _has_lossy_numbers(value[i]):
					return true
	return false


## Token-preserving entry removal. Walks the JSON text with a brace-balanced
## scanner to locate the entry at `key_path[0]/.../[server_name]` and returns
## `text` with that entry's bytes deleted (along with the surrounding
## whitespace + trailing comma). Everything else — including integers above
## the IEEE-754 exact-int range that `_narrow_integral_numbers` would silently
## mutate — is preserved byte-for-byte. Returns `text` unchanged when the
## entry isn't found in `text` (callers treat this as a no-op write).
static func _text_remove_server_entry(text: String, key_path: PackedStringArray, server_name: String) -> String:
	# Descend through `key_path`. Each step finds `"<key>":` directly inside the
	# current container and moves the cursor past the value's opening `{` or `[`.
	# After the loop, `cursor` is positioned just past the opening bracket of the
	# container that holds our entry, and `container_depth` tracks how deeply
	# nested that container is from the root (0 = root object/array).
	var cursor := 0
	# Skip past the root's opening `{` or `[` (and any leading whitespace or
	# UTF-8 BOM) so `_find_key_at_container_depth` starts scanning from
	# inside the root container with `inner_depth == 0`. Without this step,
	# the first character encountered is the root's `{`, which bumps
	# `inner_depth` to 1 and makes the top-level key check fail. The BOM
	# skip mirrors `_read_file_text`'s parse_copy BOM-strip above so the
	# scanner sees the same view of the file the parser does; the BOM
	# itself stays in `text` so the byte-survival F5 contract still holds
	# (codex round 3, F-3-6 — without it, files saved with a Windows BOM
	# left the entry in place after Remove).
	# The BOM can only ever be byte 0, so it is skipped BEFORE the whitespace
	# walk: a file saved as BOM + newline + `{` (common from Windows editors)
	# otherwise leaves the cursor on the newline, the root `{` is never
	# consumed, and the entry silently survives Remove.
	if cursor < text.length() and text[cursor] == "﻿":
		cursor += 1
	while cursor < text.length() and _is_json_ws(text[cursor]):
		cursor += 1
	if cursor < text.length() and (text[cursor] == "{" or text[cursor] == "["):
		cursor += 1
	var container_depth := 0
	for key in key_path:
		var key_bytes := JSON.stringify(String(key))
		var match := _find_key_at_container_depth(text, cursor, key_bytes)
		if match.is_empty():
			return text
		var open_char := text[match["value_start"]]
		if open_char != "{" and open_char != "[":
			return text  # leaf isn't an object/array — path can't reach our entry
		container_depth += 1
		cursor = match["value_start"] + 1
	# Now find `"<server_name>":` at the top level of the container we descended
	# into (the helper gates on `inner_depth == 0`).
	var entry_bytes := JSON.stringify(server_name)
	var entry_match := _find_key_at_container_depth(text, cursor, entry_bytes)
	if entry_match.is_empty():
		return text
	var key_start: int = entry_match["key_start"]
	var value_end: int = entry_match["value_end"]
	# Trim the surrounding comma in a mutually exclusive way: the trailing comma
	# (after the entry's value) carries the burden when the entry is NOT the last
	# in its container, and the leading comma (before the entry's key) carries it
	# only when the entry IS the last. Trimming BOTH unconditionally corrupts a
	# middle-position entry into `"x"}"y"` with no separator — codex-review
	# finding F5 (regression after the initial round).
	var remove_end := value_end
	# Skip JSON whitespace before checking for the trailing comma — valid
	# (if unusual) formats like `"godot-ai":{}   ,"other":{}` put whitespace
	# between the value and its separator. codex round 4 finding.
	var trailing_scan := remove_end
	while trailing_scan < text.length() and _is_json_ws(text[trailing_scan]):
		trailing_scan += 1
	var had_trailing_comma := trailing_scan < text.length() and text[trailing_scan] == ","
	if had_trailing_comma:
		# Jump past the comma (and any whitespace before it we just skipped).
		remove_end = trailing_scan + 1
	while remove_end < text.length() and _is_json_ws(text[remove_end]):
		remove_end += 1
	var remove_start := key_start
	if not had_trailing_comma:
		while remove_start > 0 and _is_json_ws(text[remove_start - 1]):
			remove_start -= 1
		if remove_start > 0 and text[remove_start - 1] == ",":
			remove_start -= 1
			while remove_start > 0 and _is_json_ws(text[remove_start - 1]):
				remove_start -= 1
	return text.substr(0, remove_start) + text.substr(remove_end)


## Look for `key_bytes` (a JSON-encoded string literal including the surrounding
## quotes) at the TOP LEVEL of the container we're inside, scanning `text` from
## `start` onwards. The caller is expected to advance `start` just past the
## container's opening `{` or `[`, so we begin with `inner_depth == 0` and a
## key matches when we hit it while `inner_depth` is still 0. The scan exits
## immediately if `inner_depth` drops below 0 (the target container closed)
## to prevent same-named keys in later sibling containers from being picked
## up. Returns `{key_start, value_start, value_end}` on success or `{}` if
## the key isn't present in that container.
static func _find_key_at_container_depth(text: String, start: int, key_bytes: String) -> Dictionary:
	var i := start
	var in_string := false
	var escape := false
	var inner_depth := 0  # depth *inside* the current container
	while i < text.length():
		var c := text[i]
		if in_string:
			if escape:
				escape = false
			elif c == "\\":
				escape = true
			elif c == '"':
				in_string = false
			i += 1
			continue
		if c == '"':
			if text.substr(i, key_bytes.length()) == key_bytes:
				var after_key := i + key_bytes.length()
				while after_key < text.length() and _is_json_ws(text[after_key]):
					after_key += 1
				if after_key < text.length() and text[after_key] == ":":
					var value_start := after_key + 1
					while value_start < text.length() and _is_json_ws(text[value_start]):
						value_start += 1
					var value_end := _json_value_span_end(text, value_start)
					if value_end >= 0 and inner_depth == 0:
						return {"key_start": i, "value_start": value_start, "value_end": value_end}
			in_string = true
			i += 1
			continue
		if c == "{" or c == "[":
			inner_depth += 1
		elif c == "}" or c == "]":
			inner_depth -= 1
			# Bail out the moment we leave the container we're scanning. Without
			# this guard, a later sibling container at the same level (e.g. a
			# top-level `extensions` block after `mcpServers` closes) re-balances
			# `inner_depth` back to 0 and a same-named key in that sibling would
			# match — silently deleting data we never intended to touch
			# (codex-review finding F5, regression after the initial round).
			if inner_depth < 0:
				return {}
		i += 1
	return {}


## Given `value_start` pointing at the first char of a JSON value, return the
## position AFTER the value's last char. Handles objects, arrays, strings,
## and bare literals (numbers, true/false/null). Returns -1 if the value is
## unterminated.
static func _json_value_span_end(text: String, value_start: int) -> int:
	if value_start >= text.length():
		return -1
	var c := text[value_start]
	if c == "{" or c == "[":
		var open_char := c
		var close_char := "}" if c == "{" else "]"
		var depth := 1
		var i := value_start + 1
		var in_string := false
		var escape := false
		while i < text.length() and depth > 0:
			var ch := text[i]
			if in_string:
				if escape:
					escape = false
				elif ch == "\\":
					escape = true
				elif ch == '"':
					in_string = false
				i += 1
				continue
			if ch == '"':
				in_string = true
			elif ch == open_char:
				depth += 1
			elif ch == close_char:
				depth -= 1
			i += 1
		return i if depth == 0 else -1
	if c == '"':
		var i := value_start + 1
		var escape := false
		while i < text.length():
			var ch := text[i]
			if escape:
				escape = false
			elif ch == "\\":
				escape = true
			elif ch == '"':
				return i + 1
			i += 1
		return -1
	# Bare literal: number / true / false / null. Walk until a JSON-significant
	# delimiter (`,`, `}`, `]`, or whitespace).
	var i := value_start
	while i < text.length():
		var ch := text[i]
		if ch == "," or ch == "}" or ch == "]" or _is_json_ws(ch):
			break
		i += 1
	return i


static func _is_json_ws(c: String) -> bool:
	return c == " " or c == "\t" or c == "\n" or c == "\r"
