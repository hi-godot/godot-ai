@tool
class_name McpTomlStrategy
extends RefCounted

## Minimal TOML upsert: replace or insert one [section."name"] block produced by
## `client.toml_body_builder`. Generalized from the original Codex-only logic.


static func configure(client: McpClient, _server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s" % client.display_name}

	var content := _read_text(path)
	var lines := _split_lines(content)
	var body: PackedStringArray = client.toml_body_builder.call(server_url)

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
	var lines := _split_lines(_read_text(path))
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
	if configured_url != server_url or not enabled:
		return McpClient.Status.NOT_CONFIGURED
	return McpClient.Status.CONFIGURED


static func remove(client: McpClient, _server_name: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var lines := _split_lines(_read_text(path))
	var headers := _all_headers(client)

	var output: Array[String] = []
	var i := 0
	while i < lines.size():
		if _matches_any_header(lines[i], headers):
			i += 1
			while i < lines.size():
				var nt := lines[i].strip_edges()
				if nt.begins_with("[") and nt.ends_with("]"):
					break
				i += 1
			continue
		output.append(lines[i])
		i += 1

	if not McpAtomicWrite.write(path, "\n".join(output)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


# --- helpers --------------------------------------------------------------

static func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


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
	var section := ".".join(_packed_slice(parts, 0, parts.size() - 1))
	var name := parts[parts.size() - 1]
	return "[%s.\"%s\"]" % [section, name]


static func _all_headers(client: McpClient) -> Array[String]:
	var out: Array[String] = [_primary_header(client)]
	for legacy in client.toml_legacy_section_aliases:
		out.append("[%s]" % legacy)
	return out


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
				var nt := lines[j].strip_edges()
				if nt.begins_with("[") and nt.ends_with("]"):
					end = j
					break
			return {"start": i, "end": end}
	return {}


static func _packed_slice(packed: PackedStringArray, from: int, to: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(from, to):
		out.append(packed[i])
	return out
