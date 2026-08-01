@tool
class_name McpTomlStrategy
extends RefCounted

## TOML upsert for URL entries and client-owned command entries.
##
## This remains deliberately smaller than a general TOML parser, but the
## parts that affect migration are semantic: assignments retain their whole
## value span (including multiline arrays/strings), and command/args status
## verification decodes TOML strings and arrays rather than comparing text.


static func configure(
	client: McpClient,
	_server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> Dictionary:
	var resolution := client.resolved_config_path_details()
	var path := str(resolution.get("path", ""))
	var path_error := str(resolution.get("error", ""))
	if not path_error.is_empty():
		return {"status": "error", "message": path_error}
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s" % client.display_name}

	var seed_path := str(resolution.get("seed_path", ""))
	var read_path := seed_path if not FileAccess.file_exists(path) and not seed_path.is_empty() else path
	var read := _read_or_init(read_path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [read_path, read["error"]]}

	var rendered := render_body(client, server_url, launch)
	if not bool(rendered.get("ok", false)):
		return {"status": "error", "message": str(rendered.get("error", "Could not build the TOML entry."))}

	var lines: Array[String] = _split_lines(String(read["data"]))
	var body: Array[String] = rendered["lines"]
	var pinned_keys: Dictionary = rendered["pinned_keys"]
	var initial_keys: Dictionary = rendered["initial_keys"]
	var removed_keys: Dictionary = rendered["removed_keys"]

	var section := _find_section(lines, _all_headers(client))
	var header := _primary_header(client)
	var new_lines: Array[String] = [header]

	if section.is_empty():
		new_lines.append_array(body)
		var output_fresh: Array[String] = []
		output_fresh.append_array(lines)
		if not output_fresh.is_empty() and not output_fresh[-1].strip_edges().is_empty():
			output_fresh.append("")
		output_fresh.append_array(new_lines)
		if not McpAtomicWrite.write(path, "\n".join(output_fresh)):
			return {"status": "error", "message": "Cannot write to %s" % path}
		return {"status": "ok", "message": "%s configured" % client.display_name}

	var old_items := _value_items(lines, int(section["start"]) + 1, int(section["end"]))
	var old_by_key := {}
	for item in old_items:
		var old_key := str(item.get("key", ""))
		if not old_key.is_empty() and not old_by_key.has(old_key):
			old_by_key[old_key] = item

	var body_items := _value_items(body, 0, body.size())
	var emitted_keys := {}
	for item in body_items:
		var key := str(item.get("key", ""))
		if key.is_empty():
			new_lines.append_array(item["lines"])
			continue
		emitted_keys[key] = true
		if initial_keys.has(key) and old_by_key.has(key):
			new_lines.append_array(old_by_key[key]["lines"])
		else:
			## Pinned keys always use the freshly rendered span. A generated key
			## that is neither pinned nor initial is also rendered deterministically.
			new_lines.append_array(item["lines"])

	## Carry unknown/user-owned assignments and standalone comments verbatim.
	## Whole item spans prevent multiline arrays/strings from being truncated.
	for item in old_items:
		var key := str(item.get("key", ""))
		if not key.is_empty():
			if emitted_keys.has(key) or pinned_keys.has(key) or removed_keys.has(key):
				continue
			new_lines.append_array(item["lines"])
			continue
		var item_lines: Array = item.get("lines", [])
		for line in item_lines:
			if not str(line).strip_edges().is_empty():
				new_lines.append(str(line))

	var output: Array[String] = []
	output.append_array(_slice(lines, 0, int(section["start"])))
	output.append_array(new_lines)
	output.append_array(_slice(lines, int(section["end"]), lines.size()))
	output = _rewrite_legacy_descendant_headers(output, client)

	if not McpAtomicWrite.write(path, "\n".join(output)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured" % client.display_name}


static func check_status(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, launch).get("status", McpClient.Status.NOT_CONFIGURED)


static func check_status_details(
	client: McpClient,
	_server_name: String,
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
	var lines: Array[String] = _split_lines(String(read["data"]))
	var section := _find_section(lines, _all_headers(client))
	if section.is_empty():
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}

	var items := _value_items(lines, int(section["start"]) + 1, int(section["end"]))
	var by_key := {}
	for item in items:
		var key := str(item.get("key", ""))
		if not key.is_empty() and not by_key.has(key):
			by_key[key] = item

	if client.command_shape != McpClient.CommandShape.NONE:
		if not bool(launch.get("ok", false)):
			return {
				"status": McpClient.Status.ERROR,
				"error_msg": str(launch.get("error", "No compatible attach launcher was found.")),
			}
		for legacy_key in client.command_legacy_keys:
			if by_key.has(String(legacy_key)):
				return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		if not by_key.has("command") or not by_key.has("args"):
			return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		var command_value := _decode_toml_string(_item_value(by_key["command"]))
		var args_value := _decode_toml_string_array(_item_value(by_key["args"]))
		if not bool(command_value.get("ok", false)) or not bool(args_value.get("ok", false)):
			return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		if str(command_value.get("value", "")) != str(launch.get("command", "")):
			return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		if not _string_arrays_equal(args_value.get("value", []), launch.get("args", [])):
			return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		if not client.command_transport_key.is_empty():
			var transport_key := client.command_transport_key
			if not by_key.has(transport_key):
				return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
			var decoded_transport := _decode_toml_scalar(_item_value(by_key[transport_key]))
			if not bool(decoded_transport.get("ok", false)) or decoded_transport.get("value") != client.command_transport_value:
				return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}

	if not by_key.has("url"):
		return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
	var url_value := _decode_toml_string(_item_value(by_key["url"]))
	if not bool(url_value.get("ok", false)) or str(url_value.get("value", "")) != server_url:
		return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}
	return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}


static func remove(client: McpClient, _server_name: String) -> Dictionary:
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
	var lines: Array[String] = _split_lines(String(read["data"]))
	var headers := _all_headers(client)
	var subtable_prefixes := _subtable_prefixes(headers)

	var output: Array[String] = []
	var i := 0
	while i < lines.size():
		if _matches_any_header(lines[i], headers) or _matches_subtable_prefix(lines[i], subtable_prefixes):
			i += 1
			while i < lines.size() and not _is_any_section_header(lines[i]):
				i += 1
			continue
		output.append(lines[i])
		i += 1

	if not McpAtomicWrite.write(path, "\n".join(output)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Substitute `{url}` in every legacy URL body-template line.
static func format_body(template: PackedStringArray, server_url: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in template:
		out.append(String(line).replace("{url}", server_url))
	return out


## Encode a TOML basic string. This is intentionally public for the
## cross-language fixture test that parses the rendered sample with tomllib.
static func encode_basic_string(value: String) -> String:
	return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"').replace("\b", "\\b").replace("\t", "\\t").replace("\n", "\\n").replace("\f", "\\f").replace("\r", "\\r")


## Multi-line string-array encoding used by command-shape entries.
static func encode_string_array(values: Variant) -> Array[String]:
	var out: Array[String] = ["["]
	for value in values:
		out.append("  %s," % encode_basic_string(str(value)))
	out.append("]")
	return out


static func render_body(client: McpClient, server_url: String, launch: Dictionary) -> Dictionary:
	if client.command_shape == McpClient.CommandShape.NONE:
		if client.toml_body_template.is_empty():
			return {"ok": false, "error": "%s descriptor missing toml_body_template" % client.display_name}
		var legacy_body := format_body(client.toml_body_template, server_url)
		var legacy_lines: Array[String] = []
		var pinned := {}
		var initial := {}
		for idx in range(legacy_body.size()):
			legacy_lines.append(String(legacy_body[idx]))
			var key := _line_key(String(client.toml_body_template[idx]))
			if key.is_empty():
				continue
			if String(client.toml_body_template[idx]).contains("{url}"):
				pinned[key] = true
			else:
				initial[key] = true
		return {
			"ok": true,
			"lines": legacy_lines,
			"pinned_keys": pinned,
			"initial_keys": initial,
			"removed_keys": {},
		}

	if client.command_shape != McpClient.CommandShape.COMMAND_ARRAY:
		return {"ok": false, "error": "%s uses a command shape not supported by TOML yet" % client.display_name}
	if not bool(launch.get("ok", false)):
		return {"ok": false, "error": str(launch.get("error", "No compatible attach launcher was found."))}

	var command_lines: Array[String] = [
		"command = %s" % encode_basic_string(str(launch.get("command", ""))),
	]
	command_lines.append_array(_encode_assignment("args", launch.get("args", [])))

	var pinned_keys := {"command": true, "args": true}
	if not client.command_transport_key.is_empty():
		var encoded_transport := _encode_scalar(client.command_transport_value)
		if encoded_transport.is_empty():
			return {
				"ok": false,
				"error": "Unsupported TOML transport `%s` for %s" % [
					client.command_transport_key, client.display_name,
				],
			}
		command_lines.append("%s = %s" % [client.command_transport_key, encoded_transport])
		pinned_keys[client.command_transport_key] = true

	var initial_keys := {}
	for key in client.command_initial_fields:
		var encoded := _encode_assignment(str(key), client.command_initial_fields[key])
		if encoded.is_empty():
			return {"ok": false, "error": "Unsupported TOML default `%s` for %s" % [key, client.display_name]}
		command_lines.append_array(encoded)
		initial_keys[str(key)] = true

	var removed_keys := {}
	for key in client.command_legacy_keys:
		removed_keys[String(key)] = true
	return {
		"ok": true,
		"lines": command_lines,
		"pinned_keys": pinned_keys,
		"initial_keys": initial_keys,
		"removed_keys": removed_keys,
	}


static func _encode_assignment(key: String, value: Variant) -> Array[String]:
	if value is Array or value is PackedStringArray:
		var lines := encode_string_array(value)
		lines[0] = "%s = %s" % [key, lines[0]]
		return lines
	var encoded := _encode_scalar(value)
	var lines: Array[String] = []
	if not encoded.is_empty():
		lines.append("%s = %s" % [key, encoded])
	return lines


static func _encode_scalar(value: Variant) -> String:
	if value is String:
		return encode_basic_string(value)
	if value is bool:
		return "true" if value else "false"
	if value is int or value is float:
		return str(value)
	return ""


# --- span-aware merge helpers -------------------------------------------

static func _value_items(lines: Array[String], from: int, to: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i := from
	while i < to:
		var key := _line_key(lines[i])
		if key.is_empty():
			out.append({"key": "", "lines": [lines[i]]})
			i += 1
			continue
		var end := _value_span_end(lines, i, to)
		out.append({"key": key, "lines": _slice(lines, i, end)})
		i = end
	return out


static func _value_span_end(lines: Array[String], start: int, limit: int) -> int:
	var state := {"quote": "", "square": 0, "curly": 0, "escaped": false}
	for i in range(start, limit):
		var begin := 0
		if i == start:
			var eq := _assignment_equal(lines[i])
			begin = eq + 1 if eq >= 0 else 0
		_scan_toml_value_line(lines[i], begin, state)
		if str(state["quote"]).is_empty() and int(state["square"]) == 0 and int(state["curly"]) == 0:
			return i + 1
	return limit


static func _scan_toml_value_line(line: String, begin: int, state: Dictionary) -> void:
	var i := begin
	while i < line.length():
		var quote := str(state["quote"])
		if quote == '"""' or quote == "'''":
			if line.substr(i).begins_with(quote):
				state["quote"] = ""
				i += 3
				continue
			if quote == '"""' and line.unicode_at(i) == 92 and not bool(state["escaped"]):
				state["escaped"] = true
				i += 1
				continue
			state["escaped"] = false
			i += 1
			continue
		if quote == '"' or quote == "'":
			var c := line.unicode_at(i)
			if quote == '"' and c == 92 and not bool(state["escaped"]):
				state["escaped"] = true
				i += 1
				continue
			if c == quote.unicode_at(0) and not bool(state["escaped"]):
				state["quote"] = ""
			state["escaped"] = false
			i += 1
			continue

		if line.substr(i).begins_with('"""'):
			state["quote"] = '"""'
			i += 3
			continue
		if line.substr(i).begins_with("'''"):
			state["quote"] = "'''"
			i += 3
			continue
		var c := line.unicode_at(i)
		if c == 34:
			state["quote"] = '"'
		elif c == 39:
			state["quote"] = "'"
		elif c == 35:
			break
		elif c == 91:
			state["square"] = int(state["square"]) + 1
		elif c == 93:
			state["square"] = maxi(0, int(state["square"]) - 1)
		elif c == 123:
			state["curly"] = int(state["curly"]) + 1
		elif c == 125:
			state["curly"] = maxi(0, int(state["curly"]) - 1)
		i += 1


static func _line_key(line: String) -> String:
	var eq := _assignment_equal(line)
	if eq <= 0:
		return ""
	return line.substr(0, eq).strip_edges()


static func _assignment_equal(line: String) -> int:
	var quote := 0
	var escaped := false
	for i in range(line.length()):
		var c := line.unicode_at(i)
		if quote != 0:
			if quote == 34 and c == 92 and not escaped:
				escaped = true
				continue
			if c == quote and not escaped:
				quote = 0
			escaped = false
			continue
		if c == 34 or c == 39:
			quote = c
		elif c == 35:
			return -1
		elif c == 61:
			return i
	return -1


# --- semantic value decoding --------------------------------------------

static func _item_value(item: Dictionary) -> String:
	var item_lines: Array = item.get("lines", [])
	if item_lines.is_empty():
		return ""
	var first := str(item_lines[0])
	var eq := _assignment_equal(first)
	if eq < 0:
		return ""
	var parts: Array[String] = [first.substr(eq + 1)]
	for i in range(1, item_lines.size()):
		parts.append(str(item_lines[i]))
	return "\n".join(parts)


static func _decode_toml_scalar(raw: String) -> Dictionary:
	var cleaned := _without_comments(raw).strip_edges()
	if cleaned == "true":
		return {"ok": true, "value": true}
	if cleaned == "false":
		return {"ok": true, "value": false}
	var string_value := _decode_toml_string(cleaned)
	if bool(string_value.get("ok", false)):
		return string_value
	if cleaned.is_valid_int():
		return {"ok": true, "value": cleaned.to_int()}
	if cleaned.is_valid_float():
		return {"ok": true, "value": cleaned.to_float()}
	return {"ok": false}


static func _decode_toml_string(raw: String) -> Dictionary:
	var cleaned := _without_comments(raw).strip_edges()
	if cleaned.length() >= 2 and cleaned.begins_with("'") and cleaned.ends_with("'"):
		return {"ok": true, "value": cleaned.substr(1, cleaned.length() - 2)}
	if cleaned.length() < 2 or not cleaned.begins_with('"') or not cleaned.ends_with('"'):
		return {"ok": false}
	var parsed: Variant = JSON.parse_string(cleaned)
	if parsed is String:
		return {"ok": true, "value": parsed}
	return {"ok": false}


static func _decode_toml_string_array(raw: String) -> Dictionary:
	var cleaned := _without_comments(raw).strip_edges()
	if not cleaned.begins_with("["):
		return {"ok": false}
	var i := 1
	var values: Array[String] = []
	while true:
		i = _skip_space(cleaned, i)
		if i >= cleaned.length():
			return {"ok": false}
		if cleaned.unicode_at(i) == 93:
			i = _skip_space(cleaned, i + 1)
			return {"ok": i == cleaned.length(), "value": values}
		var parsed := _parse_string_at(cleaned, i)
		if not bool(parsed.get("ok", false)):
			return {"ok": false}
		values.append(str(parsed.get("value", "")))
		i = _skip_space(cleaned, int(parsed.get("next", i)))
		if i >= cleaned.length():
			return {"ok": false}
		var c := cleaned.unicode_at(i)
		if c == 44:
			i += 1
			continue
		if c == 93:
			continue
		return {"ok": false}
	return {"ok": false}  # Unreachable; keeps GDScript's return analysis explicit.


static func _parse_string_at(text: String, start: int) -> Dictionary:
	if start >= text.length():
		return {"ok": false}
	var quote := text.unicode_at(start)
	if quote != 34 and quote != 39:
		return {"ok": false}
	var i := start + 1
	var escaped := false
	while i < text.length():
		var c := text.unicode_at(i)
		if quote == 34 and c == 92 and not escaped:
			escaped = true
			i += 1
			continue
		if c == quote and not escaped:
			var raw := text.substr(start, i - start + 1)
			if quote == 39:
				return {"ok": true, "value": raw.substr(1, raw.length() - 2), "next": i + 1}
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is String:
				return {"ok": true, "value": parsed, "next": i + 1}
			return {"ok": false}
		escaped = false
		i += 1
	return {"ok": false}


static func _without_comments(raw: String) -> String:
	var out: Array[String] = []
	for line in raw.split("\n"):
		var quote := 0
		var escaped := false
		var kept := ""
		for i in range(line.length()):
			var c := line.unicode_at(i)
			if quote != 0:
				kept += line.substr(i, 1)
				if quote == 34 and c == 92 and not escaped:
					escaped = true
					continue
				if c == quote and not escaped:
					quote = 0
				escaped = false
				continue
			if c == 34 or c == 39:
				quote = c
				kept += line.substr(i, 1)
			elif c == 35:
				break
			else:
				kept += line.substr(i, 1)
		out.append(kept)
	return "\n".join(out)


static func _skip_space(text: String, start: int) -> int:
	var i := start
	while i < text.length() and text.substr(i, 1) in [" ", "\t", "\r", "\n"]:
		i += 1
	return i


static func _string_arrays_equal(left: Variant, right: Variant) -> bool:
	if not (left is Array or left is PackedStringArray):
		return false
	if not (right is Array or right is PackedStringArray):
		return false
	if left.size() != right.size():
		return false
	for i in range(left.size()):
		if str(left[i]) != str(right[i]):
			return false
	return true


# --- file / section helpers ---------------------------------------------

static func _read_or_init(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "error": "could not open for reading (error %d)" % err}
	var text := f.get_as_text()
	f.close()
	return {"ok": true, "data": text}


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
	var parts := client.toml_section_path
	if parts.size() < 2:
		return "[%s]" % ".".join(parts)
	var section := ".".join(McpClient._packed_slice(parts, 0, parts.size() - 1))
	var name := parts[parts.size() - 1]
	return "[%s.\"%s\"]" % [section, name]


static func _all_headers(client: McpClient) -> Array[String]:
	var primary := _primary_header(client)
	var out: Array[String] = [primary]
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
	for part in parts:
		if not _is_bare_key(String(part)):
			return ""
	return "[%s]" % ".".join(parts)


static func _is_bare_key(value: String) -> bool:
	if value.is_empty():
		return false
	for i in range(value.length()):
		var c := value.unicode_at(i)
		var alpha := (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		var digit := c >= 48 and c <= 57
		if not (alpha or digit or c == 45 or c == 95):
			return false
	return true


static func _subtable_prefixes(headers: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for header in headers:
		if header.length() > 2 and header.ends_with("]"):
			out.append(header.substr(0, header.length() - 1) + ".")
	return out


static func _matches_subtable_prefix(line: String, prefixes: Array[String]) -> bool:
	var trimmed := line.strip_edges()
	for prefix in prefixes:
		if not trimmed.begins_with(prefix):
			continue
		var rest := trimmed.substr(prefix.length())
		var bracket := rest.find("]")
		if bracket < 0:
			continue
		var remainder := rest.substr(bracket + 1).strip_edges()
		if remainder.is_empty() or remainder.begins_with("#"):
			return true
	return false


static func _matches_any_header(line: String, headers: Array[String]) -> bool:
	var trimmed := line.strip_edges()
	for header in headers:
		if not trimmed.begins_with(header):
			continue
		var remainder := trimmed.substr(header.length()).strip_edges()
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


static func _is_any_section_header(line: String) -> bool:
	var trimmed := line.strip_edges()
	if not trimmed.begins_with("["):
		return false
	var bracket := trimmed.find("]")
	if bracket < 0:
		return false
	var remainder := trimmed.substr(bracket + 1).strip_edges()
	return remainder.is_empty() or remainder.begins_with("#")


static func _rewrite_legacy_descendant_headers(
	lines: Array[String], client: McpClient
) -> Array[String]:
	if client.toml_legacy_section_aliases.is_empty():
		return lines
	var primary := _primary_header(client)
	var primary_prefix := primary.substr(0, primary.length() - 1) + "."
	var out: Array[String] = []
	for line in lines:
		var rewritten := line
		var trimmed := line.strip_edges()
		var indent_length := line.find("[")
		var indent := line.substr(0, indent_length) if indent_length >= 0 else ""
		for alias in client.toml_legacy_section_aliases:
			var legacy_prefix := "[%s." % String(alias)
			if trimmed.begins_with(legacy_prefix):
				rewritten = indent + primary_prefix + trimmed.substr(legacy_prefix.length())
				break
		out.append(rewritten)
	return out
