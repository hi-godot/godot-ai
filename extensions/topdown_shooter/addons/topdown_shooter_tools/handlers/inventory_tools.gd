@tool
extends RefCounted

## inventory_ui_scaffold: gives the player a grid + weight inventory
## (inventory.gd, an "Inventory" child) and an inventory screen
## (inventory_ui.gd, a CanvasLayer in the open scene) toggled by an input
## action (Tab / I by default).
##
## Loot pickups call add_item(item, count) on the body that touches them.
## When the player script has no add_item yet, the tool appends a short one
## that forwards to the Inventory child, so dropped loot goes into the bag.
## The scene nodes are one undo step in the scene history; the player
## script change is one undo step in the global history.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const LootTools := preload("res://addons/topdown_shooter_tools/handlers/loot_tools.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_DATABASE := "res://data/items/item_database.tres"
const DEFAULT_ACTION := "inventory"
const TOGGLE_KEYS := [KEY_TAB, KEY_I]
const PATCH_MARKER := "# --- inventory_ui_scaffold"
const MAX_STARTING := 200


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func inventory_ui_scaffold(params: Dictionary, _ctx = null) -> Dictionary:
	var values := {}
	for spec in [
		["grid_width", 6, 1, 64], ["grid_height", 8, 1, 64], ["cell_size", 56, 24, 128],
	]:
		var v: Variant = Util.integer(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	for spec in [
		["max_weight", 40.0, 0.0, 100000.0], ["encumbered_weight", 25.0, 0.0, 100000.0],
		["min_speed_factor", 0.5, 0.05, 1.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	for spec in [
		["allow_rotation", true], ["block_player_while_open", true], ["show_hud", true],
		["create_input_action", true], ["patch_player_script", true], ["overwrite_scripts", false],
		["dry_run", false],
	]:
		var v: Variant = Util.boolean(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	for spec in [
		["player_path", ""], ["database_path", DEFAULT_DATABASE], ["toggle_action", DEFAULT_ACTION],
		["inventory_name", "Inventory"], ["ui_name", "InventoryUI"], ["script_dir", DEFAULT_SCRIPT_DIR],
		["title", "인벤토리"],
	]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	for key in ["inventory_name", "ui_name"]:
		if not String(values[key]).is_valid_identifier():
			return Util.error(Util.INVALID_PARAMS, "'%s' must be a plain node name like %s" % [key, "Inventory" if key == "inventory_name" else "InventoryUI"])
	var action := String(values.toggle_action)
	if not action.is_empty() and not action.is_valid_identifier():
		return Util.error(Util.INVALID_PARAMS, "'toggle_action' must be letters, digits and underscores (e.g. inventory)")
	if values.max_weight > 0.0 and values.encumbered_weight > values.max_weight:
		return Util.error(Util.INVALID_PARAMS, "encumbered_weight (%s) is above max_weight (%s)" % [values.encumbered_weight, values.max_weight])
	var script_dir := Util.clean_dir(values.script_dir)
	var inv_script_path := script_dir + "/inventory.gd"
	var ui_script_path := script_dir + "/inventory_ui.gd"
	for p in [inv_script_path, ui_script_path]:
		var reason := Util.check_res_path(p, "gd")
		if not reason.is_empty():
			return Util.error(Util.INVALID_PARAMS, reason)

	## --- scene and player -------------------------------------------------------
	var root := Util.edited_root()
	if root == null:
		return Util.no_scene_error()
	var player: Node = null
	if String(values.player_path).is_empty():
		for node in root.get_tree().get_nodes_in_group(&"player"):
			if node == root or root.is_ancestor_of(node):
				player = node
				break
		if player == null:
			return Util.error(Util.NODE_NOT_FOUND, "no node in group 'player' in the open scene; create one with player_controller_scaffold or pass player_path")
	else:
		player = Util.resolve(values.player_path, root)
		if player == null:
			return Util.error(Util.NODE_NOT_FOUND, "player_path '%s' not found in the edited scene" % values.player_path)
	var warnings: Array[String] = []

	## --- item database and starting items ---------------------------------------
	var db: Variant = LootTools._read_database(values.database_path)
	if Util.is_error(db):
		return db
	var starting: Variant = _parse_starting(params, db, values.database_path)
	if Util.is_error(starting):
		return starting
	if db.items.is_empty():
		warnings.append("no item database at %s: the inventory accepts item resources only, not ids (import items with item_db_import)" % values.database_path)

	## --- player script patch (planned) -------------------------------------------
	var patch := _plan_patch(player, values.inventory_name, values.patch_player_script)
	if not patch.warning.is_empty():
		warnings.append(patch.warning)

	## --- existing nodes ----------------------------------------------------------
	var existing_inv: Node = null
	for child in player.get_children():
		var s := child.get_script() as Script
		if s != null and s.resource_path == inv_script_path:
			existing_inv = child
			break
	var existing_ui: Node = null
	for node in _all_nodes(root):
		var s := node.get_script() as Script
		if s != null and s.resource_path == ui_script_path:
			existing_ui = node
			break

	var report := {
		"player": Util.scene_path_of(player, root),
		"grid": [values.grid_width, values.grid_height],
		"max_weight": values.max_weight,
		"encumbered_weight": values.encumbered_weight,
		"database": values.database_path if not db.items.is_empty() else "",
		"starting_items": starting,
		"player_script": patch.status,
		"warnings": warnings,
	}
	if values.dry_run:
		report["dry_run"] = true
		report["would"] = {
			"inventory": "update" if existing_inv != null else "create",
			"ui": "update" if existing_ui != null else "create",
		}
		return {"data": report}

	## --- scripts ------------------------------------------------------------------
	var installed := {}
	for pair in [["inventory.gd.tmpl", inv_script_path], ["inventory_ui.gd.tmpl", ui_script_path]]:
		var s := Util.install_script(pair[0], pair[1], values.overwrite_scripts)
		if Util.is_error(s):
			return s
		installed[pair[1]] = s
	report["scripts"] = {inv_script_path: installed[inv_script_path].status, ui_script_path: installed[ui_script_path].status}
	Util.refresh_filesystem(installed.keys())

	## --- input action ---------------------------------------------------------------
	if not action.is_empty():
		if ProjectSettings.has_setting("input/" + action):
			report["input_action"] = {"name": action, "status": "kept"}
		elif values.create_input_action:
			var err := _add_action(action)
			if not err.is_empty():
				return Util.error(Util.INTERNAL_ERROR, err)
			report["input_action"] = {"name": action, "status": "created", "keys": ["Tab", "I"]}
		else:
			warnings.append("input action '%s' does not exist; the screen cannot be opened until you add it" % action)

	## --- player script ----------------------------------------------------------------
	if patch.apply:
		var msg := _apply_patch(patch)
		if not msg.is_empty():
			return Util.error(Util.INTERNAL_ERROR, msg)
		report["player_script"] = "patched %s (added add_item -> %s)" % [patch.path, values.inventory_name]

	## --- nodes ------------------------------------------------------------------------
	var inv_props := {
		"grid_width": values.grid_width,
		"grid_height": values.grid_height,
		"allow_rotation": values.allow_rotation,
		"max_weight": values.max_weight,
		"encumbered_weight": values.encumbered_weight,
		"min_speed_factor": values.min_speed_factor,
	}
	if not db.items.is_empty():
		inv_props["item_database"] = ResourceLoader.load(values.database_path)
	if params.has("starting_items") and params.starting_items != null:
		var typed: Array[Dictionary] = []
		for s in starting:
			typed.append({"item_id": s.item_id, "count": s.count})
		inv_props["starting_items"] = typed
	var pickup_path := script_dir + "/loot_pickup.gd"
	if FileAccess.file_exists(pickup_path):
		inv_props["pickup_script_path"] = pickup_path
	else:
		warnings.append("%s not found: dropping items from the bag needs loot_table_edit's pickup script" % pickup_path)

	var ui_props := {
		"toggle_action": StringName(action),
		"title": values.title,
		"cell_size": values.cell_size,
		"block_owner_while_open": values.block_player_while_open,
		"show_hud": values.show_hud,
	}

	var items := []
	var props := []
	var inv_node := existing_inv
	if inv_node == null:
		inv_node = Node.new()
		inv_node.name = Util.unique_child_name(player, values.inventory_name)
		inv_node.set_script(installed[inv_script_path].script)
		for k in inv_props:
			inv_node.set(k, inv_props[k])
		items.append([player, inv_node])
	else:
		for k in inv_props:
			props.append([inv_node, k, inv_props[k], inv_node.get(k)])
	## The UI finds the inventory by path from the scene root's child.
	var inv_rel := "../" + String(root.get_path_to(player)) + "/" + String(inv_node.name)
	if player == root:
		inv_rel = "../" + String(inv_node.name)
	ui_props["inventory_path"] = NodePath(inv_rel)
	var ui_node := existing_ui
	if ui_node == null:
		ui_node = CanvasLayer.new()
		ui_node.name = Util.unique_child_name(root, values.ui_name)
		ui_node.set_script(installed[ui_script_path].script)
		for k in ui_props:
			ui_node.set(k, ui_props[k])
		items.append([root, ui_node])
	else:
		if ui_node.get_parent() != root:
			ui_props["inventory_path"] = ui_node.get_path_to(inv_node) if inv_node.is_inside_tree() else ui_props.inventory_path
		for k in ui_props:
			props.append([ui_node, k, ui_props[k], ui_node.get(k)])

	var label := "Inventory UI scaffold"
	if not items.is_empty():
		Util.add_nodes_to_scene(label, items, root, props)
	elif not props.is_empty():
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action(label, UndoRedo.MERGE_DISABLE, root)
		for t in props:
			ur.add_do_property(t[0], t[1], t[2])
			ur.add_undo_property(t[0], t[1], t[3])
		ur.commit_action()
	report["inventory"] = Util.scene_path_of(inv_node, root) + (" (updated)" if existing_inv != null else "")
	report["ui"] = Util.scene_path_of(ui_node, root) + (" (updated)" if existing_ui != null else "")
	var undo := "Edit > Undo removes the nodes (or restores their settings)."
	if patch.apply:
		undo += " The player script change is a separate undo step."
	report["undo"] = undo
	report["controls"] = "Tab/I: open/close, drag: move, R while dragging: rotate, right click: drop, Shift+click: split, Esc: close"
	report["warnings"] = warnings
	return {"data": report}


# =============================================================================
# helpers
# =============================================================================

func _parse_starting(params: Dictionary, db: Dictionary, database_path: String) -> Variant:
	var out := []
	if not params.has("starting_items") or params.starting_items == null:
		return out
	if not params.starting_items is Array:
		return Util.error(Util.INVALID_PARAMS, "'starting_items' must be an array of {item_id, count}")
	if params.starting_items.size() > MAX_STARTING:
		return Util.error(Util.INVALID_PARAMS, "at most %d starting_items" % MAX_STARTING)
	var unknown: Array[String] = []
	for i in params.starting_items.size():
		var raw: Variant = params.starting_items[i]
		var where := "starting_items[%d]" % i
		if raw is String:
			raw = {"item_id": raw}
		if not raw is Dictionary:
			return Util.error(Util.INVALID_PARAMS, "%s must be {item_id, count}" % where)
		for k in raw:
			if String(k) not in ["item_id", "count"]:
				return Util.error(Util.INVALID_PARAMS, "%s has unknown key '%s' (use item_id, count)" % [where, k])
		if not raw.get("item_id") is String or String(raw.item_id).strip_edges().is_empty():
			return Util.error(Util.INVALID_PARAMS, "%s.item_id must be a non-empty string" % where)
		var count: Variant = Util.integer(raw, "count", 1, 1, 1000000)
		if Util.is_error(count):
			count.error.message = where + ": " + count.error.message
			return count
		var id := String(raw.item_id).strip_edges()
		if not db.items.has(id):
			unknown.append(id)
		out.append({"item_id": id, "count": count})
	if not unknown.is_empty():
		return Util.error(Util.INVALID_PARAMS, "not in the item database (%s): %s" % [database_path, ", ".join(unknown)])
	return out


## Decides whether the player's script needs an add_item that forwards to
## the inventory node. Returns {apply, status, warning, path, source}.
static func _plan_patch(player: Node, inventory_name: String, enabled: bool) -> Dictionary:
	var out := {"apply": false, "status": "", "warning": "", "path": "", "source": ""}
	var script := player.get_script() as Script
	if script == null:
		out.status = "none"
		out.warning = "%s has no script; give it add_item(item, count) that calls $%s.add_item so pickups fill the bag" % [player.name, inventory_name]
		return out
	out.path = script.resource_path
	var source := FileAccess.get_file_as_string(out.path) if out.path.begins_with("res://") and not out.path.contains("::") else ""
	if source.is_empty():
		out.status = "not a file"
		out.warning = "%s's script is built in; add add_item(item, count) that calls $%s.add_item yourself" % [player.name, inventory_name]
		return out
	if _has_func(source, "add_item"):
		out.status = "kept (already has add_item)"
		return out
	if not enabled:
		out.status = "not patched"
		out.warning = "patch_player_script=false: pickups will not reach the inventory until %s has add_item(item, count)" % out.path
		return out
	if out.path.begins_with("res://addons/"):
		out.status = "not patched (addon script)"
		out.warning = "%s is inside addons/; add add_item(item, count) to the player yourself" % out.path
		return out
	out.apply = true
	out.status = "will patch"
	out.source = source
	out["addition"] = _patch_text(inventory_name)
	return out


static func _has_func(source: String, name: String) -> bool:
	var re := RegEx.create_from_string("(?m)^\\s*(static\\s+)?func\\s+" + name + "\\s*\\(")
	return re.search(source) != null


static func _patch_text(inventory_name: String) -> String:
	return "\n\n%s: loot pickups call add_item on the body ---\n" % PATCH_MARKER \
		+ "## Puts picked-up items into the %s child; false (bag full) leaves the pickup.\n" % inventory_name \
		+ "func add_item(item: Variant, count: int = 1) -> bool:\n" \
		+ "\tvar inventory := get_node_or_null(^\"%s\")\n" % inventory_name \
		+ "\tif inventory == null or not inventory.has_method(\"add_item\"):\n" \
		+ "\t\treturn true\n" \
		+ "\treturn inventory.add_item(item, count)\n"


func _apply_patch(patch: Dictionary) -> String:
	var path: String = patch.path
	var before := ItemTools.FileSnapshot.capture([path])
	var text: String = patch.source
	text = text.rstrip("\n") + patch.addition
	var probe := GDScript.new()
	probe.source_code = text
	if probe.reload() != OK:
		return "%s would not compile with add_item added; add it yourself or pass patch_player_script=false" % path
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	f.close()
	var reloader := ScriptReloader.new()
	reloader.path = path
	reloader.reload()
	var after := ItemTools.FileSnapshot.capture([path])
	var ur := EditorInterface.get_editor_undo_redo() if Engine.is_editor_hint() else null
	if ur != null:
		ur.create_action("Add add_item to %s" % path.get_file(), UndoRedo.MERGE_DISABLE, null, false, false)
		ur.add_do_method(after, "restore")
		ur.add_do_method(reloader, "reload")
		ur.add_undo_method(before, "restore")
		ur.add_undo_method(reloader, "reload")
		ur.commit_action(false)
	Util.refresh_filesystem([path])
	return ""


static func _add_action(action: String) -> String:
	var events: Array = []
	for code in TOGGLE_KEYS:
		var key := InputEventKey.new()
		key.physical_keycode = code
		events.append(key)
	ProjectSettings.set_setting("input/" + action, {"deadzone": 0.5, "events": events})
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.5)
		for ev in events:
			InputMap.action_add_event(action, ev)
	var err := ProjectSettings.save()
	if err != OK:
		return "cannot save project.godot: %s" % error_string(err)
	return ""


static func _all_nodes(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_all_nodes(child))
	return out


## Makes the cached Script match the file (the editor keeps scripts loaded).
class ScriptReloader extends RefCounted:
	var path := ""

	func reload() -> void:
		if not ResourceLoader.has_cached(path):
			return
		var script := ResourceLoader.load(path) as GDScript
		if script != null:
			script.source_code = FileAccess.get_file_as_string(path)
			script.reload(true)
