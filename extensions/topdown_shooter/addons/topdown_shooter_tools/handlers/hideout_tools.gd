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
## style="map" also writes a walkable 3D hideout (hideout_map.gd): a base
## room with the player, a follow camera, a stash locker (interact opens the
## stash screen above as an overlay) and a deploy door (stand on its pad to
## deploy). HideoutState then loads that map after a raid, and it becomes
## the main scene. The menu scene stays as the overlay.
##
## Nothing in the raid scene is edited: the autoload finds the player, its
## Inventory and the extraction zones by group at run time. The scene files
## and the Project Settings changes (autoload, game/hideout/* settings,
## main scene) are one undo step in the editor's global history.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const LootTools := preload("res://addons/topdown_shooter_tools/handlers/loot_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")
const TopdownTools := preload("res://addons/topdown_shooter_tools/handlers/topdown_tools.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_SCENE := "res://scenes/hideout.tscn"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_SAVE := "user://hideout/save.json"
const DEFAULT_MAP_SCENE := "res://scenes/hideout_map.tscn"
const DEFAULT_PLAYER_SCENE := "res://scenes/player/player.tscn"
const MAP_COLORS := {
	"floor": Color(0.32, 0.31, 0.29),
	"wall": Color(0.5, 0.5, 0.52),
	"low_wall": Color(0.42, 0.42, 0.45),
	"locker": Color(0.3, 0.42, 0.55),
	"door": Color(0.18, 0.17, 0.16),
	"frame": Color(0.55, 0.38, 0.18),
	"pad": Color(1.0, 0.65, 0.2),
	"wood": Color(0.45, 0.33, 0.22),
	"crate": Color(0.55, 0.45, 0.25),
	"cot": Color(0.3, 0.38, 0.28),
}
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
	var map_mode: bool = p.style == "map"
	if map_mode and (p.map_scene == raid_scene or p.map_scene == p.hideout_scene):
		return Util.error(Util.INVALID_PARAMS, "map_scene (%s) must differ from raid_scene and hideout_scene" % p.map_scene)
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
	var map_exists := map_mode and FileAccess.file_exists(p.map_scene)
	var write_map: bool = map_mode and (not map_exists or p.overwrite)
	var player_scene := ""
	if map_mode:
		paths["map"] = script_dir + "/hideout_map.gd"
		paths["door"] = script_dir + "/hideout_door.gd"
		paths["locker"] = script_dir + "/hideout_locker.gd"
		paths["camera"] = script_dir + "/topdown_camera_rig.gd"
		paths["player"] = script_dir + "/player_controller.gd"
		if map_exists and not p.overwrite:
			warnings.append("%s exists and was kept: room size, door and locker were not changed (overwrite=true rebuilds it)" % p.map_scene)
		if write_map and Engine.is_editor_hint() and EditorInterface.get_open_scenes().has(p.map_scene):
			return Util.error(Util.INVALID_PARAMS, "%s is open in the editor; close it before rebuilding it" % p.map_scene)
		player_scene = p.player_scene
		if player_scene.is_empty():
			player_scene = str(raid.get("player_scene", ""))
		if player_scene.is_empty() and FileAccess.file_exists(DEFAULT_PLAYER_SCENE):
			player_scene = DEFAULT_PLAYER_SCENE
		if not player_scene.is_empty() and not ResourceLoader.exists(player_scene):
			return Util.error(Util.NODE_NOT_FOUND, "player_scene %s does not exist" % player_scene)
		if player_scene.is_empty():
			warnings.append("no player scene found (player_controller_scaffold): the map gets a plain player_controller.gd body")
	var home_scene: String = p.map_scene if map_mode else p.hideout_scene

	var settings := {
		"autoload/" + AUTOLOAD_NAME: "*" + paths.state,
		SETTINGS_PREFIX + "hideout_scene": home_scene,
		SETTINGS_PREFIX + "menu_scene": p.hideout_scene,
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
		settings[MAIN_SCENE_KEY] = home_scene

	var report := {
		"style": p.style,
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
		"main_scene": {"before": old_main, "after": home_scene if p.set_main_scene else old_main},
		"warnings": warnings,
	}
	if map_mode:
		report["map"] = {
			"scene": p.map_scene,
			"room": [p.map_size.x, p.map_size.y],
			"deploy_time": p.deploy_time,
			"player_scene": player_scene,
			"interact_action": p.interact_action,
		}
	if p.dry_run:
		report["dry_run"] = true
		report["would"] = {"hideout_scene": ("overwrite" if p.overwrite else "keep") if scene_exists else "create"}
		if map_mode:
			report.would["map_scene"] = ("overwrite" if p.overwrite else "keep") if map_exists else "create"
		return {"data": report}

	## --- scripts ------------------------------------------------------------------
	var installed := {}
	var templates := [["inventory.gd.tmpl", paths.inventory, false], ["hideout.gd.tmpl", paths.hideout, p.overwrite_scripts], ["hideout_state.gd.tmpl", paths.state, p.overwrite_scripts]]
	if map_mode:
		templates.append_array([
			["hideout_map.gd.tmpl", paths.map, p.overwrite_scripts],
			["hideout_door.gd.tmpl", paths.door, p.overwrite_scripts],
			["hideout_locker.gd.tmpl", paths.locker, p.overwrite_scripts],
			["topdown_camera_rig.gd.tmpl", paths.camera, false],
		])
		if player_scene.is_empty():
			templates.append(["player_controller.gd.tmpl", paths.player, false])
	for pair in templates:
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
	var scene_files: Array = [p.hideout_scene]
	if map_mode:
		scene_files.append(p.map_scene)
		var action: Variant = _ensure_interact_action(p.interact_action)
		if Util.is_error(action):
			return action
		report.map["input_actions"] = action
	var before := ItemTools.FileSnapshot.capture(scene_files)
	if write_scene:
		var root := build_hideout(p, bag, installed[paths.hideout].script, installed[paths.inventory].script)
		var msg := Util.save_scene(root, p.hideout_scene)
		if not msg.is_empty():
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, msg)
		Util.refresh_filesystem([p.hideout_scene])
	report["hideout_scene_status"] = ("overwritten" if scene_exists else "created") if write_scene else "kept"
	if write_map:
		var menu := ResourceLoader.load(p.hideout_scene, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
		var player_packed: PackedScene = null
		if not player_scene.is_empty():
			player_packed = ResourceLoader.load(player_scene, "PackedScene") as PackedScene
			if player_packed == null:
				before.restore()
				return Util.error(Util.INTERNAL_ERROR, "cannot load player_scene %s" % player_scene)
		if menu == null:
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, "cannot load the hideout scene %s back" % p.hideout_scene)
		var scripts := {}
		for k in ["map", "door", "locker", "camera"]:
			scripts[k] = installed[paths[k]].script
		scripts["player"] = installed[paths.player].script if installed.has(paths.player) else null
		var map_root := build_map(p, menu, player_packed, scripts)
		report.map["nodes"] = _map_summary(map_root)
		var msg := Util.save_scene(map_root, p.map_scene)
		if not msg.is_empty():
			before.restore()
			return Util.error(Util.INTERNAL_ERROR, msg)
		Util.refresh_filesystem([p.map_scene])
	if map_mode:
		report.map["status"] = ("overwritten" if map_exists else "created") if write_map else "kept"
	var after := ItemTools.FileSnapshot.capture(scene_files)
	var files_changed: bool = write_scene or write_map

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
		if files_changed:
			ur.add_do_method(after, &"restore")
			ur.add_undo_method(before, &"restore")
		ur.commit_action()
	else:
		for key in settings:
			ProjectSettings.set_setting(key, settings[key])
		ProjectSettings.save()
	if ProjectSettings.get_setting("autoload/" + AUTOLOAD_NAME, null) != settings["autoload/" + AUTOLOAD_NAME]:
		return Util.error(Util.INTERNAL_ERROR, "could not register the %s autoload in project.godot" % AUTOLOAD_NAME)

	if map_mode:
		report["flow"] = "%s(걸어 다니는 은신처: 창고 사물함에서 E -> 창고·가방 화면) -> 출격 문 앞에 %s초 -> %s -> 탈출하면 가방 전체가 창고로 / 죽으면 가방을 잃음 -> %s초 뒤 은신처 맵" % [p.map_scene.get_file(), p.deploy_time, raid_scene.get_file(), p.return_delay]
		report["controls"] = "WASD 이동, 사물함 앞에서 E: 창고 열기 (E/Tab/Esc 닫기), 창고 화면: 드래그 이동, R 회전, 우클릭 반대편으로, Shift+클릭 나누기, 출격 문 패드에 서 있기: 출격"
	else:
		report["flow"] = "%s(창고·가방) -> 출격 -> %s -> 탈출하면 가방 전체가 창고로 / 죽으면 가방을 잃음 -> %s초 뒤 은신처" % [p.hideout_scene.get_file(), raid_scene.get_file(), p.return_delay]
		report["controls"] = "드래그: 이동(창고↔가방), R: 회전, 우클릭: 반대편으로 보내기, Shift+클릭: 나누기, 출격 버튼"
	var undone: Array[String] = []
	if write_scene:
		undone.append("the hideout scene")
	if write_map:
		undone.append("the hideout map")
	report["undo"] = "Edit > Undo removes the autoload and settings%s and restores the main scene. Copied scripts stay." % ((" and " + " and ".join(undone)) if not undone.is_empty() else "")
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
		"style", "map_scene", "map_size", "deploy_time", "player_scene", "interact_action",
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
		["deploy_time", "num", 3.0, 0.5, 30.0],
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
		["style", "text", "menu"],
		["map_scene", "text", DEFAULT_MAP_SCENE],
		["player_scene", "text", ""],
		["interact_action", "text", "interact"],
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
	if p.style not in ["menu", "map"]:
		return Util.error(Util.INVALID_PARAMS, "'style' must be menu or map, got '%s'" % p.style)
	reason = Util.check_res_path(p.map_scene, "tscn")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'map_scene': " + reason)
	if not p.player_scene.is_empty() and (not p.player_scene.begins_with("res://") or p.player_scene.get_extension() not in ["tscn", "scn"]):
		return Util.error(Util.INVALID_PARAMS, "'player_scene' must be a res:// .tscn path, got '%s'" % p.player_scene)
	if not p.interact_action.is_valid_identifier():
		return Util.error(Util.INVALID_PARAMS, "'interact_action' must be letters, digits and underscores")
	p.map_size = Vector2(14, 10)
	if params.has("map_size") and params.map_size != null:
		var size: Variant = params.map_size
		if not size is Array or size.size() != 2 or not (size[0] is float or size[0] is int) or not (size[1] is float or size[1] is int):
			return Util.error(Util.INVALID_PARAMS, "'map_size' must be [width, depth] in meters")
		p.map_size = Vector2(roundf(float(size[0])), roundf(float(size[1])))
		if p.map_size.x < 10 or p.map_size.y < 8 or p.map_size.x > 40 or p.map_size.y > 40:
			return Util.error(Util.INVALID_PARAMS, "'map_size' must be 10..40 wide and 8..40 deep, got %s" % [size])
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
## instances). Returns {"extractions", "player", "player_scene" (the .tscn
## the player is an instance of, or ""), "inventory": {...}}.
static func inspect_scene(path: String) -> Dictionary:
	var out := {"extractions": 0, "player": false, "player_scene": "", "inventory": {}}
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
			var had_player: bool = out.player
			_scan_state(instance.get_state(), out, depth + 1)
			if not had_player and out.player and str(out.player_scene).is_empty():
				out.player_scene = instance.resource_path


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


# =============================================================================
# 3D hideout map (style="map")
# =============================================================================

## The walkable hideout: a room (floor top at y=0, centered on the origin,
## the deploy door in the far -z wall), the stash locker on the left wall,
## some furniture, the player, a follow camera and the menu hideout as a
## hidden overlay (StashScreen). Caller saves (and frees) it.
static func build_map(p: Dictionary, menu: PackedScene, player_packed: PackedScene, scripts: Dictionary) -> Node3D:
	var w: float = p.map_size.x
	var d: float = p.map_size.y
	var t := 0.4
	var h := 3.0
	var cache := {}
	var root := Node3D.new()
	root.name = "HideoutMap"
	root.set_script(scripts.map)
	root.set("title", p.title)
	root.set("interact_action", StringName(p.interact_action))

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.8
	sun.shadow_enabled = true
	_own(root, root, sun)
	var lamp := OmniLight3D.new()
	lamp.name = "Lamp"
	lamp.position = Vector3(0, h - 0.4, 0)
	lamp.light_color = Color(1.0, 0.85, 0.65)
	lamp.light_energy = 1.6
	lamp.omni_range = maxf(w, d) * 0.8
	lamp.shadow_enabled = true
	_own(root, root, lamp)

	## Room: floor, walls (the near +z wall is low so the camera sees in),
	## and a gap in the far wall for the door.
	var room := _own(root, root, _node3d("Room"))
	_map_box(root, room, cache, "Floor", Vector3(w + 2 * t, 0.2, d + 2 * t), Vector3(0, -0.1, 0), "floor")
	var gap := 2.4
	var side := (w + 2 * t - gap) / 2.0
	var far_z := -d / 2.0 - t / 2.0
	_map_box(root, room, cache, "WallFarLeft", Vector3(side, h, t), Vector3(-gap / 2.0 - side / 2.0, h / 2.0, far_z), "wall")
	_map_box(root, room, cache, "WallFarRight", Vector3(side, h, t), Vector3(gap / 2.0 + side / 2.0, h / 2.0, far_z), "wall")
	_map_box(root, room, cache, "WallNear", Vector3(w + 2 * t, 1.0, t), Vector3(0, 0.5, d / 2.0 + t / 2.0), "low_wall")
	_map_box(root, room, cache, "WallLeft", Vector3(t, h, d), Vector3(-w / 2.0 - t / 2.0, h / 2.0, 0), "wall")
	_map_box(root, room, cache, "WallRight", Vector3(t, h, d), Vector3(w / 2.0 + t / 2.0, h / 2.0, 0), "wall")

	## Deploy door: frame and a closed slab in the gap, the pad in front.
	var door_frame := _own(root, root, _node3d("DoorFrame"))
	_map_box(root, door_frame, cache, "PostLeft", Vector3(0.3, h, t + 0.2), Vector3(-gap / 2.0 + 0.15, h / 2.0, far_z), "frame")
	_map_box(root, door_frame, cache, "PostRight", Vector3(0.3, h, t + 0.2), Vector3(gap / 2.0 - 0.15, h / 2.0, far_z), "frame")
	_map_box(root, door_frame, cache, "Lintel", Vector3(gap, 0.5, t + 0.2), Vector3(0, h - 0.25, far_z), "frame")
	_map_box(root, door_frame, cache, "Slab", Vector3(gap - 0.6, h - 0.5, 0.15), Vector3(0, (h - 0.5) / 2.0, far_z), "door")
	var door := Area3D.new()
	door.name = "DeployDoor"
	door.position = Vector3(0, 0, -d / 2.0 + 1.2)
	door.set_script(scripts.door)
	door.set("deploy_time", p.deploy_time)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(gap - 0.4, 2.0, 1.6)
	shape.shape = box
	shape.position = Vector3(0, 1, 0)
	door.add_child(shape)
	var pad := MeshInstance3D.new()
	pad.name = "Pad"
	var pad_mesh := BoxMesh.new()
	pad_mesh.size = Vector3(gap - 0.4, 0.04, 1.6)
	pad_mesh.material = _map_material(cache, "pad")
	pad.mesh = pad_mesh
	pad.position = Vector3(0, 0.02, 0)
	door.add_child(pad)
	door.add_child(_label3d("출격", Vector3(0, 2.4, -0.4), Color(1.0, 0.8, 0.45)))
	_own(root, root, door)

	## Stash locker against the left wall, facing the room.
	var locker := StaticBody3D.new()
	locker.name = "StashLocker"
	locker.position = Vector3(-w / 2.0 + 0.45, 0, -d / 2.0 + 3.0)
	locker.set_script(scripts.locker)
	var locker_size := Vector3(0.9, 2.2, 2.6)
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = locker_size
	body_mesh.material = _map_material(cache, "locker")
	body.mesh = body_mesh
	body.position = Vector3(0, locker_size.y / 2.0, 0)
	locker.add_child(body)
	var locker_shape := CollisionShape3D.new()
	locker_shape.name = "Shape"
	var locker_box := BoxShape3D.new()
	locker_box.size = locker_size
	locker_shape.shape = locker_box
	locker_shape.position = body.position
	locker.add_child(locker_shape)
	for i in 3:
		var stripe := MeshInstance3D.new()
		stripe.name = "Door%d" % (i + 1)
		var stripe_mesh := BoxMesh.new()
		stripe_mesh.size = Vector3(0.04, 1.9, 0.78)
		stripe_mesh.material = _map_material(cache, "frame")
		stripe.mesh = stripe_mesh
		stripe.position = Vector3(locker_size.x / 2.0 + 0.01, 1.05, -0.86 + 0.86 * i)
		locker.add_child(stripe)
	locker.add_child(_label3d("창고", Vector3(0.6, 2.7, 0), Color(0.75, 0.85, 1.0)))
	_own(root, root, locker)

	## Furniture (static boxes; move or delete freely).
	var props := _own(root, root, _node3d("Props"))
	_map_box(root, props, cache, "Table", Vector3(2.0, 0.8, 1.0), Vector3(w / 2.0 - 3.0, 0.4, -0.5), "wood")
	_map_box(root, props, cache, "Cot", Vector3(1.0, 0.5, 2.2), Vector3(w / 2.0 - 0.8, 0.25, d / 2.0 - 2.0), "cot")
	_map_box(root, props, cache, "Crate1", Vector3(1.0, 0.8, 1.0), Vector3(w / 2.0 - 0.8, 0.4, -d / 2.0 + 0.8), "crate")
	_map_box(root, props, cache, "Crate2", Vector3(0.8, 0.6, 0.8), Vector3(w / 2.0 - 0.8, 1.1, -d / 2.0 + 0.8), "crate")
	_map_box(root, props, cache, "Crate3", Vector3(1.0, 0.8, 1.0), Vector3(w / 2.0 - 2.0, 0.4, -d / 2.0 + 0.8), "crate")
	_map_box(root, props, cache, "Shelf", Vector3(0.6, 1.8, 2.0), Vector3(-w / 2.0 + 0.3, 0.9, d / 2.0 - 2.0), "wood")

	## Player, spawn point, camera.
	## A bit in front of the middle, so the camera shows the door at the start.
	var spawn_at := Vector3(0, 0, minf(1.0, d / 2.0 - 2.5))
	var spawn := Marker3D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = spawn_at
	spawn.add_to_group(&"player_spawn", true)
	_own(root, root, spawn)
	var player: Node3D
	if player_packed != null:
		player = player_packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
		player.name = "Player"
		player.position = spawn_at
		root.add_child(player)
		player.owner = root
	else:
		var values := {"move_speed": 6.0, "aim_height": 1.2}
		var actions := {}
		for suffix in TopdownTools.INPUT_ACTIONS:
			actions[suffix] = suffix
		player = TopdownTools.new()._build_player(scripts.player, values, actions)
		player.position = spawn_at
		_own(root, root, player)
	var rig := Node3D.new()
	rig.name = "TopdownCamera"
	rig.top_level = true
	rig.set_script(scripts.camera)
	rig.set("target_path", NodePath("../Player"))
	rig.set("distance", 12.0)
	rig.position = spawn_at
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 50.0
	camera.current = true
	rig.add_child(camera)
	_own(root, root, rig)

	## The stash screen: the menu hideout, hidden until the locker opens it.
	var screen := CanvasLayer.new()
	screen.name = "StashScreen"
	screen.layer = 20
	screen.visible = false
	root.add_child(screen)
	screen.owner = root
	var ui := menu.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	ui.name = "Hideout"
	screen.add_child(ui)
	ui.owner = root
	root.set("stash_ui_path", NodePath("StashScreen/Hideout"))
	return root


## Adds `node` under `parent` and makes `owner_node` own it and everything
## below it. Returns node.
static func _own(owner_node: Node, parent: Node, node: Node) -> Node:
	parent.add_child(node)
	node.owner = owner_node
	Util.own_descendants(node, owner_node)
	return node


static func _node3d(node_name: String) -> Node3D:
	var n := Node3D.new()
	n.name = node_name
	return n


static func _map_box(owner_node: Node, parent: Node, cache: Dictionary, box_name: String, size: Vector3, center: Vector3, kind: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.position = center
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _map_material(cache, kind)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	_own(owner_node, parent, body)
	return body


static func _map_material(cache: Dictionary, kind: String) -> StandardMaterial3D:
	if not cache.has(kind):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = MAP_COLORS[kind]
		if kind == "pad":
			mat.emission_enabled = true
			mat.emission = MAP_COLORS[kind]
			mat.emission_energy_multiplier = 0.5
		cache[kind] = mat
	return cache[kind]


static func _label3d(text: String, at: Vector3, color: Color) -> Label3D:
	var label := Label3D.new()
	label.name = "Label"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 64
	label.outline_size = 12
	label.modulate = color
	label.position = at
	return label


static func _map_summary(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		out.append(str(child.name))
	return out


func _ensure_interact_action(action: String) -> Variant:
	var key := "input/" + action
	if ProjectSettings.has_setting(key):
		return {"created": [], "kept_existing": [action]}
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ProjectSettings.set_setting(key, {"deadzone": 0.5, "events": [ev]})
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.5)
		InputMap.action_add_event(action, ev)
	var err := ProjectSettings.save()
	if err != OK:
		return Util.error(Util.INTERNAL_ERROR, "cannot save project.godot: %s" % error_string(err))
	return {"created": [action], "kept_existing": []}
