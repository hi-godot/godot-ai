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
) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var config: Dictionary = read["data"]
	var holder := _ensure_path(config, client.server_key_path)
	## Pass the existing entry through so `build_entry` can preserve user-mutable
	## state (auto-approval lists, `disabled` toggles) instead of resetting it
	## to descriptor defaults on every Configure click. See `entry_initial_fields`
	## docs in `_base.gd`.
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing, launch)

	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch).get("status", McpClient.Status.NOT_CONFIGURED)


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
) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": path_error}
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": McpClient.Status.ERROR, "error_msg": String(read["error"])}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if not (holder is Dictionary) or not holder.has(server_name):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var entry = holder[server_name]
	if not (entry is Dictionary):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": McpClient.Status.ERROR, "error_msg": launch_error}
	## An entry under `server_name` exists — if the URL doesn't match,
	## that's drift (the user changed the port and the client config is stale),
	## not "never configured". The dock surfaces that as an amber banner.
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
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if holder is Dictionary and holder.has(server_name):
		holder.erase(server_name)
		if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
			return {"status": "error", "message": "Cannot write to %s" % path}
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
		if client.command_shape != McpClient.CommandShape.FLAT or not bool(launch.get("ok", false)):
			return false
		for key in client.command_legacy_keys:
			if entry.has(String(key)):
				return false
		var env = entry.get("env", null)
		if env is Dictionary:
			for key in client.command_env_legacy_keys:
				if env.has(String(key)):
					return false
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
	if client.command_shape != McpClient.CommandShape.FLAT:
		return "%s uses a command shape not supported by JSON yet" % client.display_name
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


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


## Returns {"ok": true, "data": Dictionary} when the file is absent or parses
## cleanly, and {"ok": false, "error": String} when the file exists with
## non-empty content we cannot safely round-trip. Callers must NOT fall back
## to an empty dict on the error path — doing so blows away the user's other
## MCP entries on the next write.
static func _read_or_init(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "error": "could not open for reading (error %d)" % err}
	var content := file.get_as_text()
	file.close()
	# Strip a UTF-8 BOM if present — some editors (notably on Windows) save
	# JSON with a leading ﻿, which Godot's JSON.parse rejects outright.
	# Previously this landed on the "unparseable → wipe" path.
	if content.begins_with("﻿"):
		content = content.substr(1)
	if content.strip_edges().is_empty():
		return {"ok": true, "data": {}}
	var json := JSON.new()
	if json.parse(content) != OK:
		var msg := "JSON parse error on line %d: %s" % [json.get_error_line(), json.get_error_message()]
		push_warning("MCP | %s in %s" % [msg, path])
		return {"ok": false, "error": msg}
	if not (json.data is Dictionary):
		return {"ok": false, "error": "top-level value is %s, expected object" % type_string(typeof(json.data))}
	return {"ok": true, "data": json.data}


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
