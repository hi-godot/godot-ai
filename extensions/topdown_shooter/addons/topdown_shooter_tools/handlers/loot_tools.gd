@tool
extends RefCounted

## loot_table_edit: creates or edits a drop table .tres (loot_table.gd),
## reports each item's drop chance (exact and simulated), and can hook the
## table to enemies or crates in the open scene with a LootDropper child
## that drops pickups when its parent emits `died`.
##
## Item ids are checked against the item database from item_db_import. The
## table is one undo step in the editor's global history (file bytes), the
## dropper nodes one undo step in the scene history.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")

const DEFAULT_LOOT_DIR := "res://data/loot"
const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_DROPPER_NAME := "LootDropper"
const MAX_ENTRIES := 500
const MAX_SIMULATE := 100000
const MAX_SAMPLES := 20
const ENTRY_KEYS := ["item_id", "category", "tag", "weight", "min_count", "max_count", "guaranteed"]


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func loot_table_edit(params: Dictionary, _ctx = null) -> Dictionary:
	var table_id: Variant = Util.text(params, "table_id", "")
	var data_dir: Variant = Util.text(params, "data_dir", DEFAULT_LOOT_DIR)
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var database_path: Variant = Util.text(params, "database_path", DEFAULT_DATABASE)
	var replace_entries: Variant = Util.boolean(params, "replace_entries", false)
	var allow_unknown: Variant = Util.boolean(params, "allow_unknown_items", false)
	var dry_run: Variant = Util.boolean(params, "dry_run", false)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	var simulate: Variant = Util.integer(params, "simulate", 1000, 0, MAX_SIMULATE)
	var samples: Variant = Util.integer(params, "samples", 5, 0, MAX_SAMPLES)
	var seed_value: Variant = Util.integer(params, "seed", -1, -1, 2147483647)
	var attach_group: Variant = Util.text(params, "attach_to_group", "")
	var trigger_signal: Variant = Util.text(params, "trigger_signal", "died")
	var dropper_name: Variant = Util.text(params, "dropper_name", DEFAULT_DROPPER_NAME)
	for v in [table_id, data_dir, script_dir, database_path, replace_entries, allow_unknown, dry_run, overwrite_scripts, simulate, samples, seed_value, attach_group, trigger_signal, dropper_name]:
		if Util.is_error(v):
			return v
	if String(table_id).is_empty():
		return Util.error(Util.INVALID_PARAMS, "'table_id' is required (e.g. \"grunt\" or \"medical_crate\")")
	if not ItemTools._is_id(table_id):
		return Util.error(Util.INVALID_PARAMS, "'table_id' must be lower_snake_case letters, digits and underscores")
	if not String(dropper_name).is_valid_identifier():
		return Util.error(Util.INVALID_PARAMS, "'dropper_name' must be a plain node name like LootDropper")
	var remove_items: Variant = _string_list(params, "remove_items")
	var attach_to: Variant = _string_list(params, "attach_to")
	for v in [remove_items, attach_to]:
		if Util.is_error(v):
			return v
	var settings := {}
	for spec in [["rolls_min", 0, 100], ["rolls_max", 0, 100]]:
		if params.has(spec[0]) and params[spec[0]] != null:
			var v: Variant = Util.integer(params, spec[0], 1, spec[1], spec[2])
			if Util.is_error(v):
				return v
			settings[spec[0]] = v
	if params.has("empty_weight") and params.empty_weight != null:
		var v: Variant = Util.num(params, "empty_weight", 0.0, 0.0, 1e9)
		if Util.is_error(v):
			return v
		settings["empty_weight"] = v
	var new_entries: Variant = _parse_entries(params)
	if Util.is_error(new_entries):
		return new_entries

	data_dir = Util.clean_dir(data_dir)
	script_dir = Util.clean_dir(script_dir)
	var table_path: String = data_dir + "/" + table_id + ".tres"
	var reason := Util.check_res_path(table_path, "tres")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)
	var table_script_path: String = script_dir + "/loot_table.gd"
	var dropper_script_path: String = script_dir + "/loot_dropper.gd"
	var pickup_script_path: String = script_dir + "/loot_pickup.gd"

	## --- current table and item database --------------------------------------
	var existing: Resource = null
	if FileAccess.file_exists(table_path):
		existing = ResourceLoader.load(table_path)
		var script := existing.get_script() as Script if existing != null else null
		if script == null or script.resource_path != table_script_path:
			return Util.error(Util.INVALID_PARAMS, "%s is not a loot table made with %s; pick another table_id or data_dir" % [table_path, table_script_path])
	var db: Variant = _read_database(database_path)
	if Util.is_error(db):
		return db
	if db.items.is_empty() and not allow_unknown:
		return Util.error(Util.NODE_NOT_FOUND, "no item database at %s; import items with item_db_import first, pass database_path, or allow_unknown_items=true" % database_path)

	var edits: bool = existing == null or replace_entries or not new_entries.is_empty() or not remove_items.is_empty() or not settings.is_empty()
	var table := {
		"rolls_min": 1,
		"rolls_max": 1,
		"empty_weight": 0.0,
		"entries": [],
	}
	if existing != null:
		table.rolls_min = int(existing.get("rolls_min"))
		table.rolls_max = int(existing.get("rolls_max"))
		table.empty_weight = float(existing.get("empty_weight"))
		if not replace_entries:
			for e in existing.get("entries"):
				table.entries.append(_normalized(e))
	table.merge(settings, true)
	if int(table.rolls_min) > int(table.rolls_max):
		return Util.error(Util.INVALID_PARAMS, "rolls_min (%d) is above rolls_max (%d)" % [table.rolls_min, table.rolls_max])

	## --- apply removals and upserts --------------------------------------------
	var warnings: Array[String] = []
	var removed: Array[String] = []
	for id in remove_items:
		var idx := _index_of(table.entries, id)
		if idx < 0:
			warnings.append("remove_items: '%s' is not in the table" % id)
		else:
			table.entries.remove_at(idx)
			removed.append(id)
	var unknown: Array[String] = []
	var added: Array[String] = []
	var changed: Array[String] = []
	for spec in new_entries:
		var ids: Array[String] = []
		if spec.has("item_id"):
			ids.append(spec.item_id)
			if not db.items.has(spec.item_id):
				unknown.append(spec.item_id)
		else:
			ids = _match_items(db.items, spec)
			if ids.is_empty():
				return Util.error(Util.INVALID_PARAMS, "no item in %s has %s '%s'" % [database_path, "category" if spec.has("category") else "tag", spec.get("category", spec.get("tag"))])
		for id in ids:
			var entry := {"item_id": id, "weight": spec.weight, "min": spec.min, "max": spec.max, "guaranteed": spec.guaranteed}
			var idx := _index_of(table.entries, id)
			if idx < 0:
				table.entries.append(entry)
				added.append(id)
			else:
				## A later entry for the same item wins; report it once.
				table.entries[idx] = entry
				if id not in added and id not in changed:
					changed.append(id)
	if not unknown.is_empty() and not allow_unknown:
		return Util.error(Util.INVALID_PARAMS, "not in the item database (%s): %s. Fix the ids, import the items first, or pass allow_unknown_items=true" % [database_path, ", ".join(unknown)])
	if table.entries.size() > MAX_ENTRIES:
		return Util.error(Util.INVALID_PARAMS, "a table holds at most %d entries" % MAX_ENTRIES)
	if table.entries.is_empty():
		return Util.error(Util.INVALID_PARAMS, "the table would have no entries; give 'entries' like [{\"item_id\": \"bandage\", \"weight\": 10}]")
	for id in unknown:
		warnings.append("'%s' is not in the item database; it drops with no item resource" % id)
	if _pool(table) <= 0.0 and int(table.rolls_max) > 0 and not _has_guaranteed(table):
		warnings.append("every weight is 0, so the rolls never drop anything")

	## --- attach targets (resolved before anything is written) ------------------
	var targets: Variant = _attach_targets(attach_to, attach_group, warnings)
	if Util.is_error(targets):
		return targets

	## --- odds and simulation ---------------------------------------------------
	var odds := chances(table)
	var table_script: Variant = _table_script(table_script_path, overwrite_scripts or not FileAccess.file_exists(table_script_path))
	if Util.is_error(table_script):
		return table_script
	var sim: Variant = _simulate(table_script, table, simulate, samples, seed_value)
	if Util.is_error(sim):
		return sim

	var report := {
		"table_id": table_id,
		"path": table_path,
		"status": _status(existing == null, edits, dry_run),
		"rolls": [table.rolls_min, table.rolls_max],
		"empty_weight": table.empty_weight,
		"total_weight": _pool(table),
		"added": added,
		"changed": changed,
		"removed": removed,
		"entries": _entry_report(table, odds, sim),
		"nothing_chance_percent": _pct(odds.nothing),
		"database": database_path if not db.items.is_empty() else "",
		"warnings": warnings,
	}
	if simulate > 0:
		report["simulation"] = {
			"runs": simulate,
			"seed": sim.seed,
			"nothing_percent": _pct(float(sim.nothing) / simulate),
			"average_items_per_drop": snappedf(float(sim.total_items) / simulate, 0.01),
			"samples": sim.samples,
		}
	if dry_run:
		report["dry_run"] = true
		if not targets.is_empty():
			report["would_attach"] = _paths(targets)
		return {"data": report}

	## --- write the table -------------------------------------------------------
	var installed := {}
	for pair in [["loot_table.gd.tmpl", table_script_path], ["loot_dropper.gd.tmpl", dropper_script_path], ["loot_pickup.gd.tmpl", pickup_script_path]]:
		if pair[1] != table_script_path and targets.is_empty():
			continue
		var s := Util.install_script(pair[0], pair[1], overwrite_scripts)
		if Util.is_error(s):
			return s
		installed[pair[1]] = s
	var scripts_report := {}
	for path in installed:
		scripts_report[path] = installed[path].status
	report["scripts"] = scripts_report

	var res: Resource = existing
	if edits:
		var before := ItemTools.FileSnapshot.capture([table_path])
		if res == null:
			res = Resource.new()
			res.set_script(installed[table_script_path].script)
		res.set("table_id", table_id)
		if not db.items.is_empty():
			res.set("item_database", ResourceLoader.load(database_path))
		res.set("rolls_min", table.rolls_min)
		res.set("rolls_max", table.rolls_max)
		res.set("empty_weight", table.empty_weight)
		var typed: Array[Dictionary] = []
		for e in table.entries:
			typed.append(e.duplicate())
		res.set("entries", typed)
		var msg := ""
		if existing == null:
			msg = Util.save_resource(res, table_path)
		else:
			var err := ResourceSaver.save(res, table_path)
			if err != OK:
				msg = "cannot save %s: %s" % [table_path, error_string(err)]
		if not msg.is_empty():
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, msg)
		var after := ItemTools.FileSnapshot.capture([table_path])
		var ur := EditorInterface.get_editor_undo_redo() if Engine.is_editor_hint() else null
		if ur != null:
			ur.create_action("Edit loot table %s" % table_id, UndoRedo.MERGE_DISABLE, null, false, false)
			ur.add_do_method(after, "restore")
			ur.add_undo_method(before, "restore")
			ur.commit_action(false)
			report["undo"] = "Edit > Undo restores the table file as it was."
	Util.refresh_filesystem([table_path] + installed.keys())

	## --- attach droppers -------------------------------------------------------
	if not targets.is_empty():
		var attached: Variant = _attach(targets, res, installed, dropper_script_path, pickup_script_path, trigger_signal, dropper_name, table_id)
		if Util.is_error(attached):
			return attached
		report["attached"] = attached.paths
		report["warnings"].append_array(attached.warnings)
		if report.has("undo"):
			report["undo"] += " Removing the droppers is a separate scene undo step."
		else:
			report["undo"] = "Edit > Undo removes the droppers."
	return {"data": report}


# =============================================================================
# params
# =============================================================================

func _parse_entries(params: Dictionary) -> Variant:
	if not params.has("entries") or params.entries == null:
		return []
	if not params.entries is Array:
		return Util.error(Util.INVALID_PARAMS, "'entries' must be an array of {item_id, weight, min_count, max_count, guaranteed}")
	var out: Array = []
	for i in params.entries.size():
		var raw: Variant = params.entries[i]
		var where := "entries[%d]" % i
		if not raw is Dictionary:
			return Util.error(Util.INVALID_PARAMS, "%s must be an object" % where)
		for k in raw:
			if String(k) not in ENTRY_KEYS:
				return Util.error(Util.INVALID_PARAMS, "%s has unknown key '%s' (use %s)" % [where, k, ", ".join(ENTRY_KEYS)])
		var keys := 0
		var spec := {}
		for k in ["item_id", "category", "tag"]:
			if raw.has(k) and raw[k] != null:
				if not raw[k] is String or String(raw[k]).strip_edges().is_empty():
					return Util.error(Util.INVALID_PARAMS, "%s.%s must be a non-empty string" % [where, k])
				spec[k] = String(raw[k]).strip_edges()
				keys += 1
		if keys != 1:
			return Util.error(Util.INVALID_PARAMS, "%s needs exactly one of item_id, category or tag" % where)
		if spec.has("item_id"):
			spec.item_id = spec.item_id.to_lower().replace(" ", "_").replace("-", "_")
			if not ItemTools._is_id(spec.item_id):
				return Util.error(Util.INVALID_PARAMS, "%s.item_id '%s' must be letters, digits and underscores" % [where, raw.item_id])
		var guaranteed: Variant = Util.boolean(raw, "guaranteed", false)
		var weight: Variant = Util.num(raw, "weight", 1.0, 0.0, 1e9)
		var lo: Variant = Util.integer(raw, "min_count", 1, 0, 1000000)
		for v in [guaranteed, weight, lo]:
			if Util.is_error(v):
				v.error.message = where + ": " + v.error.message
				return v
		var hi: Variant = Util.integer(raw, "max_count", lo, 0, 1000000)
		if Util.is_error(hi):
			hi.error.message = where + ": " + hi.error.message
			return hi
		if hi < lo:
			return Util.error(Util.INVALID_PARAMS, "%s: max_count (%d) is below min_count (%d)" % [where, hi, lo])
		spec.weight = 0.0 if guaranteed else weight
		spec.min = lo
		spec.max = hi
		spec.guaranteed = guaranteed
		out.append(spec)
	return out


static func _string_list(params: Dictionary, key: String) -> Variant:
	if not params.has(key) or params[key] == null:
		return [] as Array[String]
	var raw: Variant = params[key]
	if raw is String:
		raw = [raw]
	if not raw is Array:
		return Util.error(Util.INVALID_PARAMS, "'%s' must be an array of strings" % key)
	var out: Array[String] = []
	for v in raw:
		if not v is String or String(v).strip_edges().is_empty():
			return Util.error(Util.INVALID_PARAMS, "'%s' must be an array of non-empty strings" % key)
		out.append(String(v).strip_edges())
	return out


static func _normalized(e: Variant) -> Dictionary:
	var d: Dictionary = e if e is Dictionary else {}
	var lo := int(d.get("min", 1))
	return {
		"item_id": String(d.get("item_id", "")),
		"weight": float(d.get("weight", 1.0)),
		"min": lo,
		"max": int(d.get("max", lo)),
		"guaranteed": bool(d.get("guaranteed", false)),
	}


static func _index_of(entries: Array, id: String) -> int:
	for i in entries.size():
		if entries[i].item_id == id:
			return i
	return -1


# =============================================================================
# item database
# =============================================================================

## Reads the database's stored item list (works without running its script,
## which the editor keeps as a placeholder). Returns {"items": {id: {category,
## tags}}} — empty when the file does not exist.
static func _read_database(path: String) -> Variant:
	var out := {"items": {}}
	if path.is_empty() or not FileAccess.file_exists(path):
		return out
	var db := ResourceLoader.load(path)
	if db == null or not db.get("items") is Array:
		return Util.error(Util.INVALID_PARAMS, "%s is not an item database (no 'items' list)" % path)
	for item in db.get("items"):
		if item == null:
			continue
		var id := String(item.get("item_id"))
		if id.is_empty():
			continue
		var tags := PackedStringArray()
		if item.get("tags") != null:
			for t in item.get("tags"):
				tags.append(String(t))
		out.items[id] = {"category": String(item.get("category")), "tags": tags}
	return out


static func _match_items(items: Dictionary, spec: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for id in items:
		var info: Dictionary = items[id]
		if spec.has("category") and info.category.to_lower() == String(spec.category).to_lower():
			out.append(id)
		elif spec.has("tag") and info.tags.has(spec.tag):
			out.append(id)
	out.sort()
	return out


# =============================================================================
# odds
# =============================================================================

static func _pool(table: Dictionary) -> float:
	var total := maxf(float(table.empty_weight), 0.0)
	for e in table.entries:
		if not e.guaranteed:
			total += maxf(float(e.weight), 0.0)
	return total


static func _has_guaranteed(table: Dictionary) -> bool:
	for e in table.entries:
		if e.guaranteed and int(e.max) > 0:
			return true
	return false


## Exact odds per drop. Returns {"per_item": {id: {roll, drop, expected}},
## "nothing": chance}. A drop rolls r times, r uniform in rolls_min..rolls_max;
## each roll picks an entry with probability weight / total weight.
static func chances(table: Dictionary) -> Dictionary:
	var pool := _pool(table)
	var lo := mini(int(table.rolls_min), int(table.rolls_max))
	var hi := maxi(int(table.rolls_min), int(table.rolls_max))
	var roll_counts := range(lo, hi + 1)
	var mean_rolls := (lo + hi) / 2.0
	var per_item := {}
	var q := 1.0 if pool <= 0.0 else maxf(float(table.empty_weight), 0.0) / pool
	var guaranteed_zero := 1.0
	for e in table.entries:
		var spread := int(e.max) - int(e.min) + 1
		var zero := 1.0 / spread if int(e.min) == 0 else 0.0
		var mean_count := (int(e.min) + int(e.max)) / 2.0
		if e.guaranteed:
			per_item[e.item_id] = {"roll": 1.0, "drop": 1.0 - zero, "expected": mean_count}
			guaranteed_zero *= zero
			continue
		var p := 0.0 if pool <= 0.0 else maxf(float(e.weight), 0.0) / pool
		var p_some := p * (1.0 - zero)
		q += p * zero
		var drop := 0.0
		for r in roll_counts:
			drop += 1.0 - pow(1.0 - p_some, r)
		drop /= roll_counts.size()
		per_item[e.item_id] = {"roll": p, "drop": drop, "expected": mean_rolls * p * mean_count}
	var nothing := 0.0
	for r in roll_counts:
		nothing += pow(q, r)
	nothing = nothing / roll_counts.size() * guaranteed_zero
	return {"per_item": per_item, "nothing": nothing}


## Compiles a @tool copy of the project's loot_table.gd (or the template
## when it is not installed yet) so its roll() can run inside the editor.
func _table_script(path: String, use_template: bool) -> Variant:
	var source := FileAccess.get_file_as_string(Util.TEMPLATE_DIR + "loot_table.gd.tmpl" if use_template else path)
	if not source.contains("@tool"):
		source = "@tool\n" + source
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return Util.error(Util.INTERNAL_ERROR, "%s does not compile; fix it or pass overwrite_scripts=true" % path)
	return script


func _simulate(script: GDScript, table: Dictionary, runs: int, samples: int, seed_value: int) -> Variant:
	var out := {"counts": {}, "hits": {}, "nothing": 0, "total_items": 0, "samples": [], "seed": seed_value}
	if runs <= 0:
		return out
	var t: Resource = Resource.new()
	t.set_script(script)
	if not t.has_method("roll"):
		return Util.error(Util.INTERNAL_ERROR, "loot_table.gd has no roll() method; restore it or pass overwrite_scripts=true")
	t.set("rolls_min", table.rolls_min)
	t.set("rolls_max", table.rolls_max)
	t.set("empty_weight", table.empty_weight)
	var typed: Array[Dictionary] = []
	for e in table.entries:
		typed.append(e.duplicate())
	t.set("entries", typed)
	var rng := RandomNumberGenerator.new()
	if seed_value < 0:
		rng.randomize()
		out.seed = rng.randi() & 0x7fffffff
	rng.seed = out.seed
	for i in runs:
		var drops: Array = t.roll(rng)
		if drops.is_empty():
			out.nothing += 1
		var line: Array[String] = []
		for d in drops:
			var id := String(d.item_id)
			out.counts[id] = out.counts.get(id, 0) + int(d.count)
			out.hits[id] = out.hits.get(id, 0) + 1
			out.total_items += int(d.count)
			line.append(id if int(d.count) == 1 else "%s x%d" % [id, d.count])
		if out.samples.size() < samples:
			out.samples.append(", ".join(line) if not line.is_empty() else "(nothing)")
	out["runs"] = runs
	return out


func _entry_report(table: Dictionary, odds: Dictionary, sim: Dictionary) -> Array:
	var out := []
	var runs := int(sim.get("runs", 0))
	for e in table.entries:
		var o: Dictionary = odds.per_item[e.item_id]
		var row := {
			"item_id": e.item_id,
			"weight": e.weight,
			"count": [e.min, e.max],
			"guaranteed": e.guaranteed,
			"roll_percent": _pct(o.roll),
			"drop_percent": _pct(o.drop),
			"expected_count": snappedf(o.expected, 0.001),
		}
		if runs > 0:
			row["simulated_drop_percent"] = _pct(float(sim.hits.get(e.item_id, 0)) / runs)
			row["simulated_avg_count"] = snappedf(float(sim.counts.get(e.item_id, 0)) / runs, 0.001)
		out.append(row)
	return out


static func _status(is_new: bool, edits: bool, dry_run: bool) -> String:
	if not edits:
		return "unchanged"
	var verb := "create" if is_new else "update"
	return "would " + verb if dry_run else verb + "d"


static func _pct(x: float) -> float:
	return snappedf(x * 100.0, 0.01)


# =============================================================================
# droppers
# =============================================================================

func _attach_targets(paths: Array[String], group: String, warnings: Array[String]) -> Variant:
	var out: Array[Node] = []
	if paths.is_empty() and group.is_empty():
		return out
	var root := Util.edited_root()
	if root == null:
		return Util.no_scene_error()
	for p in paths:
		var node := Util.resolve(p, root)
		if node == null:
			return Util.error(Util.NODE_NOT_FOUND, "attach_to '%s' not found in the edited scene" % p)
		if not node is Node3D:
			return Util.error(Util.INVALID_PARAMS, "attach_to '%s' is a %s; a dropper needs a 3D parent" % [p, node.get_class()])
		if node not in out:
			out.append(node)
	if not group.is_empty():
		var found := 0
		for node in root.get_tree().get_nodes_in_group(group):
			if (node == root or root.is_ancestor_of(node)) and node is Node3D and node not in out:
				out.append(node)
				found += 1
		if found == 0:
			warnings.append("no 3D node in group '%s' in the open scene" % group)
	return out


func _attach(targets: Array, table: Resource, installed: Dictionary, dropper_path: String, pickup_path: String, trigger_signal: String, dropper_name: String, table_id: String) -> Variant:
	var root := Util.edited_root()
	var dropper_script: Script = installed[dropper_path].script
	var items := []
	var props := []
	var paths := []
	var warnings: Array[String] = []
	for target in targets:
		if trigger_signal != "" and not _has_signal(target, trigger_signal):
			warnings.append("%s has no '%s' signal; call its %s.drop() yourself (e.g. when a crate opens)" % [Util.scene_path_of(target, root), trigger_signal, dropper_name])
		var current: Node = null
		for child in target.get_children():
			var s := child.get_script() as Script
			if s != null and s.resource_path == dropper_path:
				current = child
				break
		if current != null:
			for change in [["loot_table", table], ["trigger_signal", StringName(trigger_signal)], ["pickup_script_path", pickup_path]]:
				props.append([current, change[0], change[1], current.get(change[0])])
			paths.append(Util.scene_path_of(current, root) + " (updated)")
			continue
		var dropper := Node3D.new()
		dropper.name = Util.unique_child_name(target, dropper_name)
		dropper.set_script(dropper_script)
		dropper.set("loot_table", table)
		dropper.set("trigger_signal", StringName(trigger_signal))
		dropper.set("pickup_script_path", pickup_path)
		items.append([target, dropper])
	if not items.is_empty() or not props.is_empty():
		var label := "Attach loot table %s" % table_id
		if items.is_empty():
			var ur := EditorInterface.get_editor_undo_redo()
			ur.create_action(label, UndoRedo.MERGE_DISABLE, root)
			for t in props:
				ur.add_do_property(t[0], t[1], t[2])
				ur.add_undo_property(t[0], t[1], t[3])
			ur.commit_action()
		else:
			Util.add_nodes_to_scene(label, items, root, props)
	for item in items:
		paths.append(Util.scene_path_of(item[1], root))
	return {"paths": paths, "warnings": warnings}


static func _has_signal(node: Node, sig: String) -> bool:
	if ClassDB.class_has_signal(node.get_class(), sig):
		return true
	var script := node.get_script() as Script
	while script != null:
		if script.has_script_signal(sig):
			return true
		script = script.get_base_script()
	return false


static func _paths(nodes: Array) -> Array:
	var root := Util.edited_root()
	var out := []
	for n in nodes:
		out.append(Util.scene_path_of(n, root))
	return out
