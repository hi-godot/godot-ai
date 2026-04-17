@tool
class_name McpJsonStrategy
extends RefCounted

## Read–merge–write strategy for JSON-backed MCP clients.
## All knobs come from the McpClient descriptor — no per-client branches in here.


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var config := _read_or_init(path)
	var holder := _ensure_path(config, client.server_key_path)
	holder[server_name] = client.entry_builder.call(server_name, server_url)

	if not McpAtomicWrite.write(path, JSON.stringify(config, "\t")):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return McpClient.Status.NOT_CONFIGURED
	var config := _read_or_init(path)
	var holder := _walk_path(config, client.server_key_path)
	if not (holder is Dictionary) or not holder.has(server_name):
		return McpClient.Status.NOT_CONFIGURED
	var entry = holder[server_name]
	if not (entry is Dictionary):
		return McpClient.Status.NOT_CONFIGURED
	if client.verify_entry.is_valid():
		return McpClient.Status.CONFIGURED if client.verify_entry.call(entry, server_url) else McpClient.Status.NOT_CONFIGURED
	return McpClient.Status.CONFIGURED if entry.get(client.entry_url_field, "") == server_url else McpClient.Status.NOT_CONFIGURED


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var config := _read_or_init(path)
	var holder := _walk_path(config, client.server_key_path)
	if holder is Dictionary and holder.has(server_name):
		holder.erase(server_name)
		if not McpAtomicWrite.write(path, JSON.stringify(config, "\t")):
			return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


static func _read_or_init(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var content := file.get_as_text()
	file.close()
	if content.strip_edges().is_empty():
		return {}
	var json := JSON.new()
	if json.parse(content) != OK:
		push_warning("MCP | JSON parse error in %s: %s (line %d)" % [path, json.get_error_message(), json.get_error_line()])
		return {}
	if json.data is Dictionary:
		return json.data
	return {}


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
