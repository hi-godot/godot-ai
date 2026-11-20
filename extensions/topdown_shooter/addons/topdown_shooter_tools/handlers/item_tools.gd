@tool
extends RefCounted

## item_db_import: turns an item spreadsheet (CSV/TSV) into one item .tres
## per row plus an item database .tres that indexes them. Godot AI
## materializes this script lazily (no-arg new()) and calls one method per
## tool with (params: Dictionary, ctx: McpCallContext).
##
## Columns map to the item script's @export properties by name (or an alias,
## or column_map). Values are converted from the property's type, so a
## project that adds an @export var to its copy of item_data.gd and a column
## of the same name gets it filled with no tool change. Every row is
## validated before anything is written; one bad cell writes nothing.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_ITEM_DIR := "res://data/items"
const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_WEAPON_DATA_DIR := "res://data/weapons"
const DATABASE_FILE := "item_database.tres"
const MAX_ROWS := 5000
const MAX_LISTED_ERRORS := 15
const EXISTING_MODES := ["update", "replace", "skip", "error"]

## Normalized header -> item property. English and Korean spreadsheet
## headings people commonly use.
const HEADER_ALIASES := {
	"id": "item_id",
	"name": "display_name",
	"title": "display_name",
	"desc": "description",
	"type": "category",
	"grade": "rarity",
	"price": "value",
	"sell_price": "value",
	"cost": "value",
	"stack": "max_stack",
	"stack_size": "max_stack",
	"max_stack_size": "max_stack",
	"width": "grid_width",
	"height": "grid_height",
	"w": "grid_width",
	"h": "grid_height",
	"weight_kg": "weight",
	"ammo": "ammo_type",
	"caliber": "ammo_type",
	"tag": "tags",
	"아이디": "item_id",
	"이름": "display_name",
	"설명": "description",
	"분류": "category",
	"종류": "category",
	"희귀도": "rarity",
	"등급": "rarity",
	"아이콘": "icon",
	"무게": "weight",
	"가격": "value",
	"중첩": "max_stack",
	"최대중첩": "max_stack",
	"가로": "grid_width",
	"세로": "grid_height",
	"무기": "weapon",
	"탄종": "ammo_type",
	"태그": "tags",
}

const _TRUE_WORDS := ["true", "yes", "y", "1", "o", "on"]
const _FALSE_WORDS := ["false", "no", "n", "0", "x", "off"]


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func item_db_import(params: Dictionary, _ctx = null) -> Dictionary:
	var csv_path: Variant = Util.text(params, "csv_path", "")
	var csv_text: Variant = _raw_text(params, "csv_text")
	var delimiter: Variant = _raw_text(params, "delimiter")
	var data_dir: Variant = Util.text(params, "data_dir", DEFAULT_ITEM_DIR)
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var weapon_dir: Variant = Util.text(params, "weapon_data_dir", DEFAULT_WEAPON_DATA_DIR)
	var existing: Variant = Util.text(params, "existing", "update")
	var update_database: Variant = Util.boolean(params, "update_database", true)
	var database_path: Variant = Util.text(params, "database_path", "")
	var dry_run: Variant = Util.boolean(params, "dry_run", false)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	for v in [csv_path, csv_text, delimiter, data_dir, script_dir, weapon_dir, existing, update_database, database_path, dry_run, overwrite_scripts]:
		if Util.is_error(v):
			return v
	var column_map: Variant = _column_map(params)
	if Util.is_error(column_map):
		return column_map
	if existing not in EXISTING_MODES:
		return Util.error(Util.INVALID_PARAMS, "'existing' must be one of %s" % ", ".join(EXISTING_MODES))
	if String(delimiter).is_empty():
		delimiter = "auto"
	if delimiter not in ["auto", ",", ";", "\t", "tab", "|"]:
		return Util.error(Util.INVALID_PARAMS, "'delimiter' must be auto, \",\", \";\", \"|\" or \"tab\"")

	data_dir = Util.clean_dir(data_dir)
	weapon_dir = Util.clean_dir(weapon_dir)
	if String(database_path).is_empty():
		database_path = data_dir + "/" + DATABASE_FILE
	var reason := Util.check_res_path(data_dir + "/x.tres", "tres")
	if reason.is_empty() and update_database:
		reason = Util.check_res_path(database_path, "tres")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)

	## --- read the sheet -------------------------------------------------------
	var source: Variant = _read_source(csv_path, csv_text)
	if Util.is_error(source):
		return source
	var delim: String = _pick_delimiter(delimiter, source, csv_path)
	var rows := parse_csv(source, delim)
	if rows.is_empty():
		return Util.error(Util.INVALID_PARAMS, "the sheet is empty; the first row must be the column headers")
	var header: PackedStringArray = rows[0].cells
	var body := rows.slice(1)
	if body.size() > MAX_ROWS:
		return Util.error(Util.INVALID_PARAMS, "the sheet has %d rows; import at most %d at a time" % [body.size(), MAX_ROWS])

	## --- item script (its @export list drives column mapping) -----------------
	var item_script_path: String = Util.clean_dir(script_dir) + "/item_data.gd"
	var db_script_path: String = Util.clean_dir(script_dir) + "/item_database.gd"
	var item_script: Variant = _peek_or_install("item_data.gd.tmpl", item_script_path, overwrite_scripts, dry_run)
	if Util.is_error(item_script):
		return item_script
	var props := _exported_properties(item_script.script)
	if not props.has("item_id"):
		return Util.error(Util.INVALID_PARAMS, "%s has no 'item_id' property; restore it or pass overwrite_scripts=true" % item_script_path)

	var mapping := _map_columns(header, props, column_map)
	if Util.is_error(mapping):
		return mapping
	if not mapping.by_index.values().has("item_id"):
		return Util.error(Util.INVALID_PARAMS, "no id column: name one 'item_id' or 'id' (or map one with column_map). Headers: %s" % ", ".join(header))

	## --- validate every row before writing ------------------------------------
	var items: Array = []
	var errors: Array[String] = []
	var seen := {}
	var skipped_rows := 0
	for row in body:
		if _blank_or_comment(row.cells):
			skipped_rows += 1
			continue
		var parsed := _parse_row(row, mapping, props, weapon_dir, data_dir)
		if parsed.errors.is_empty():
			if seen.has(parsed.id):
				parsed.errors.append("line %d: item_id '%s' repeats line %d" % [row.line, parsed.id, seen[parsed.id]])
			else:
				seen[parsed.id] = row.line
		errors.append_array(parsed.errors)
		items.append(parsed)
	if items.is_empty():
		return Util.error(Util.INVALID_PARAMS, "the sheet has headers but no item rows")
	if not errors.is_empty():
		var listed := errors.slice(0, MAX_LISTED_ERRORS)
		var more := "" if errors.size() <= MAX_LISTED_ERRORS else " (+%d more)" % (errors.size() - MAX_LISTED_ERRORS)
		return Util.error(Util.INVALID_PARAMS, "%d problem(s) in the sheet, nothing was written: %s%s" % [errors.size(), "; ".join(listed), more])

	## --- decide what happens to each file -------------------------------------
	for item in items:
		item.path = data_dir + "/" + item.id + ".tres"
		item.action = "create"
		if FileAccess.file_exists(item.path):
			match existing:
				"error":
					return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass existing=\"update\", \"replace\" or \"skip\"" % item.path)
				"replace":
					item.action = "replace"
				_:
					item.action = existing
					var current := ResourceLoader.load(item.path)
					if current == null or not _is_item(current, item_script_path):
						return Util.error(Util.INVALID_PARAMS, "%s is not an item made with %s; pass existing=\"replace\" to overwrite it, or another data_dir" % [item.path, item_script_path])

	var report := _report(items, mapping, header, skipped_rows, data_dir)
	if dry_run:
		report["dry_run"] = true
		report["script"] = {"path": item_script_path, "status": item_script.status}
		if update_database:
			report["database"] = {"path": database_path, "status": "would update" if FileAccess.file_exists(database_path) else "would create"}
		return {"data": report}

	## --- write ----------------------------------------------------------------
	var db_script: Variant = null
	if update_database:
		db_script = Util.install_script("item_database.gd.tmpl", db_script_path, overwrite_scripts)
		if Util.is_error(db_script):
			return db_script
	var targets: Array[String] = []
	for item in items:
		if item.action != "skip":
			targets.append(item.path)
	if update_database:
		targets.append(database_path)
	var before := FileSnapshot.capture(targets)

	var resources := {}
	for item in items:
		if item.action == "skip":
			resources[item.id] = ResourceLoader.load(item.path)
			continue
		var res: Resource
		if item.action == "update":
			res = ResourceLoader.load(item.path)
		else:
			res = Resource.new()
			res.set_script(item_script.script)
			res.set("display_name", String(item.id).capitalize())
		res.set("item_id", item.id)
		for key in item.values:
			res.set(key, item.values[key])
		if not item.extra.is_empty():
			var extra: Dictionary = res.get("extra") if res.get("extra") is Dictionary else {}
			extra = extra.duplicate()
			extra.merge(item.extra, true)
			res.set("extra", extra)
		var msg := ""
		if item.action == "update":
			var save_err := ResourceSaver.save(res, item.path)
			if save_err != OK:
				msg = "cannot save %s: %s" % [item.path, error_string(save_err)]
		else:
			msg = Util.save_resource(res, item.path)
		if not msg.is_empty():
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, msg + " (files written so far were rolled back)")
		resources[item.id] = res

	var written: Array = targets.duplicate()
	written.append(item_script_path)
	if update_database:
		var db_report: Variant = _write_database(database_path, db_script.script, db_script_path, items, resources)
		if Util.is_error(db_report):
			before.restore()
			return db_report
		report["database"] = db_report
		report["database"]["script"] = {"path": db_script_path, "status": db_script.status}
		written.append(db_script_path)
	Util.refresh_filesystem(written)

	var after := FileSnapshot.capture(targets)
	var ur := EditorInterface.get_editor_undo_redo() if Engine.is_editor_hint() else null
	if ur != null and not targets.is_empty():
		## File edits are not scene edits: the action lives in the global
		## history, which the editor's Ctrl+Z reaches when it is the newest.
		ur.create_action("Import %d items" % items.size(), UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_undo_method(before, "restore")
		ur.commit_action(false)
		report["undo"] = "One editor undo step (Edit > Undo) restores the item files and database as they were. Scripts are kept."
	report["script"] = {"path": item_script_path, "status": item_script.status}
	return {"data": report}


# =============================================================================
# CSV
# =============================================================================

## RFC 4180 style: quoted fields may hold the delimiter, newlines and ""
## escaped quotes. Returns [{"line": first line number, "cells": PackedStringArray}].
static func parse_csv(text: String, delim: String) -> Array:
	var rows: Array = []
	var cells := PackedStringArray()
	var field := ""
	var in_quotes := false
	var line := 1
	var row_line := 1
	var i := 0
	var n := text.length()
	var row_started := false
	while i < n:
		var c := text[i]
		if in_quotes:
			if c == "\"":
				if i + 1 < n and text[i + 1] == "\"":
					field += "\""
					i += 1
				else:
					in_quotes = false
			else:
				if c == "\n":
					line += 1
				field += c
		elif c == "\"" and field.strip_edges().is_empty():
			in_quotes = true
			field = ""
			row_started = true
		elif c == delim:
			cells.append(field)
			field = ""
			row_started = true
		elif c == "\r":
			pass
		elif c == "\n":
			if row_started or not field.is_empty():
				cells.append(field)
				rows.append({"line": row_line, "cells": cells})
			cells = PackedStringArray()
			field = ""
			row_started = false
			line += 1
			row_line = line
		else:
			field += c
			row_started = true
		i += 1
	if row_started or not field.is_empty():
		cells.append(field)
		rows.append({"line": row_line, "cells": cells})
	return rows


func _read_source(csv_path: String, csv_text: String) -> Variant:
	if csv_path.is_empty() == csv_text.is_empty():
		return Util.error(Util.INVALID_PARAMS, "pass exactly one of 'csv_path' (a res:// or user:// .csv/.tsv file) or 'csv_text' (the sheet itself)")
	if not csv_text.is_empty():
		return csv_text.trim_prefix("﻿")
	if not (csv_path.begins_with("res://") or csv_path.begins_with("user://")) or csv_path.contains(".."):
		return Util.error(Util.INVALID_PARAMS, "'csv_path' must be a res:// or user:// path without '..'; for a file elsewhere pass its contents as csv_text")
	if not FileAccess.file_exists(csv_path):
		return Util.error(Util.NODE_NOT_FOUND, "%s does not exist" % csv_path)
	var bytes := FileAccess.get_file_as_bytes(csv_path)
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		bytes = bytes.slice(3)
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return Util.error(Util.INVALID_PARAMS, "%s is not UTF-8. Save it again as \"CSV UTF-8\" (Excel) or download it as CSV from Google Sheets" % csv_path)
	return text


static func _pick_delimiter(wanted: String, text: String, path: String) -> String:
	if wanted == "tab":
		return "\t"
	if wanted != "auto":
		return wanted
	if path.get_extension().to_lower() == "tsv":
		return "\t"
	var first := text.get_slice("\n", 0)
	var best := ","
	var best_count := first.count(",")
	for d in ["\t", ";", "|"]:
		if first.count(d) > best_count:
			best = d
			best_count = first.count(d)
	return best


static func _blank_or_comment(cells: PackedStringArray) -> bool:
	if cells.is_empty() or cells[0].strip_edges().begins_with("#"):
		return true
	for c in cells:
		if not c.strip_edges().is_empty():
			return false
	return true


# =============================================================================
# columns and values
# =============================================================================

static func normalize_header(h: String) -> String:
	return h.strip_edges().to_lower().replace(" ", "_").replace("-", "_")


## Returns {"by_index": {col: property}, "extra": {col: key}, "ignored": [header]}.
func _map_columns(header: PackedStringArray, props: Dictionary, column_map: Dictionary) -> Variant:
	var by_index := {}
	var extra := {}
	var ignored: Array[String] = []
	var used := {}
	for i in header.size():
		var raw := header[i].strip_edges()
		var key := normalize_header(raw)
		if key.is_empty() or key.begins_with("#") or key.begins_with("_"):
			if not raw.is_empty():
				ignored.append(raw)
			continue
		var target := ""
		if column_map.has(raw):
			target = column_map[raw]
		elif column_map.has(key):
			target = column_map[key]
		elif props.has(key):
			target = key
		elif HEADER_ALIASES.has(key) and props.has(HEADER_ALIASES[key]):
			target = HEADER_ALIASES[key]
		if target.is_empty():
			extra[i] = key
			continue
		if target == "-":
			ignored.append(raw)
			continue
		if not props.has(target):
			return Util.error(Util.INVALID_PARAMS, "column_map sends '%s' to '%s', which item_data.gd does not export" % [raw, target])
		if target == "extra":
			return Util.error(Util.INVALID_PARAMS, "column '%s' maps to 'extra', which the importer fills from unmatched columns" % raw)
		if used.has(target):
			return Util.error(Util.INVALID_PARAMS, "columns '%s' and '%s' both map to '%s'" % [used[target], raw, target])
		used[target] = raw
		by_index[i] = target
	return {"by_index": by_index, "extra": extra, "ignored": ignored}


func _parse_row(row: Dictionary, mapping: Dictionary, props: Dictionary, weapon_dir: String, data_dir: String) -> Dictionary:
	var out := {"line": row.line, "id": "", "values": {}, "extra": {}, "errors": [] as Array[String]}
	var cells: PackedStringArray = row.cells
	for i in mapping.by_index:
		var prop: String = mapping.by_index[i]
		var raw := cells[i].strip_edges() if i < cells.size() else ""
		if prop == "item_id":
			var id := raw.to_lower().replace(" ", "_").replace("-", "_")
			if id.is_empty():
				out.errors.append("line %d: item_id is empty" % row.line)
			elif not _is_id(id):
				out.errors.append("line %d: item_id '%s' must be letters, digits and underscores" % [row.line, raw])
			out.id = id
			continue
		if raw.is_empty():
			continue
		var converted: Variant = convert_cell(raw, props[prop], weapon_dir)
		if converted is Dictionary and converted.has("_error"):
			out.errors.append("line %d, %s: %s" % [row.line, prop, converted._error])
		else:
			out.values[prop] = converted
	for i in mapping.extra:
		var raw := cells[i].strip_edges() if i < cells.size() else ""
		if not raw.is_empty():
			out.extra[mapping.extra[i]] = guess_value(raw)
	return out


## Converts a cell to the property's type. Returns the value, or
## {"_error": reason}.
static func convert_cell(raw: String, prop: Dictionary, weapon_dir: String = DEFAULT_WEAPON_DATA_DIR) -> Variant:
	var type: int = prop.type
	var hint: int = prop.hint
	var enum_options: PackedStringArray = []
	if hint == PROPERTY_HINT_ENUM:
		for opt in String(prop.hint_string).split(","):
			enum_options.append(opt.get_slice(":", 0).strip_edges())
	match type:
		TYPE_STRING, TYPE_STRING_NAME:
			if not enum_options.is_empty():
				for opt in enum_options:
					if opt.to_lower() == raw.to_lower():
						return opt if type == TYPE_STRING else StringName(opt)
				return {"_error": "'%s' is not one of %s" % [raw, ", ".join(enum_options)]}
			return raw.replace("\\n", "\n") if type == TYPE_STRING else StringName(raw)
		TYPE_INT:
			if not enum_options.is_empty() and not raw.is_valid_int():
				for i in enum_options.size():
					if enum_options[i].to_lower() == raw.to_lower():
						var parts := String(prop.hint_string).split(",")[i].split(":")
						return int(parts[1]) if parts.size() > 1 else i
				return {"_error": "'%s' is not one of %s" % [raw, ", ".join(enum_options)]}
			if raw.is_valid_int():
				return raw.to_int()
			if raw.is_valid_float() and raw.to_float() == floorf(raw.to_float()):
				return int(raw.to_float())
			return {"_error": "'%s' is not a whole number" % raw}
		TYPE_FLOAT:
			if raw.is_valid_float():
				return raw.to_float()
			return {"_error": "'%s' is not a number" % raw}
		TYPE_BOOL:
			var low := raw.to_lower()
			if low in _TRUE_WORDS:
				return true
			if low in _FALSE_WORDS:
				return false
			return {"_error": "'%s' is not true/false" % raw}
		TYPE_PACKED_STRING_ARRAY, TYPE_ARRAY:
			var list := PackedStringArray()
			for part in raw.replace("|", ";").split(";"):
				if not part.strip_edges().is_empty():
					list.append(part.strip_edges())
			if type == TYPE_PACKED_STRING_ARRAY:
				return list
			## Array[String] / Array[StringName] properties need a typed array.
			if hint == PROPERTY_HINT_ARRAY_TYPE and String(prop.hint_string) in ["String", "StringName"]:
				var elem := TYPE_STRING if prop.hint_string == "String" else TYPE_STRING_NAME
				var typed := Array([], elem, &"", null)
				for part in list:
					typed.append(part if elem == TYPE_STRING else StringName(part))
				return typed
			return Array(list)
		TYPE_DICTIONARY:
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Dictionary:
				return parsed
			return {"_error": "expected a JSON object like {\"key\": 1}"}
		TYPE_COLOR:
			if Color.html_is_valid(raw):
				return Color.html(raw)
			var named := Color.from_string(raw, Color(0, 0, 0, -1))
			if named.a >= 0.0:
				return named
			return {"_error": "'%s' is not a color (#rrggbb or a color name)" % raw}
		TYPE_OBJECT:
			return _load_resource_cell(raw, prop, weapon_dir)
	var value: Variant = str_to_var(raw)
	if typeof(value) == type:
		return value
	return {"_error": "'%s' cannot be read as %s (write it the way Godot prints it, e.g. Vector2(1, 2))" % [raw, type_string(type)]}


static func _load_resource_cell(raw: String, prop: Dictionary, weapon_dir: String) -> Variant:
	var path := raw
	if not path.begins_with("res://"):
		if prop.name == "weapon" and _is_id(path.to_lower()):
			path = weapon_dir + "/" + path.to_lower() + ".tres"
		else:
			return {"_error": "'%s' must be a res:// path" % raw}
	if not ResourceLoader.exists(path):
		var hint := " (create it with weapon_create first)" if prop.name == "weapon" else ""
		return {"_error": "%s does not exist%s" % [path, hint]}
	var res := ResourceLoader.load(path)
	var wanted := String(prop.get("class_name", ""))
	if res == null:
		return {"_error": "cannot load %s" % path}
	if not wanted.is_empty() and ClassDB.class_exists(wanted) and not res.is_class(wanted):
		return {"_error": "%s is a %s, not a %s" % [path, res.get_class(), wanted]}
	return res


## For columns with no matching property: numbers and true/false become
## typed values, everything else stays a string.
static func guess_value(raw: String) -> Variant:
	if raw.is_valid_int():
		return raw.to_int()
	if raw.is_valid_float():
		return raw.to_float()
	if raw.to_lower() == "true":
		return true
	if raw.to_lower() == "false":
		return false
	return raw


static func _is_id(value: String) -> bool:
	if value.is_empty():
		return false
	for c in value:
		if not (c == "_" or (c >= "a" and c <= "z") or (c >= "0" and c <= "9")):
			return false
	return true


# =============================================================================
# scripts, resources, report
# =============================================================================

## In a dry run nothing is written: use the project's script when it exists,
## else compile the template in memory just to read its properties.
func _peek_or_install(template: String, dest: String, overwrite: bool, dry_run: bool) -> Variant:
	if not dry_run:
		return Util.install_script(template, dest, overwrite)
	var reason := Util.check_res_path(dest, "gd")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)
	var exists := FileAccess.file_exists(dest)
	var source := FileAccess.get_file_as_string(dest if exists and not overwrite else Util.TEMPLATE_DIR + template)
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return Util.error(Util.INTERNAL_ERROR, "%s does not compile; fix it or pass overwrite_scripts=true" % dest)
	var status := "would keep" if exists and not overwrite else ("would overwrite" if exists else "would create")
	return {"script": script, "status": status, "path": dest}


static func _exported_properties(script: Script) -> Dictionary:
	var out := {}
	for p in script.get_script_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR and p.usage & PROPERTY_USAGE_STORAGE:
			out[p.name] = p
	return out


static func _is_item(res: Resource, script_path: String) -> bool:
	var script := res.get_script() as Script
	return script != null and script.resource_path == script_path


func _write_database(path: String, script: Script, script_path: String, items: Array, resources: Dictionary) -> Variant:
	var db: Resource = null
	var status := "created"
	var kept := 0
	if FileAccess.file_exists(path):
		db = ResourceLoader.load(path)
		var db_script := db.get_script() as Script if db != null else null
		if db_script == null or db_script.resource_path != script_path:
			return Util.error(Util.INVALID_PARAMS, "%s is not an item database made with %s; pass another database_path or update_database=false" % [path, script_path])
		status = "updated"
	else:
		db = Resource.new()
		db.set_script(script)
	var list: Array[Resource] = []
	var index := {}
	for res in db.get("items"):
		if res == null or not ResourceLoader.exists(res.resource_path):
			continue
		var id := String(res.get("item_id"))
		if index.has(id):
			continue
		index[id] = list.size()
		list.append(res)
	kept = list.size()
	for item in items:
		var res: Resource = resources[item.id]
		if index.has(item.id):
			list[index[item.id]] = res
		else:
			index[item.id] = list.size()
			list.append(res)
	db.set("items", list)
	var msg := Util.save_resource(db, path) if status == "created" else ""
	if status == "updated":
		var err := ResourceSaver.save(db, path)
		if err != OK:
			msg = "cannot save %s: %s" % [path, error_string(err)]
	if not msg.is_empty():
		return Util.error(Util.INTERNAL_ERROR, msg)
	return {"path": path, "status": status, "item_count": list.size(), "previous_entries": kept}


func _report(items: Array, mapping: Dictionary, header: PackedStringArray, skipped_rows: int, data_dir: String) -> Dictionary:
	var by_action := {"create": [], "update": [], "replace": [], "skip": []}
	for item in items:
		by_action[item.action].append(item.id)
	var columns := {}
	for i in mapping.by_index:
		columns[header[i].strip_edges()] = mapping.by_index[i]
	var extra_columns := []
	for i in mapping.extra:
		extra_columns.append(header[i].strip_edges())
	var out := {
		"item_count": items.size(),
		"data_dir": data_dir,
		"created": by_action.create,
		"updated": by_action.update,
		"replaced": by_action.replace,
		"skipped": by_action.skip,
		"columns": columns,
		"extra_columns": extra_columns,
		"ignored_columns": mapping.ignored,
		"blank_or_comment_rows": skipped_rows,
	}
	if not extra_columns.is_empty():
		out["note"] = "Columns with no matching property were stored in each item's 'extra' dictionary. Add an @export var with the same name to item_data.gd (or use column_map) to make them real properties."
	return out


static func _raw_text(params: Dictionary, key: String) -> Variant:
	if not params.has(key) or params[key] == null:
		return ""
	if not params[key] is String:
		return Util.error(Util.INVALID_PARAMS, "'%s' must be a string" % key)
	return params[key]


static func _column_map(params: Dictionary) -> Variant:
	if not params.has("column_map") or params.column_map == null:
		return {}
	if not params.column_map is Dictionary:
		return Util.error(Util.INVALID_PARAMS, "'column_map' must be an object of {\"CSV header\": \"property\"}")
	var out := {}
	for k in params.column_map:
		var v: Variant = params.column_map[k]
		if not (k is String and v is String):
			return Util.error(Util.INVALID_PARAMS, "'column_map' keys and values must be strings")
		out[String(k).strip_edges()] = String(v).strip_edges()
	return out


## Bytes of a set of files at one moment, written back by restore() (a
## file that did not exist is deleted). Held by the undo history.
class FileSnapshot extends RefCounted:
	var files := {}

	static func capture(paths: Array) -> FileSnapshot:
		var snap := FileSnapshot.new()
		for path in paths:
			snap.files[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
		return snap

	func restore() -> void:
		var changed: Array = []
		for path in files:
			var bytes: Variant = files[path]
			if bytes == null:
				if FileAccess.file_exists(path):
					DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
					changed.append(path)
				continue
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(String(path).get_base_dir()))
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				push_error("item_db_import undo: cannot write %s" % path)
				continue
			f.store_buffer(bytes)
			f.close()
			changed.append(path)
		## Paths keep capture order (items before the database), so the
		## database reload finds the items already restored.
		for path in changed:
			if FileAccess.file_exists(path) and ResourceLoader.has_cached(path):
				ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		Util.refresh_filesystem(changed)
