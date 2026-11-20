@tool
extends RefCounted

## Handlers for the top-down shooter MCP tools. Godot AI materializes this
## script lazily (no-arg new()) and calls one method per tool with
## (params: Dictionary, ctx: McpCallContext). Params arrive unvalidated.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_PLAYER_SCENE := "res://scenes/player/player.tscn"
const DEFAULT_WEAPON_DATA_DIR := "res://data/weapons"
const DEFAULT_WEAPON_SCENE_DIR := "res://scenes/weapons"
const DEFAULT_ENEMY_SCENE_DIR := "res://scenes/enemies"
## Static colliders under nodes in this group feed the navigation mesh.
const NAV_SOURCE_GROUP := &"navigation_source"

## action suffix -> [events]; each event is ["key", Key] or ["mouse", MouseButton]
const INPUT_ACTIONS := {
	"move_left": [["key", KEY_A], ["key", KEY_LEFT]],
	"move_right": [["key", KEY_D], ["key", KEY_RIGHT]],
	"move_forward": [["key", KEY_W], ["key", KEY_UP]],
	"move_back": [["key", KEY_S], ["key", KEY_DOWN]],
	"dodge": [["key", KEY_SPACE]],
	"fire": [["mouse", MOUSE_BUTTON_LEFT]],
	"reload": [["key", KEY_R]],
}


## Godot AI asks handlers to confirm they hold no in-flight work before a
## hot update swaps scripts. These tools finish synchronously.
func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


# =============================================================================
# topdown_camera_setup
# =============================================================================

func camera_setup(params: Dictionary, _ctx = null) -> Dictionary:
	var root := Util.edited_root()
	if root == null:
		return Util.no_scene_error()

	var values := {}
	for spec in [
		["pitch_degrees", 55.0, 10.0, 89.0],
		["distance", 14.0, 1.0, 200.0],
		["yaw_degrees", 0.0, -180.0, 180.0],
		["fov", 50.0, 1.0, 179.0],
		["follow_smoothing", 8.0, 0.0, 50.0],
		["aim_lookahead", 0.25, 0.0, 1.0],
		["max_lookahead", 4.0, 0.0, 50.0],
		["lookahead_smoothing", 6.0, 0.0, 50.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	var make_current: Variant = Util.boolean(params, "make_current", true)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	var node_name: Variant = Util.text(params, "name", "TopdownCamera")
	var parent_path: Variant = Util.text(params, "parent_path", "")
	var target_path: Variant = Util.text(params, "target_path", "")
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	for v in [make_current, overwrite_scripts, node_name, parent_path, target_path, script_dir]:
		if Util.is_error(v):
			return v
	if String(node_name).is_empty() or _has_any(node_name, [".", ":", "@", "/", "\"", "%"]):
		return Util.error(Util.INVALID_PARAMS, "'name' contains characters not allowed in node names")

	var parent := Util.resolve(parent_path, root)
	if parent == null:
		return Util.error(Util.NODE_NOT_FOUND, "parent_path '%s' not found in the edited scene" % parent_path)
	if parent.get_node_or_null(NodePath(node_name)) != null:
		return Util.error(Util.ALREADY_EXISTS, "'%s' already has a child named '%s'; pass another name or delete it first" % [Util.scene_path_of(parent, root), node_name])

	var target: Node3D = null
	var target_note := ""
	if String(target_path).is_empty():
		target = _find_player(root)
		target_note = "auto: first node in group 'player'" if target != null else "none: no target_path given and no node in group 'player'"
	else:
		var found := Util.resolve(target_path, root)
		if found == null:
			return Util.error(Util.NODE_NOT_FOUND, "target_path '%s' not found in the edited scene" % target_path)
		target = found as Node3D
		if target == null:
			return Util.error(Util.INVALID_PARAMS, "target_path '%s' is a %s; the camera can only follow a Node3D" % [target_path, found.get_class()])
		target_note = "given"

	var installed := Util.install_script("topdown_camera_rig.gd.tmpl", Util.clean_dir(script_dir) + "/topdown_camera_rig.gd", overwrite_scripts)
	if Util.is_error(installed):
		return installed

	var rig := Node3D.new()
	rig.name = node_name
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = values.fov
	camera.current = make_current
	rig.add_child(camera)
	rig.set_script(installed.script)
	rig.top_level = true
	for key in ["pitch_degrees", "distance", "yaw_degrees", "follow_smoothing", "aim_lookahead", "max_lookahead", "lookahead_smoothing"]:
		rig.set(key, values[key])
	if target != null:
		## The rig will be a child of `parent`, so the path starts one level up.
		var rel := parent.get_path_to(target)
		rig.set("target_path", NodePath("..") if String(rel) == "." else NodePath("../" + String(rel)))
		rig.position = target.global_position

	var extra := []
	if make_current:
		for other in _cameras_3d(root):
			if other.current:
				extra.append([other, "current", false, true])
	Util.add_to_scene("Top-down camera setup", parent, rig, root, extra)
	Util.refresh_filesystem([installed.path])

	var data := {
		"rig_path": Util.scene_path_of(rig, root),
		"camera_path": Util.scene_path_of(camera, root),
		"target_path": Util.scene_path_of(target, root) if target != null else "",
		"target": target_note,
		"script": {"path": installed.path, "status": installed.status},
		"settings": values,
		"current": make_current,
		"undo": "One editor undo step removes the rig.",
	}
	if target == null:
		data["next_steps"] = ["Set the rig's target_path to the player node (or rerun with target_path)."]
	return {"data": data}


# =============================================================================
# player_controller_scaffold
# =============================================================================

func player_scaffold(params: Dictionary, _ctx = null) -> Dictionary:
	var values := {}
	for spec in [
		["move_speed", 6.0, 0.1, 100.0],
		["acceleration", 40.0, 0.1, 1000.0],
		["deceleration", 50.0, 0.1, 1000.0],
		["turn_speed", 20.0, 0.0, 200.0],
		["dodge_speed", 14.0, 0.1, 200.0],
		["dodge_duration", 0.25, 0.01, 5.0],
		["dodge_cooldown", 0.6, 0.0, 30.0],
		["max_health", 100.0, 1.0, 100000.0],
		["aim_height", 1.2, 0.0, 10.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	var scene_path: Variant = Util.text(params, "scene_path", DEFAULT_PLAYER_SCENE)
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var action_prefix: Variant = Util.text(params, "action_prefix", "")
	var create_actions: Variant = Util.boolean(params, "create_input_actions", true)
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	var add_to_scene: Variant = Util.boolean(params, "add_to_scene", true)
	var parent_path: Variant = Util.text(params, "parent_path", "")
	var position: Variant = Util.vec3(params, "position", Vector3.ZERO)
	for v in [scene_path, script_dir, action_prefix, create_actions, overwrite, overwrite_scripts, add_to_scene, parent_path, position]:
		if Util.is_error(v):
			return v
	var reason := Util.check_res_path(scene_path, "tscn")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)
	if not String(action_prefix).is_empty() and not String(action_prefix).is_valid_identifier():
		return Util.error(Util.INVALID_PARAMS, "'action_prefix' must be letters, digits and underscores")
	if FileAccess.file_exists(scene_path) and not overwrite:
		return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass overwrite=true to replace it" % scene_path)

	## Resolve the instancing target before writing anything.
	var root := Util.edited_root()
	var parent: Node = null
	var skip_reason := ""
	if add_to_scene:
		if root == null:
			skip_reason = "no scene is open"
		elif root.scene_file_path == scene_path:
			skip_reason = "the open scene is the player scene itself"
		else:
			parent = Util.resolve(parent_path, root)
			if parent == null:
				return Util.error(Util.NODE_NOT_FOUND, "parent_path '%s' not found in the edited scene" % parent_path)

	var installed := Util.install_script("player_controller.gd.tmpl", Util.clean_dir(script_dir) + "/player_controller.gd", overwrite_scripts)
	if Util.is_error(installed):
		return installed

	var actions := {}
	for suffix in INPUT_ACTIONS:
		actions[suffix] = String(action_prefix) + suffix
	var input_report := {}
	if create_actions:
		input_report = _ensure_input_actions(actions)
		if Util.is_error(input_report):
			return input_report

	var player := _build_player(installed.script, values, actions)
	var player_name := String(player.name)
	var save_msg := Util.save_scene(player, scene_path)
	if not save_msg.is_empty():
		return Util.error(Util.INTERNAL_ERROR, save_msg)
	Util.refresh_filesystem([installed.path, scene_path])

	var data := {
		"scene_path": scene_path,
		"script": {"path": installed.path, "status": installed.status},
		"nodes": [player_name, "CollisionShape3D", "Body", "Aim", "Aim/Nose", "Aim/WeaponMount"],
		"settings": values,
		"input_actions": input_report if create_actions else {"skipped": actions.values()},
		"api": "take_damage(amount, info), heal(amount), get_weapon(), is_dodging(); signals health_changed, died, dodged",
	}
	if parent != null:
		var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
		if packed == null:
			return Util.error(Util.INTERNAL_ERROR, "saved %s but cannot load it back" % scene_path)
		var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
		inst.name = Util.unique_child_name(parent, player_name)
		inst.position = position
		Util.add_to_scene("Add player", parent, inst, root)
		data["instance_path"] = Util.scene_path_of(inst, root)
	elif add_to_scene:
		data["instance_path"] = ""
		data["instance_skipped"] = skip_reason
	data["next_steps"] = [
		"topdown_camera_setup to add a follow camera (it finds the player by group).",
		"weapon_create with attach_to set to the player instance to give it a gun.",
		"The scene needs floor collision (e.g. a StaticBody3D) for the player to stand on.",
	]
	return {"data": data}


func _build_player(script: Script, values: Dictionary, actions: Dictionary) -> CharacterBody3D:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(script)
	player.add_to_group(&"player", true)
	for key in values:
		player.set(key, values[key])
	player.set("action_move_left", StringName(actions.move_left))
	player.set("action_move_right", StringName(actions.move_right))
	player.set("action_move_forward", StringName(actions.move_forward))
	player.set("action_move_back", StringName(actions.move_back))
	player.set("action_dodge", StringName(actions.dodge))
	player.set("action_fire", StringName(actions.fire))
	player.set("action_reload", StringName(actions.reload))

	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	player.add_child(shape)

	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.4
	body_mesh.height = 1.8
	body.mesh = body_mesh
	body.position = Vector3(0, 0.9, 0)
	player.add_child(body)

	var aim := Node3D.new()
	aim.name = "Aim"
	player.add_child(aim)

	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.2, 0.2, 0.4)
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.4, -0.45)
	aim.add_child(nose)

	var mount := Node3D.new()
	mount.name = "WeaponMount"
	mount.position = Vector3(0.35, values.aim_height, -0.3)
	aim.add_child(mount)

	Util.own_descendants(player, player)
	return player


## Adds missing input actions to project.godot (existing ones are left as
## they are, so custom bindings survive reruns).
func _ensure_input_actions(actions: Dictionary) -> Variant:
	var created: Array[String] = []
	var kept: Array[String] = []
	for suffix in actions:
		var action: String = actions[suffix]
		var key := "input/" + action
		if ProjectSettings.has_setting(key):
			kept.append(action)
			continue
		var events: Array = []
		for ev_spec in INPUT_ACTIONS[suffix]:
			events.append(_make_event(ev_spec))
		ProjectSettings.set_setting(key, {"deadzone": 0.5, "events": events})
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.5)
			for ev in events:
				InputMap.action_add_event(action, ev)
		created.append(action)
	if not created.is_empty():
		var err := ProjectSettings.save()
		if err != OK:
			return Util.error(Util.INTERNAL_ERROR, "cannot save project.godot: %s" % error_string(err))
	return {"created": created, "kept_existing": kept}


static func _make_event(ev_spec: Array) -> InputEvent:
	if ev_spec[0] == "mouse":
		var mouse := InputEventMouseButton.new()
		mouse.button_index = ev_spec[1]
		return mouse
	var key := InputEventKey.new()
	## Physical keys keep WASD in place on any keyboard layout.
	key.physical_keycode = ev_spec[1]
	return key


# =============================================================================
# weapon_create
# =============================================================================

func weapon_create(params: Dictionary, _ctx = null) -> Dictionary:
	var weapon_id: Variant = Util.text(params, "weapon_id", "")
	if Util.is_error(weapon_id):
		return weapon_id
	if String(weapon_id).is_empty():
		return Util.error(Util.INVALID_PARAMS, "'weapon_id' is required (e.g. \"pistol\")")
	if not String(weapon_id).is_valid_identifier() or String(weapon_id) != String(weapon_id).to_lower():
		return Util.error(Util.INVALID_PARAMS, "'weapon_id' must be lower_snake_case letters, digits and underscores")
	var fire_mode: Variant = Util.text(params, "fire_mode", "hitscan")
	if Util.is_error(fire_mode):
		return fire_mode
	if fire_mode not in ["hitscan", "projectile"]:
		return Util.error(Util.INVALID_PARAMS, "'fire_mode' must be \"hitscan\" or \"projectile\"")

	var stats := {}
	for spec in [
		["damage", 20.0, 0.0, 100000.0],
		["fire_rate", 5.0, 0.01, 100.0],
		["reload_time", 1.5, 0.0, 60.0],
		["spread_degrees", 3.0, 0.0, 180.0],
		["max_range", 50.0, 0.1, 10000.0],
		["projectile_speed", 40.0, 0.1, 10000.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		stats[spec[0]] = v
	for spec in [["magazine_size", 12, 1, 10000], ["pellets", 1, 1, 64], ["collision_mask", 1, 1, 4294967295]]:
		var v: Variant = Util.integer(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		stats[spec[0]] = v
	for spec in [["automatic", false], ["auto_reload", true]]:
		var v: Variant = Util.boolean(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		stats[spec[0]] = v
	var display_name: Variant = Util.text(params, "display_name", String(weapon_id).capitalize())
	var data_dir: Variant = Util.text(params, "data_dir", DEFAULT_WEAPON_DATA_DIR)
	var scene_dir: Variant = Util.text(params, "scene_dir", DEFAULT_WEAPON_SCENE_DIR)
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var attach_to: Variant = Util.text(params, "attach_to", "")
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	for v in [display_name, data_dir, scene_dir, script_dir, attach_to, overwrite, overwrite_scripts]:
		if Util.is_error(v):
			return v

	var data_path: String = Util.clean_dir(data_dir) + "/" + weapon_id + ".tres"
	var scene_path: String = Util.clean_dir(scene_dir) + "/" + weapon_id + ".tscn"
	var projectile_path: String = Util.clean_dir(scene_dir) + "/projectile.tscn"
	for p in [data_path, scene_path]:
		var reason := Util.check_res_path(p)
		if not reason.is_empty():
			return Util.error(Util.INVALID_PARAMS, reason)
		if FileAccess.file_exists(p) and not overwrite:
			return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass overwrite=true to replace it or pick another weapon_id" % p)

	## Resolve the attach point before writing anything.
	var root := Util.edited_root()
	var mount: Node = null
	if not String(attach_to).is_empty():
		if root == null:
			return Util.no_scene_error()
		var found := Util.resolve(attach_to, root)
		if found == null:
			return Util.error(Util.NODE_NOT_FOUND, "attach_to '%s' not found in the edited scene" % attach_to)
		mount = found.get_node_or_null("Aim/WeaponMount")
		if mount == null:
			mount = found

	var scripts := {}
	for pair in [["weapon_data", "weapon_data.gd.tmpl"], ["weapon", "weapon.gd.tmpl"], ["projectile", "projectile.gd.tmpl"]]:
		if pair[0] == "projectile" and fire_mode != "projectile":
			continue
		var installed := Util.install_script(pair[1], Util.clean_dir(script_dir) + "/" + pair[1].trim_suffix(".tmpl"), overwrite_scripts)
		if Util.is_error(installed):
			return installed
		scripts[pair[0]] = installed
	var written: Array = []
	for key in scripts:
		written.append(scripts[key].path)

	var projectile_status := ""
	var projectile_scene: PackedScene = null
	if fire_mode == "projectile":
		if FileAccess.file_exists(projectile_path) and not overwrite:
			projectile_status = "kept"
		else:
			projectile_status = "overwritten" if FileAccess.file_exists(projectile_path) else "created"
			var msg := Util.save_scene(_build_projectile(scripts.projectile.script), projectile_path)
			if not msg.is_empty():
				return Util.error(Util.INTERNAL_ERROR, msg)
			written.append(projectile_path)
		projectile_scene = ResourceLoader.load(projectile_path, "PackedScene") as PackedScene

	var data_res := Resource.new()
	data_res.set_script(scripts.weapon_data.script)
	data_res.set("weapon_id", weapon_id)
	data_res.set("display_name", display_name)
	data_res.set("fire_mode", fire_mode)
	for key in stats:
		data_res.set(key, stats[key])
	data_res.set("projectile_scene", projectile_scene)
	var data_msg := Util.save_resource(data_res, data_path)
	if not data_msg.is_empty():
		return Util.error(Util.INTERNAL_ERROR, data_msg)
	written.append(data_path)

	var weapon := _build_weapon(scripts.weapon.script, data_res, weapon_id)
	var scene_msg := Util.save_scene(weapon, scene_path)
	if not scene_msg.is_empty():
		return Util.error(Util.INTERNAL_ERROR, scene_msg)
	written.append(scene_path)
	Util.refresh_filesystem(written)

	var script_report := {}
	for key in scripts:
		script_report[key] = {"path": scripts[key].path, "status": scripts[key].status}
	var data := {
		"weapon_id": weapon_id,
		"data_path": data_path,
		"scene_path": scene_path,
		"fire_mode": fire_mode,
		"stats": stats,
		"scripts": script_report,
		"api": "try_fire(aim_point) -> bool, reload() -> bool, ammo; signals fired, hit, empty, reload_started, reload_finished. Targets take damage via take_damage(amount, info).",
	}
	if fire_mode == "projectile":
		data["projectile_scene"] = {"path": projectile_path, "status": projectile_status}
	if mount != null:
		var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
		if packed == null:
			return Util.error(Util.INTERNAL_ERROR, "saved %s but cannot load it back" % scene_path)
		var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		inst.name = Util.unique_child_name(mount, _pascal(weapon_id))
		Util.add_to_scene("Attach weapon %s" % weapon_id, mount, inst, root)
		data["instance_path"] = Util.scene_path_of(inst, root)
		if mount.get_child_count() > 1:
			data["note"] = "The player fires the first weapon under the mount; remove or reorder others."
	return {"data": data}


func _build_weapon(script: Script, data_res: Resource, weapon_id: String) -> Node3D:
	var weapon := Node3D.new()
	weapon.name = _pascal(weapon_id)
	weapon.set_script(script)
	weapon.set("data", data_res)

	var model := MeshInstance3D.new()
	model.name = "Model"
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 0.12, 0.6)
	model.mesh = box
	model.position = Vector3(0, 0, -0.3)
	weapon.add_child(model)

	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0, -0.65)
	weapon.add_child(muzzle)

	Util.own_descendants(weapon, weapon)
	return weapon


func _build_projectile(script: Script) -> Node3D:
	var projectile := Node3D.new()
	projectile.name = "Projectile"
	projectile.set_script(script)
	var model := MeshInstance3D.new()
	model.name = "Model"
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	model.mesh = sphere
	projectile.add_child(model)
	Util.own_descendants(projectile, projectile)
	return projectile


# =============================================================================
# enemy_ai_scaffold
# =============================================================================

func enemy_scaffold(params: Dictionary, _ctx = null) -> Dictionary:
	var enemy_id: Variant = Util.text(params, "enemy_id", "")
	if Util.is_error(enemy_id):
		return enemy_id
	if String(enemy_id).is_empty():
		return Util.error(Util.INVALID_PARAMS, "'enemy_id' is required (e.g. \"grunt\")")
	if not String(enemy_id).is_valid_identifier() or String(enemy_id) != String(enemy_id).to_lower():
		return Util.error(Util.INVALID_PARAMS, "'enemy_id' must be lower_snake_case letters, digits and underscores")
	var attack_mode: Variant = Util.text(params, "attack_mode", "melee")
	if Util.is_error(attack_mode):
		return attack_mode
	if attack_mode not in ["melee", "ranged"]:
		return Util.error(Util.INVALID_PARAMS, "'attack_mode' must be \"melee\" or \"ranged\"")
	var ranged: bool = attack_mode == "ranged"

	var values := {}
	for spec in [
		["max_health", 60.0, 1.0, 100000.0],
		["patrol_speed", 2.5, 0.0, 100.0],
		["chase_speed", 4.5, 0.1, 100.0],
		["sight_range", 15.0, 0.5, 1000.0],
		["sight_angle_degrees", 110.0, 1.0, 360.0],
		["proximity_radius", 2.5, 0.0, 100.0],
		["attack_range", 12.0 if ranged else 1.8, 0.3, 1000.0],
		["attack_damage", 10.0, 0.0, 100000.0],
		["attack_cooldown", 0.8 if ranged else 1.0, 0.0, 60.0],
		["attack_windup", 0.35, 0.0, 10.0],
		["lose_sight_time", 3.0, 0.0, 60.0],
		["search_time", 4.0, 0.0, 60.0],
		["alert_radius", 8.0, 0.0, 1000.0],
		["wander_radius", 6.0, 0.0, 1000.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		values[spec[0]] = v
	var target_group: Variant = Util.text(params, "target_group", "player")
	var weapon_scene: Variant = Util.text(params, "weapon_scene", "")
	var scene_dir: Variant = Util.text(params, "scene_dir", DEFAULT_ENEMY_SCENE_DIR)
	var script_dir: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	var add_to_scene: Variant = Util.boolean(params, "add_to_scene", true)
	var parent_path: Variant = Util.text(params, "parent_path", "")
	var setup_navigation: Variant = Util.boolean(params, "setup_navigation", true)
	var overwrite: Variant = Util.boolean(params, "overwrite", false)
	var overwrite_scripts: Variant = Util.boolean(params, "overwrite_scripts", false)
	for v in [target_group, weapon_scene, scene_dir, script_dir, add_to_scene, parent_path, setup_navigation, overwrite, overwrite_scripts]:
		if Util.is_error(v):
			return v
	if String(target_group).is_empty():
		return Util.error(Util.INVALID_PARAMS, "'target_group' must not be empty")
	var positions: Variant = _vec3_list(params, "positions", [Vector3(0, 0, -8)])
	if Util.is_error(positions):
		return positions
	if positions.is_empty() or positions.size() > 64:
		return Util.error(Util.INVALID_PARAMS, "'positions' needs 1 to 64 [x, y, z] entries")
	var patrol_points: Variant = _vec3_list(params, "patrol_points", [])
	if Util.is_error(patrol_points):
		return patrol_points

	var weapon_packed: PackedScene = null
	if not String(weapon_scene).is_empty():
		if not ranged:
			return Util.error(Util.INVALID_PARAMS, "'weapon_scene' only applies to attack_mode \"ranged\"")
		if not String(weapon_scene).begins_with("res://") or String(weapon_scene).get_extension() != "tscn":
			return Util.error(Util.INVALID_PARAMS, "'weapon_scene' must be a res:// .tscn (e.g. one made by weapon_create)")
		if not ResourceLoader.exists(weapon_scene):
			return Util.error(Util.NODE_NOT_FOUND, "weapon_scene %s does not exist; create it with weapon_create first" % weapon_scene)
		weapon_packed = ResourceLoader.load(weapon_scene, "PackedScene") as PackedScene
		if weapon_packed == null:
			return Util.error(Util.INVALID_PARAMS, "weapon_scene %s is not a scene" % weapon_scene)

	var scene_path: String = Util.clean_dir(scene_dir) + "/" + enemy_id + ".tscn"
	var reason := Util.check_res_path(scene_path, "tscn")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, reason)
	if FileAccess.file_exists(scene_path) and not overwrite:
		return Util.error(Util.ALREADY_EXISTS, "%s already exists; pass overwrite=true to replace it or pick another enemy_id" % scene_path)

	## Resolve the placement target before writing anything.
	var root := Util.edited_root()
	var parent: Node = null
	var skip_reason := ""
	if add_to_scene:
		if root == null:
			skip_reason = "no scene is open"
		elif root.scene_file_path == scene_path:
			skip_reason = "the open scene is the enemy scene itself"
		elif not root is Node3D:
			skip_reason = "the open scene's root is not a 3D node"
		else:
			parent = Util.resolve(parent_path, root)
			if parent == null:
				return Util.error(Util.NODE_NOT_FOUND, "parent_path '%s' not found in the edited scene" % parent_path)

	var installed := Util.install_script("enemy_ai.gd.tmpl", Util.clean_dir(script_dir) + "/enemy_ai.gd", overwrite_scripts)
	if Util.is_error(installed):
		return installed

	var enemy := _build_enemy(installed.script, values, attack_mode, target_group, enemy_id, weapon_packed)
	var save_msg := Util.save_scene(enemy, scene_path)
	if not save_msg.is_empty():
		return Util.error(Util.INTERNAL_ERROR, save_msg)
	Util.refresh_filesystem([installed.path, scene_path])

	var data := {
		"enemy_id": enemy_id,
		"scene_path": scene_path,
		"script": {"path": installed.path, "status": installed.status},
		"attack_mode": attack_mode,
		"weapon_scene": weapon_scene,
		"target_group": target_group,
		"settings": values,
		"states": ["PATROL", "CHASE", "ATTACK", "SEARCH", "DEAD"],
		"api": "take_damage(amount, info), heal(amount), alert(target, position), can_see(node), think(delta), get_state_name(); signals state_changed, target_spotted, target_lost, attack_started, attacked, health_changed, died",
	}
	if parent == null:
		data["instances"] = []
		if add_to_scene:
			data["instance_skipped"] = skip_reason
		return {"data": data}

	var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if packed == null:
		return Util.error(Util.INTERNAL_ERROR, "saved %s but cannot load it back" % scene_path)
	var items := []
	var taken := {}
	for pos in positions:
		var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
		inst.name = _unique_name(parent, _pascal(enemy_id), taken)
		taken[String(inst.name)] = true
		inst.position = pos
		if not patrol_points.is_empty():
			inst.set("patrol_points", PackedVector3Array(patrol_points))
		items.append([parent, inst])

	var nav_report := {"status": "skipped"}
	var region: NavigationRegion3D = null
	var calls := []
	if setup_navigation:
		var existing := _navigation_regions(root)
		if existing.is_empty():
			region = _build_nav_region(Util.unique_child_name(root, "Navigation"))
			items.append([root, region])
			if not root.is_in_group(NAV_SOURCE_GROUP):
				calls.append([root, "add_to_group", [NAV_SOURCE_GROUP, true], "remove_from_group", [NAV_SOURCE_GROUP]])
		else:
			nav_report = {
				"status": "existing",
				"region_path": Util.scene_path_of(existing[0], root),
				"note": "Kept the scene's NavigationRegion3D. Rebake it (Bake NavigationMesh) after changing the level.",
			}

	var label := "Add enemy %s" % enemy_id if positions.size() == 1 else "Add %d %s enemies" % [positions.size(), enemy_id]
	Util.add_nodes_to_scene(label, items, root, [], calls)

	var instance_paths := []
	for item in items:
		if item[1] != region:
			instance_paths.append(Util.scene_path_of(item[1], root))
	data["instances"] = instance_paths
	if region != null:
		nav_report = _bake_region(region, root)
	data["navigation"] = nav_report
	var steps := []
	if nav_report.get("polygons", 1) == 0:
		steps.append("The navigation mesh is empty: add floor collision (a StaticBody3D) and press Bake NavigationMesh on %s. Enemies steer straight at their goal until then." % nav_report.region_path)
	if ranged and weapon_packed == null:
		steps.append("No weapon_scene: the enemy fires its own ray (attack_damage per shot). Pass a weapon from weapon_create to use its rate, ammo and spread.")
	if patrol_points.is_empty():
		steps.append("No patrol_points: each enemy wanders within wander_radius of where it stands. Set patrol_points on an instance for a route.")
	data["next_steps"] = steps
	return {"data": data}


func _build_enemy(script: Script, values: Dictionary, attack_mode: String, target_group: String, enemy_id: String, weapon_packed: PackedScene) -> CharacterBody3D:
	var enemy := CharacterBody3D.new()
	enemy.name = _pascal(enemy_id)
	enemy.set_script(script)
	enemy.add_to_group(&"enemy", true)
	for key in values:
		enemy.set(key, values[key])
	enemy.set("attack_mode", attack_mode)
	enemy.set("target_group", StringName(target_group))

	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	enemy.add_child(shape)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.25, 0.2) if attack_mode == "melee" else Color(0.9, 0.55, 0.15)
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = 0.4
	body_mesh.height = 1.8
	body_mesh.material = material
	body.mesh = body_mesh
	body.position = Vector3(0, 0.9, 0)
	enemy.add_child(body)

	## Shows which way the enemy faces (and so where its vision cone points).
	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.2, 0.2, 0.4)
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.4, -0.45)
	enemy.add_child(nose)

	var mount := Node3D.new()
	mount.name = "WeaponMount"
	mount.position = Vector3(0.35, 1.2, -0.3)
	enemy.add_child(mount)

	var agent := NavigationAgent3D.new()
	agent.name = "NavigationAgent3D"
	agent.path_desired_distance = 0.5
	agent.target_desired_distance = 0.5
	agent.radius = 0.4
	agent.height = 1.8
	enemy.add_child(agent)

	Util.own_descendants(enemy, enemy)
	if weapon_packed != null:
		## An instanced child: only its root is owned by the enemy, so the
		## enemy scene stores a link to the weapon scene, not a copy.
		var weapon := weapon_packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		mount.add_child(weapon)
		weapon.owner = enemy
	return enemy


## A NavigationRegion3D whose mesh is built from the static colliders under
## nodes in NAV_SOURCE_GROUP (the scene root joins it), so the editor's own
## Bake NavigationMesh button keeps working after the level changes.
func _build_nav_region(region_name: String) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.name = region_name
	var nav := NavigationMesh.new()
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav.geometry_source_group_name = NAV_SOURCE_GROUP
	nav.agent_radius = 0.5
	## A multiple of the default cell_height (0.25) so the bake keeps it exact.
	nav.agent_height = 1.75
	region.navigation_mesh = nav
	return region


func _bake_region(region: NavigationRegion3D, root: Node) -> Dictionary:
	region.bake_navigation_mesh(false)
	var polygons := region.navigation_mesh.get_polygon_count() if region.navigation_mesh != null else 0
	return {
		"status": "created",
		"region_path": Util.scene_path_of(region, root),
		"source_group": String(NAV_SOURCE_GROUP),
		"polygons": polygons,
		"note": "Baked from static colliders in the scene. Rebake (Bake NavigationMesh) after changing the level; undo removes the region.",
	}


static func _navigation_regions(root: Node) -> Array:
	var out := []
	if root is NavigationRegion3D:
		out.append(root)
	out.append_array(root.find_children("*", "NavigationRegion3D", true, false))
	return out


## Reads an optional list of [x, y, z] points.
static func _vec3_list(params: Dictionary, key: String, default_value: Array) -> Variant:
	if not params.has(key) or params[key] == null:
		return default_value
	if not params[key] is Array:
		return Util.error(Util.INVALID_PARAMS, "'%s' must be a list of [x, y, z] points" % key)
	var out := []
	for i in params[key].size():
		var v: Variant = Util.vec3({"p": params[key][i]}, "p", Vector3.ZERO)
		if Util.is_error(v):
			return Util.error(Util.INVALID_PARAMS, "'%s[%d]' must be [x, y, z] numbers" % [key, i])
		out.append(v)
	return out


static func _unique_name(parent: Node, wanted: String, taken: Dictionary) -> String:
	if parent.get_node_or_null(NodePath(wanted)) == null and not taken.has(wanted):
		return wanted
	var i := 2
	while parent.get_node_or_null(NodePath("%s%d" % [wanted, i])) != null or taken.has("%s%d" % [wanted, i]):
		i += 1
	return "%s%d" % [wanted, i]


# =============================================================================
# helpers
# =============================================================================

static func _find_player(root: Node) -> Node3D:
	if root.is_in_group(&"player") and root is Node3D:
		return root
	for node in root.find_children("*", "Node3D", true, false):
		if node.is_in_group(&"player"):
			return node
	return null


static func _cameras_3d(root: Node) -> Array:
	var out := []
	if root is Camera3D:
		out.append(root)
	out.append_array(root.find_children("*", "Camera3D", true, false))
	return out


static func _has_any(value: String, chars: Array) -> bool:
	for c in chars:
		if value.contains(c):
			return true
	return false


static func _pascal(snake: String) -> String:
	return snake.to_pascal_case()
