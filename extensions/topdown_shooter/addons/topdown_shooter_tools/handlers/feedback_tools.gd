@tool
extends RefCounted

## Handler for combat_feedback_setup: adds (or retunes) one CombatFeedback
## node in the open scene. The node's script (combat_feedback.gd) hooks the
## game's weapons and damageable bodies by their signals at run time, so no
## weapon, enemy or player script is edited.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const SCRIPT_NAME := "combat_feedback.gd"
const DEFAULT_NODE_NAME := "CombatFeedback"

## Effect switches: param name -> exported property (same name).
const SWITCHES := [
	"enabled", "muzzle_flash", "muzzle_flash_for_enemies", "shell_casings",
	"shell_casings_for_enemies", "hit_particles", "damage_numbers",
	"damage_numbers_for_enemies", "hitmarker", "hitmarker_at_cursor",
	"damage_vignette", "screen_shake",
]

## Tuning numbers: [param, min, max, integer]. Defaults live in the script.
const NUMBERS := [
	["muzzle_flash_size", 0.05, 3.0, false],
	["muzzle_flash_light", 0.0, 30.0, false],
	["casing_lifetime", 0.1, 30.0, false],
	["max_casings", 1, 500, true],
	["particle_amount", 1, 64, true],
	["damage_number_font_size", 8, 256, true],
	["damage_number_duration", 0.1, 3.0, false],
	["damage_number_merge_time", 0.0, 1.0, false],
	["hitmarker_size", 2.0, 80.0, false],
	["hitmarker_duration", 0.02, 1.0, false],
	["vignette_max_alpha", 0.0, 1.0, false],
	["low_health_threshold", 0.0, 1.0, false],
	["shake_strength", 0.0, 3.0, false],
	["max_shake_offset", 0.0, 3.0, false],
	["shake_on_fire", 0.0, 1.0, false],
	["shake_on_hurt", 0.0, 1.0, false],
	["shake_on_kill", 0.0, 1.0, false],
]

const COLORS := ["muzzle_flash_color", "flesh_color", "spark_color", "damage_number_color", "kill_number_color", "hitmarker_color", "kill_marker_color", "vignette_color"]


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func combat_feedback_setup(params: Dictionary, _ctx = null) -> Dictionary:
	var root := Util.edited_root()
	if root == null:
		return Util.no_scene_error()
	if not root is Node3D:
		return Util.error(Util.INVALID_PARAMS, "the open scene's root is a %s; open the 3D game scene (e.g. the raid scene) first" % root.get_class())

	var settings: Variant = _read_settings(params)
	if Util.is_error(settings):
		return settings
	var node_name: Variant = Util.text(params, "name", DEFAULT_NODE_NAME)
	var parent_path: Variant = Util.text(params, "parent_path", "")
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	for v in [node_name, parent_path, script_dir, overwrite_scripts]:
		if Util.is_error(v):
			return v
	if String(node_name).is_empty() or _has_any(node_name, [".", ":", "@", "/", "\"", "%"]):
		return Util.error(Util.INVALID_PARAMS, "'name' contains characters not allowed in node names")

	var script_path := Util.clean_dir(script_dir) + "/" + SCRIPT_NAME
	var existing := _find_existing(root, script_path)
	var report := _scan_scene(root)

	if existing != null:
		## Retune in place: only the given settings change, one undo step.
		var installed_again := Util.install_script("combat_feedback.gd.tmpl", script_path, overwrite_scripts)
		if Util.is_error(installed_again):
			return installed_again
		var changed := {}
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Combat feedback settings", UndoRedo.MERGE_DISABLE, root)
		for key in settings:
			var old: Variant = existing.get(key)
			if old == settings[key]:
				continue
			ur.add_do_property(existing, key, settings[key])
			ur.add_undo_property(existing, key, old)
			changed[key] = {"from": old, "to": settings[key]}
		ur.commit_action()
		Util.refresh_filesystem([script_path])
		var data := _result(existing, root, script_path, installed_again.status, report)
		data["mode"] = "updated"
		data["changed"] = changed
		data["undo"] = "One editor undo step restores the previous settings." if not changed.is_empty() else "Nothing changed."
		return {"data": data}

	var parent := Util.resolve(parent_path, root)
	if parent == null:
		return Util.error(Util.NODE_NOT_FOUND, "parent_path '%s' not found in the edited scene" % parent_path)
	if parent.get_node_or_null(NodePath(node_name)) != null:
		return Util.error(Util.ALREADY_EXISTS, "'%s' already has a child named '%s' that is not a combat feedback node; pass another name" % [Util.scene_path_of(parent, root), node_name])

	var installed := Util.install_script("combat_feedback.gd.tmpl", script_path, overwrite_scripts)
	if Util.is_error(installed):
		return installed

	var node := Node.new()
	node.name = node_name
	node.set_script(installed.script)
	for key in settings:
		node.set(key, settings[key])
	Util.add_to_scene("Combat feedback setup", parent, node, root)
	Util.refresh_filesystem([installed.path])

	var out := _result(node, root, installed.path, installed.status, report)
	out["mode"] = "created"
	out["undo"] = "One editor undo step removes the CombatFeedback node (the copied script stays)."
	return {"data": out}


func _read_settings(params: Dictionary) -> Variant:
	var settings := {}
	for key in SWITCHES:
		if params.has(key) and params[key] != null:
			var b: Variant = Util.boolean(params, key, true)
			if Util.is_error(b):
				return b
			settings[key] = b
	for spec in NUMBERS:
		var key: String = spec[0]
		if not params.has(key) or params[key] == null:
			continue
		var v: Variant
		if spec[3]:
			v = Util.integer(params, key, 0, int(spec[1]), int(spec[2]))
		else:
			v = Util.num(params, key, 0.0, spec[1], spec[2])
		if Util.is_error(v):
			return v
		settings[key] = v
	for key in COLORS:
		if not params.has(key) or params[key] == null:
			continue
		var c: Variant = _color(params[key], key)
		if Util.is_error(c):
			return c
		settings[key] = c
	for key in ["player_group", "camera_path"]:
		if not params.has(key) or params[key] == null:
			continue
		var t: Variant = Util.text(params, key, "")
		if Util.is_error(t):
			return t
		settings[key] = StringName(t) if key == "player_group" else NodePath(t)
	return settings


static func _color(raw: Variant, key: String) -> Variant:
	if raw is String:
		var s := String(raw).strip_edges()
		if Color.html_is_valid(s):
			return Color.html(s)
		var named := Color.from_string(s, Color(0, 0, 0, -1))
		if named.a >= 0.0:
			return named
	elif raw is Array and (raw.size() == 3 or raw.size() == 4):
		for v in raw:
			if not (v is float or v is int):
				return Util.error(Util.INVALID_PARAMS, "'%s' must be \"#rrggbb\" or [r, g, b(, a)] numbers 0..1" % key)
		return Color(raw[0], raw[1], raw[2], raw[3] if raw.size() == 4 else 1.0)
	return Util.error(Util.INVALID_PARAMS, "'%s' must be \"#rrggbb\" or [r, g, b(, a)] numbers 0..1" % key)


## The first node in the scene whose script is the combat feedback script.
static func _find_existing(node: Node, script_path: String) -> Node:
	var script := node.get_script() as Script
	if script != null and (script.resource_path == script_path or script.resource_path.get_file() == SCRIPT_NAME):
		return node
	for child in node.get_children():
		var found := _find_existing(child, script_path)
		if found != null:
			return found
	return null


## What the effects will hook when the scene runs. Scripts are not @tool, so
## the editor only has placeholders: read signals from the Script resource.
static func _scan_scene(root: Node) -> Dictionary:
	var weapons: Array[String] = []
	var damageable: Array[String] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var script := node.get_script() as Script
		if script != null:
			if _script_has_signal(script, "fired") and _script_has_signal(script, "hit"):
				weapons.append(Util.scene_path_of(node, root))
			if _script_has_signal(script, "health_changed"):
				damageable.append(Util.scene_path_of(node, root))
		for child in node.get_children():
			stack.append(child)
	var cameras := 0
	stack = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Camera3D:
			cameras += 1
		for child in n.get_children():
			stack.append(child)
	weapons.sort()
	damageable.sort()
	return {"weapons": weapons, "damageable": damageable, "cameras": cameras}


static func _script_has_signal(script: Script, signal_name: String) -> bool:
	var s := script
	while s != null:
		if s.has_script_signal(signal_name):
			return true
		s = s.get_base_script()
	return false


func _result(node: Node, root: Node, script_path: String, script_status: String, report: Dictionary) -> Dictionary:
	var effects := {}
	for key in SWITCHES:
		effects[key] = node.get(key)
	var warnings: Array[String] = []
	if report.weapons.is_empty():
		warnings.append("No weapon (fired + hit signals, e.g. from weapon_create) is in this scene yet. Weapons spawned while the game runs are still picked up.")
	if report.damageable.is_empty():
		warnings.append("No node with a health_changed signal (player/enemy scaffolds) is in this scene: damage numbers, kill markers and the hurt vignette need one.")
	if report.cameras == 0:
		warnings.append("No Camera3D in this scene: screen shake uses whichever camera is current when the game runs.")
	var data := {
		"node_path": Util.scene_path_of(node, root),
		"script": {"path": script_path, "status": script_status},
		"effects": effects,
		"hooks": {
			"weapons": report.weapons,
			"damageable": report.damageable,
			"cameras": report.cameras,
		},
		"tuning": "Every switch, color and number is an exported property on the node (inspector groups per effect).",
	}
	if not warnings.is_empty():
		data["warnings"] = warnings
	return data


static func _has_any(value: String, chars: Array) -> bool:
	for c in chars:
		if value.contains(c):
			return true
	return false
