@tool
class_name McpJsonStrategy
extends RefCounted

## Read–merge–write strategy for JSON-backed MCP clients.
## All knobs come from the McpClient descriptor — no per-client branches in here.


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _ensure_path(config, client.server_key_path)
	holder[server_name] = client.entry_builder.call(server_name, server_url)

	if not McpAtomicWrite.write(path, JSON.stringify(config, "\t")):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return McpClient.Status.NOT_CONFIGURED
	var read := _read_or_init(path)
	if not read["ok"]:
		return McpClient.Status.NOT_CONFIGURED
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if not (holder is Dictionary) or not holder.has(server_name):
		return McpClient.Status.NOT_CONFIGURED
	var entry = holder[server_name]
	if not (entry is Dictionary):
		return McpClient.Status.NOT_CONFIGURED
	## An entry under `server_name` exists — if the URL doesn't match,
	## that's drift (the user changed the port and the client config is stale),
	## not "never configured". The dock surfaces that as an amber banner.
	if client.verify_entry.is_valid():
		return McpClient.Status.CONFIGURED if client.verify_entry.call(entry, server_url) else McpClient.Status.CONFIGURED_MISMATCH
	return McpClient.Status.CONFIGURED if entry.get(client.entry_url_field, "") == server_url else McpClient.Status.CONFIGURED_MISMATCH


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if holder is Dictionary and holder.has(server_name):
		holder.erase(server_name)
		if not McpAtomicWrite.write(path, JSON.stringify(config, "\t")):
			return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


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
