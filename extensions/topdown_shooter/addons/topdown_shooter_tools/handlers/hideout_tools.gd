@tool
extends RefCounted

## Handler for hideout_scaffold: closes the raid loop.
##
## Writes a hideout scene (hideout.gd: a stash grid and a raid bag grid,
## both inventory.gd nodes, plus a 출격 button) and registers the
## HideoutState autoload (hideout_state.gd), which keeps the stash, the bag
## and the stats in a user:// JSON save and switches scenes:
## hideout -> raid (bag becomes the player's inventory) -> extracted (bag
## goes home into the stash) or died (bag is lost) -> hideout.
##
## Nothing in the raid scene is edited: the autoload finds the player, its
## Inventory and the extraction zones by group at run time. The scene file
## and the Project Settings changes (autoload, game/hideout/* settings,
## main scene) are one undo step in the editor's global history.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const LootTools := preload("res://addons/topdown_shooter_tools/handlers/loot_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_SCENE := "res://scenes/hideout.tscn"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_SAVE := "user://hideout/save.json"
const AUTOLOAD_NAME := "HideoutState"
const SETTINGS_PREFIX := "game/hideout/"
const MAIN_SCENE_KEY := "application/run/main_scene"
## inventory.gd defaults, for raid inventories that do not override them.
const BAG_DEFAULTS := {"grid_width": 6, "grid_height": 8, "max_weight": 40.0, "allow_rotation": true}


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func hideout_scaffold(params: Dictionary, _ctx = null) -> Dictionary:
	var p: Variant = read_params(params)
	if Util.is_error(p):
		return p
	var warnings: Array[String] = []

	## --- raid scene ---------------------------------------------------------------
	var raid_scene: Variant = _resolve_raid_scene(p.raid_scene)
	if Util.is_error(raid_scene):
		return raid_scene
	if raid_scene == p.hideout_scene:
		return Util.error(Util.INVALID_PARAMS, "raid_scene and hideout_scene are the same file (%s)" % raid_scene)
	var raid := inspect_scene(raid_scene)
	if raid.extractions == 0:
		warnings.append("%s has no extraction zone (raid_extraction.gd): a raid can only end by dying. Add one with raid_map_blockout" % raid_scene)
	if not raid.player:
		warnings.append("%s has no player_controller.gd player: the bag and death cannot be tracked" % raid_scene)
	if raid.inventory.is_empty():
		warnings.append("the raid player has no Inventory (inventory_ui_scaffold): nothing can be carried home")

	## --- bag size (from the raid player's inventory unless given) ----------------
	var bag := BAG_DEFAULTS.duplicate()
	var bag_source := "default"
	if not raid.inventory.is_empty():
		bag_source = "raid player's Inventory"
		for k in BAG_DEFAULTS:
			if raid.inventory.has(k):
				bag[k] = raid.inventory[k]
	for k in ["grid_width", "grid_height", "max_weight"]:
		if params.has("loadout_" + k) and params["loadout_" + k] != null:
			bag[k] = p["loadout_" + k]
			bag_source = "params"

	## --- item database and starting stash -----------------------------------------
	var db: Variant = LootTools._read_database(p.database_path)
	if Util.is_error(db):
		return db
	if db.items.is_empty():
		warnings.append("no item database at %s: saved items cannot be loaded back (import items with item_db_import)" % p.database_path)
	var starting: Variant
	var starting_source := "params"
	if params.has("starting_stash") and params.starting_stash != null:
		starting = InventoryTools.new()._parse_starting({"starting_items": params.starting_stash}, db, p.database_path)
		if Util.is_error(starting):
			starting.error.message = starting.error.message.replace("starting_items", "starting_stash")
			return starting
	elif ProjectSettings.has_setting(SETTINGS_PREFIX + "starting_stash"):
		starting = ProjectSettings.get_setting(SETTINGS_PREFIX + "starting_stash")
		starting_source = "kept"
	else:
		starting = []
		for s in raid.inventory.get("starting_items", []):
			if s is Dictionary and db.items.has(str(s.get("item_id", ""))):
				starting.append({"item_id": str(s.item_id), "count": int(s.get("count", 1))})
		starting_source = "raid player's starting_items" if not starting.is_empty() else "none"

	## --- paths --------------------------------------------------------------------
	var script_dir: String = p.script_dir
	var paths := {
		"inventory": script_dir + "/inventory.gd",
		"hideout": script_dir + "/hideout.gd",
		"state": script_dir + "/hideout_state.gd",
	}
	var scene_exists := FileAccess.file_exists(p.hideout_scene)
	var write_scene: bool = not scene_exists or p.overwrite
	if scene_exists and not p.overwrite:
		warnings.append("%s exists and was kept: stash and bag sizes, title and cell size were not changed (overwrite=true rebuilds it)" % p.hideout_scene)
	if write_scene and Engine.is_editor_hint() and EditorInterface.get_open_scenes().has(p.hideout_scene):
		return Util.error(Util.INVALID_PARAMS, "%s is open in the editor; close it before rebuilding it" % p.hideout_scene)

	var settings := {
		"autoload/" + AUTOLOAD_NAME: "*" + paths.state,
		SETTINGS_PREFIX + "hideout_scene": p.hideout_scene,
		SETTINGS_PREFIX + "raid_scene": raid_scene,
		SETTINGS_PREFIX + "save_path": p.save_path,
		SETTINGS_PREFIX + "item_database": p.database_path,
		SETTINGS_PREFIX + "return_delay": p.return_delay,
		SETTINGS_PREFIX + "quit_counts_as_death": p.quit_counts_as_death,
		SETTINGS_PREFIX + "track_direct_raids": p.track_direct_raids,
		SETTINGS_PREFIX + "starting_stash": starting,
	}
	var old_main := str(ProjectSettings.get_setting(MAIN_SCENE_KEY, ""))
	if p.set_main_scene:
		settings[MAIN_SCENE_KEY] = p.hideout_scene

	var report := {
		"hideout_scene": p.hideout_scene,
		"raid_scene": raid_scene,
		"stash": {"grid": [p.stash_width, p.stash_height], "max_weight": 0},
		"loadout": {"grid": [int(bag.grid_width), int(bag.grid_height)], "max_weight": float(bag.max_weight), "from": bag_source},
		"raid_check": {"extraction_zones": raid.extractions, "player": raid.player, "inventory": not raid.inventory.is_empty()},
		"starting_stash": starting,
		"starting_stash_from": starting_source,
		"save_path": p.save_path,
		"save_file": ProjectSettings.globalize_path(p.save_path),
		"autoload": AUTOLOAD_NAME,
		"main_scene": {"before": old_main, "after": p.hideout_scene if p.set_main_scene else old_main},
		"warnings": warnings,
	}
	if p.dry_run:
		report["dry_run"] = true
		report["would"] = {"hideout_scene": ("overwrite" if p.overwrite else "keep") if scene_exists else "create"}
		return {"data": report}

	## --- scripts ------------------------------------------------------------------
	var installed := {}
	for pair in [["inventory.gd.tmpl", paths.inventory, false], ["hideout.gd.tmpl", paths.hideout, p.overwrite_scripts], ["hideout_state.gd.tmpl", paths.state, p.overwrite_scripts]]:
		var s := Util.install_script(pair[0], pair[1], pair[2])
		if Util.is_error(s):
			return s
		installed[pair[1]] = s
	Util.refresh_filesystem(installed.keys())
	var statuses := {}
	for k in installed:
		statuses[k] = installed[k].status
	report["scripts"] = statuses

	## --- hideout scene ------------------------------------------------------------
	var before := ItemTools.FileSnapshot.capture([p.hideout_scene])
	if write_scene:
		var root := build_hideout(p, bag, installed[paths.hideout].script, installed[paths.inventory].script)
		var msg := Util.save_scene(root, p.hideout_scene)
		if not msg.is_empty():
			return Util.error(Util.INTERNAL_ERROR, msg)
		Util.refresh_filesystem([p.hideout_scene])
	report["hideout_scene_status"] = ("overwritten" if scene_exists else "created") if write_scene else "kept"
	var after := ItemTools.FileSnapshot.capture([p.hideout_scene])

	## --- project settings (one undo step with the scene file) ----------------------
	var previous := {}
	for key in settings:
		previous[key] = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var ur := EditorInterface.get_editor_undo_redo() if Engine.is_editor_hint() else null
	if ur != null:
		ur.create_action("Hideout scaffold", UndoRedo.MERGE_DISABLE, ProjectSettings)
		for key in settings:
			ur.add_do_method(ProjectSettings, &"set_setting", key, settings[key])
			ur.add_undo_method(ProjectSettings, &"set_setting", key, previous[key])
		ur.add_do_method(ProjectSettings, &"save")
		ur.add_undo_method(ProjectSettings, &"save")
		if write_scene:
			ur.add_do_method(after, &"restore")
			ur.add_undo_method(before, &"restore")
		ur.commit_action()
	else:
		for key in settings:
			ProjectSettings.set_setting(key, settings[key])
		ProjectSettings.save()
	if ProjectSettings.get_setting("autoload/" + AUTOLOAD_NAME, null) != settings["autoload/" + AUTOLOAD_NAME]:
		return Util.error(Util.INTERNAL_ERROR, "could not register the %s autoload in project.godot" % AUTOLOAD_NAME)

	report["flow"] = "%s(창고·가방) -> 출격 -> %s -> 탈출하면 가방 전체가 창고로 / 죽으면 가방을 잃음 -> %s초 뒤 은신처" % [p.hideout_scene.get_file(), raid_scene.get_file(), p.return_delay]
	report["controls"] = "드래그: 이동(창고↔가방), R: 회전, 우클릭: 반대편으로 보내기, Shift+클릭: 나누기, 출격 버튼"
	report["undo"] = "Edit > Undo removes the autoload and settings%s and restores the main scene. Copied scripts stay." % (" and the hideout scene" if write_scene else "")
	return {"data": report}


# =============================================================================
# params
# =============================================================================

static func read_params(params: Dictionary) -> Variant:
	var allowed := [
		"raid_scene", "hideout_scene", "stash_width", "stash_height", "loadout_grid_width",
		"loadout_grid_height", "loadout_max_weight", "starting_stash", "save_path", "return_delay",
		"quit_counts_as_death", "track_direct_raids", "set_main_scene", "title", "cell_size",
		"database_path", "script_dir", "overwrite", "overwrite_scripts", "dry_run",
	]
	for key in params:
		if not allowed.has(key):
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s'" % key)
	var p := {}
	var specs := [
		["stash_width", "int", 10, 1, 64],
		["stash_height", "int", 14, 1, 200],
		["loadout_grid_width", "int", 6, 1, 64],
		["loadout_grid_height", "int", 8, 1, 64],
		["cell_size", "int", 44, 24, 128],
		["loadout_max_weight", "num", 40.0, 0.0, 100000.0],
		["return_delay", "num", 3.0, 0.0, 60.0],
		["quit_counts_as_death", "bool", true],
		["track_direct_raids", "bool", true],
		["set_main_scene", "bool", true],
		["overwrite", "bool", false],
		["overwrite_scripts", "bool", false],
		["dry_run", "bool", false],
		["raid_scene", "text", ""],
		["hideout_scene", "text", DEFAULT_SCENE],
		["save_path", "text", DEFAULT_SAVE],
		["title", "text", "은신처"],
		["database_path", "text", DEFAULT_DATABASE],
		["script_dir", "text", DEFAULT_SCRIPT_DIR],
	]
	for s in specs:
		var value: Variant
		match s[1]:
			"num":
				value = Util.num(params, s[0], s[2], s[3], s[4])
			"int":
				value = Util.integer(params, s[0], s[2], s[3], s[4])
			"bool":
				value = Util.boolean(params, s[0], s[2])
			_:
				value = Util.text(params, s[0], s[2])
		if Util.is_error(value):
			return value
		p[s[0]] = value
	p.script_dir = Util.clean_dir(p.script_dir)
	var reason := Util.check_res_path(p.script_dir + "/x.gd", "gd")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'script_dir': " + reason)
	reason = Util.check_res_path(p.hideout_scene, "tscn")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'hideout_scene': " + reason)
	if not p.raid_scene.is_empty() and (not p.raid_scene.begins_with("res://") or p.raid_scene.get_extension() not in ["tscn", "scn"]):
		return Util.error(Util.INVALID_PARAMS, "'raid_scene' must be a res:// .tscn path, got '%s'" % p.raid_scene)
	var save: String = p.save_path
	if not save.begins_with("user://") or save.contains("..") or save.contains("\\") or save.get_extension() != "json" or save.get_file().get_basename().is_empty():
		return Util.error(Util.INVALID_PARAMS, "'save_path' must be a user:// .json path (e.g. user://hideout/save.json), got '%s'" % save)
	if p.title.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'title' must not be empty")
	return p


func _resolve_raid_scene(wanted: String) -> Variant:
	if not wanted.is_empty():
		if not ResourceLoader.exists(wanted):
			return Util.error(Util.NODE_NOT_FOUND, "raid_scene %s does not exist" % wanted)
		return wanted
	var candidates: Array[String] = []
	var root := Util.edited_root()
	if root != null and not root.scene_file_path.is_empty():
		candidates.append(root.scene_file_path)
	var main := str(ProjectSettings.get_setting(MAIN_SCENE_KEY, ""))
	if not main.is_empty() and main.begins_with("res://"):
		candidates.append(main)
	var previous := str(ProjectSettings.get_setting(SETTINGS_PREFIX + "raid_scene", ""))
	if not previous.is_empty():
		candidates.append(previous)
	for path in candidates:
		if ResourceLoader.exists(path) and int(inspect_scene(path).extractions) > 0:
			return path
	return Util.error(Util.INVALID_PARAMS, "no raid scene: open the raid scene (one with extraction zones from raid_map_blockout) or pass raid_scene")


# =============================================================================
# raid scene inspection (no instancing: SceneState only)
# =============================================================================

## Counts extraction zones, finds the player controller and reads the
## player's Inventory settings from a scene file (and the scenes it
## instances). Returns {"extractions", "player", "inventory": {...}}.
static func inspect_scene(path: String) -> Dictionary:
	var out := {"extractions": 0, "player": false, "inventory": {}}
	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed != null:
		_scan_state(packed.get_state(), out, 0)
	return out


static func _scan_state(state: SceneState, out: Dictionary, depth: int) -> void:
	if state == null or depth > 4:
		return
	for i in state.get_node_count():
		var props := {}
		for j in state.get_node_property_count(i):
			props[state.get_node_property_name(i, j)] = state.get_node_property_value(i, j)
		var script: Variant = props.get("script")
		var file := (script as Script).resource_path.get_file() if script is Script else ""
		match file:
			"raid_extraction.gd":
				out.extractions = int(out.extractions) + 1
			"player_controller.gd":
				out.player = true
			"inventory.gd":
				if out.inventory.is_empty():
					var inv := {}
					for k in ["grid_width", "grid_height", "max_weight", "allow_rotation", "starting_items"]:
						if props.has(k):
							inv[k] = props[k]
					inv["found"] = true
					out.inventory = inv
		var instance := state.get_node_instance(i)
		if instance != null:
			_scan_state(instance.get_state(), out, depth + 1)


# =============================================================================
# scene
# =============================================================================

## The hideout scene root: a full-screen Control with hideout.gd and two
## inventory.gd children (Stash, Loadout). Caller saves (and frees) it.
static func build_hideout(p: Dictionary, bag: Dictionary, hideout_script: Script, inventory_script: Script) -> Control:
	var root := Control.new()
	root.name = "Hideout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.set_script(hideout_script)
	root.set("title", p.title)
	root.set("cell_size", p.cell_size)
	var db: Resource = ResourceLoader.load(p.database_path) if FileAccess.file_exists(p.database_path) else null
	var specs := [
		["Stash", {"grid_width": p.stash_width, "grid_height": p.stash_height, "max_weight": 0.0, "allow_rotation": true}],
		["Loadout", {"grid_width": int(bag.grid_width), "grid_height": int(bag.grid_height), "max_weight": float(bag.max_weight), "allow_rotation": bool(bag.allow_rotation)}],
	]
	for spec in specs:
		var inv := Node.new()
		inv.name = spec[0]
		inv.set_script(inventory_script)
		for k in spec[1]:
			inv.set(k, spec[1][k])
		inv.set("encumbered_weight", 0.0)
		inv.set("speed_property", &"")
		inv.set("pickup_script_path", "")
		if db != null:
			inv.set("item_database", db)
		root.add_child(inv)
		inv.owner = root
	return root
