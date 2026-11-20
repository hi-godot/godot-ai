@tool
extends McpTestSuite

## Tests for the top-down shooter custom tools. Run them with
## extensions/topdown_shooter/script/link-test-project, which links the
## addon and this suite into test_project/ for the Godot AI test runner.
##
## Files are written under res://zz_mcp_test_topdown/ and removed afterwards.
## Generated game scripts are not @tool, so the editor only holds
## placeholder instances of them; logic tests run a @tool copy instead.
## Input actions use a unique prefix and are removed from project.godot.

const Tools := preload("res://addons/topdown_shooter_tools/handlers/topdown_tools.gd")
const ItemTools := preload("res://addons/topdown_shooter_tools/handlers/item_tools.gd")
const LootTools := preload("res://addons/topdown_shooter_tools/handlers/loot_tools.gd")
const InventoryTools := preload("res://addons/topdown_shooter_tools/handlers/inventory_tools.gd")
const RaidTools := preload("res://addons/topdown_shooter_tools/handlers/raid_tools.gd")
const PlaytestTools := preload("res://addons/topdown_shooter_tools/handlers/playtest_tools.gd")
const HideoutTools := preload("res://addons/topdown_shooter_tools/handlers/hideout_tools.gd")
const NotesTools := preload("res://addons/topdown_shooter_tools/handlers/notes_tools.gd")
const FeedbackTools := preload("res://addons/topdown_shooter_tools/handlers/feedback_tools.gd")
const ToolSpecs := preload("res://addons/topdown_shooter_tools/tool_specs.gd")

const WORK_DIR := "res://zz_mcp_test_topdown"
const ACTION_PREFIX := "mcp_test_td_"

var _tools: Tools
var _items: ItemTools
var _loot: LootTools
var _inventory: InventoryTools
var _raid: RaidTools
var _playtest: PlaytestTools
var _hideout: HideoutTools
var _main_scene_before := ""
var _notes: NotesTools
var _feedback: FeedbackTools
var _undo_redo: EditorUndoRedoManager
var _added: Array[Node] = []


func suite_name() -> String:
	return "topdown_shooter"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_tools = Tools.new()
	_items = ItemTools.new()
	_loot = LootTools.new()
	_inventory = InventoryTools.new()
	_raid = RaidTools.new()
	_playtest = PlaytestTools.new()
	_hideout = HideoutTools.new()
	_main_scene_before = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	_notes = NotesTools.new()
	_feedback = FeedbackTools.new()
	_notes.notes_dir = WORK_DIR + "/notes/"
	if EditorInterface.get_edited_scene_root() == null:
		skip_suite("needs an open scene")


func teardown() -> void:
	for node in _added:
		if is_instance_valid(node) and node.get_parent() != null:
			node.get_parent().remove_child(node)
			node.queue_free()
	_added.clear()


func suite_teardown() -> void:
	teardown()
	_remove_tree(ProjectSettings.globalize_path(WORK_DIR))
	var changed := false
	for suffix in Tools.INPUT_ACTIONS.keys() + ["inventory", "interact"]:
		var action: String = ACTION_PREFIX + suffix
		if ProjectSettings.has_setting("input/" + action):
			ProjectSettings.clear("input/" + action)
			changed = true
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	if ProjectSettings.has_setting(PlaytestTools.autoload_key()) and str(ProjectSettings.get_setting(PlaytestTools.autoload_key())).contains(WORK_DIR):
		ProjectSettings.set_setting(PlaytestTools.autoload_key(), null)
		changed = true
	## hideout_scaffold settings left by a failed test.
	if str(ProjectSettings.get_setting("autoload/" + HideoutTools.AUTOLOAD_NAME, "")).contains(WORK_DIR):
		ProjectSettings.set_setting("autoload/" + HideoutTools.AUTOLOAD_NAME, null)
		changed = true
	if str(ProjectSettings.get_setting(HideoutTools.SETTINGS_PREFIX + "raid_scene", "")).contains(WORK_DIR):
		for key in ["hideout_scene", "menu_scene", "raid_scene", "save_path", "item_database", "return_delay", "quit_counts_as_death", "track_direct_raids", "starting_stash"]:
			ProjectSettings.set_setting(HideoutTools.SETTINGS_PREFIX + key, null)
		changed = true
	if str(ProjectSettings.get_setting("application/run/main_scene", "")).contains(WORK_DIR):
		ProjectSettings.set_setting("application/run/main_scene", _main_scene_before)
		changed = true
	_remove_tree(ProjectSettings.globalize_path(HIDEOUT_SAVE.get_base_dir()))
	if ProjectSettings.has_setting(NotesTools.autoload_key()) and str(ProjectSettings.get_setting(NotesTools.autoload_key())).contains(WORK_DIR):
		ProjectSettings.set_setting(NotesTools.autoload_key(), null)
		changed = true
	if changed:
		ProjectSettings.save()


func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _track(path: String) -> Node:
	var node := McpScenePath.resolve(path, _root())
	if node != null:
		_added.append(node)
	return node


func _remove_tree(abs_path: String) -> void:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(abs_path.path_join(sub))
	for file in dir.get_files():
		DirAccess.remove_absolute(abs_path.path_join(file))
	DirAccess.remove_absolute(abs_path)


func _player_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"scene_path": WORK_DIR + "/player/player.tscn",
		"script_dir": WORK_DIR + "/scripts",
		"action_prefix": ACTION_PREFIX,
		"overwrite": true,
	}
	params.merge(extra, true)
	return params


func _weapon_params(id: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"weapon_id": id,
		"data_dir": WORK_DIR + "/data",
		"scene_dir": WORK_DIR + "/weapons",
		"script_dir": WORK_DIR + "/scripts",
		"overwrite": true,
	}
	params.merge(extra, true)
	return params


# --- specs -------------------------------------------------------------------

func test_specs_validate() -> void:
	var specs := ToolSpecs.build()
	assert_eq(specs.size(), 12)
	var names := []
	for spec in specs:
		assert_eq(spec.validate(), [] as Array[String], "spec %s" % spec.name)
		assert_true(spec.promoted)
		## The playtest runs while the game plays, so it must not be gated.
		## playtest_notes is read while the game runs, so it is not gated either.
		assert_eq(spec.requires_writable, not spec.name in ["raid_playtest", "playtest_notes"], "requires_writable of %s" % spec.name)
		assert_eq(spec.deferred, spec.name == "raid_playtest", "deferred of %s" % spec.name)
		names.append(spec.name)
	assert_eq(names, ["topdown_camera_setup", "player_controller_scaffold", "weapon_create", "combat_feedback_setup", "enemy_ai_scaffold", "item_db_import", "loot_table_edit", "inventory_ui_scaffold", "raid_map_blockout", "raid_playtest", "playtest_notes", "hideout_scaffold"])


# --- player ------------------------------------------------------------------

func test_player_scaffold_writes_scene_script_and_actions() -> void:
	var result := _tools.player_scaffold(_player_params({"add_to_scene": false, "move_speed": 7.5}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_true(FileAccess.file_exists(data.scene_path))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/player_controller.gd"))
	assert_eq(data.input_actions.created.size() + data.input_actions.kept_existing.size(), Tools.INPUT_ACTIONS.size())
	assert_true(InputMap.has_action(ACTION_PREFIX + "fire"))
	assert_true(ProjectSettings.has_setting("input/" + ACTION_PREFIX + "move_left"))

	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_true(packed != null, "player scene loads")
	var player := packed.instantiate()
	assert_true(player is CharacterBody3D)
	assert_true(player.get_node_or_null("Aim/WeaponMount") != null)
	assert_true(player.get_node_or_null("CollisionShape3D") != null)
	assert_true(player.is_in_group(&"player"))
	assert_eq(player.get("move_speed"), 7.5)
	assert_eq(player.get("action_fire"), StringName(ACTION_PREFIX + "fire"))
	player.free()


func test_player_scaffold_instances_into_scene_with_undo() -> void:
	var result := _tools.player_scaffold(_player_params({"position": [1, 0, 2]}))
	assert_has_key(result, "data", str(result))
	var inst := _track(result.data.instance_path)
	assert_true(inst != null, "instance exists at %s" % result.data.instance_path)
	assert_eq((inst as Node3D).position, Vector3(1, 0, 2))
	assert_eq(inst.owner, _root())
	assert_true(editor_undo(_undo_redo))
	assert_true(not is_instance_valid(inst) or inst.get_parent() == null, "undo removes the instance")


func test_player_scaffold_refuses_existing_scene_without_overwrite() -> void:
	_tools.player_scaffold(_player_params({"add_to_scene": false}))
	var result := _tools.player_scaffold(_player_params({"add_to_scene": false, "overwrite": false}))
	assert_is_error(result, "ALREADY_EXISTS")


func test_player_scaffold_rejects_bad_params() -> void:
	assert_is_error(_tools.player_scaffold(_player_params({"move_speed": "fast"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"scene_path": "res://addons/x/p.tscn"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"scene_path": "/tmp/p.tscn"})), "INVALID_PARAMS")
	assert_is_error(_tools.player_scaffold(_player_params({"action_prefix": "bad-prefix"})), "INVALID_PARAMS")


# --- camera ------------------------------------------------------------------

func test_camera_setup_follows_given_target() -> void:
	var player_result := _tools.player_scaffold(_player_params({"position": [3, 0, -4]}))
	var player := _track(player_result.data.instance_path)
	var result := _tools.camera_setup({
		"target_path": player_result.data.instance_path,
		"script_dir": WORK_DIR + "/scripts",
		"name": "TestFollowCam",
		"pitch_degrees": 60.0,
		"distance": 10.0,
	})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path) as Node3D
	assert_true(rig != null)
	assert_eq(rig.get_node_or_null(rig.get("target_path")), player, "target_path resolves to the player")
	assert_true(rig.top_level)
	var cam := rig.get_node("Camera3D") as Camera3D
	assert_true(cam.current)
	assert_true(rig.global_position.is_equal_approx(Vector3(3, 0, -4)), "rig snaps onto the target")
	var expected := Vector3(0, sin(deg_to_rad(60.0)) * 10.0, cos(deg_to_rad(60.0)) * 10.0)
	assert_true(cam.position.is_equal_approx(expected), "arm %s vs %s" % [cam.position, expected])
	## Camera looks back at the rig origin.
	var forward := -cam.global_basis.z
	var to_rig := (rig.global_position - cam.global_position).normalized()
	assert_true(forward.is_equal_approx(to_rig), "camera faces the target")


func test_camera_setup_auto_finds_player_group() -> void:
	var player_result := _tools.player_scaffold(_player_params())
	var player := _track(player_result.data.instance_path)
	var result := _tools.camera_setup({"script_dir": WORK_DIR + "/scripts", "name": "TestAutoCam"})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path)
	## The open scene may already hold another player; any group member counts.
	var target := rig.get_node_or_null(rig.get("target_path"))
	assert_true(target != null and target.is_in_group(&"player"), "rig follows a node in group 'player'")
	assert_eq(result.data.target_path, McpScenePath.from_node(target, _root()))
	assert_true(player != null)


func test_camera_setup_undo_restores_previous_current_camera() -> void:
	var existing := Camera3D.new()
	existing.name = "ExistingCam"
	_root().add_child(existing)
	existing.owner = _root()
	existing.current = true
	_added.append(existing)
	var result := _tools.camera_setup({"script_dir": WORK_DIR + "/scripts", "name": "TestUndoCam", "target_path": "ExistingCam"})
	assert_has_key(result, "data", str(result))
	var rig := _track(result.data.rig_path)
	assert_false(existing.current, "new rig camera takes over")
	assert_true(editor_undo(_undo_redo))
	assert_true(existing.current, "undo gives current back")
	assert_true(not is_instance_valid(rig) or rig.get_parent() == null, "undo removes the rig")


func test_camera_setup_errors() -> void:
	var base := {"name": "TestErrCam", "script_dir": WORK_DIR + "/scripts"}
	assert_is_error(_tools.camera_setup(base.merged({"target_path": "Nope"})), "NODE_NOT_FOUND", "missing target")
	assert_is_error(_tools.camera_setup(base.merged({"pitch_degrees": 5})), "INVALID_PARAMS", "pitch out of range")
	assert_is_error(_tools.camera_setup(base.merged({"parent_path": "Nope"})), "NODE_NOT_FOUND", "missing parent")
	assert_is_error(_tools.camera_setup(base.merged({"name": "Bad/Name"}, true)), "INVALID_PARAMS", "bad node name")


# --- weapon ------------------------------------------------------------------

func test_weapon_create_hitscan_files() -> void:
	var result := _tools.weapon_create(_weapon_params("test_pistol", {"damage": 25, "magazine_size": 7}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	var res := ResourceLoader.load(data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(res != null, "weapon data loads")
	assert_eq(res.get("damage"), 25.0)
	assert_eq(res.get("magazine_size"), 7)
	assert_eq(res.get("fire_mode"), "hitscan")
	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var weapon := packed.instantiate()
	assert_true(weapon.get_node_or_null("Muzzle") is Marker3D)
	assert_true(weapon.get("data") != null, "scene references the data resource")
	assert_false(data.scripts.has("projectile"))
	weapon.free()


func test_weapon_create_projectile_reuses_shared_scene() -> void:
	var first := _tools.weapon_create(_weapon_params("test_launcher", {"fire_mode": "projectile", "projectile_speed": 30}))
	assert_has_key(first, "data", str(first))
	assert_true(FileAccess.file_exists(first.data.projectile_scene.path))
	var res := ResourceLoader.load(first.data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(res.get("projectile_scene") is PackedScene)
	var second := _tools.weapon_create(_weapon_params("test_launcher2", {"fire_mode": "projectile", "overwrite": false}))
	assert_has_key(second, "data", str(second))
	assert_eq(second.data.projectile_scene.status, "kept")
	assert_eq(second.data.scripts.weapon.status, "kept")


func test_weapon_fire_cooldown_ammo_and_reload() -> void:
	var result := _tools.weapon_create(_weapon_params("test_smg", {"magazine_size": 2, "fire_rate": 10, "reload_time": 0.5, "auto_reload": false}))
	assert_has_key(result, "data", str(result))
	var weapon := _tool_weapon(result.data)
	assert_eq(weapon.ammo, 2)
	var aim := weapon.global_position + Vector3(0, 0, -10)
	assert_true(weapon.try_fire(aim), "first shot fires")
	assert_false(weapon.try_fire(aim), "cooldown blocks the next shot")
	weapon._physics_process(0.2)
	assert_true(weapon.try_fire(aim), "second shot after cooldown")
	weapon._physics_process(0.2)
	assert_false(weapon.try_fire(aim), "empty magazine")
	assert_eq(weapon.ammo, 0)
	assert_true(weapon.reload())
	assert_true(weapon.is_reloading())
	weapon._physics_process(0.6)
	assert_eq(weapon.ammo, 2, "reload refills the magazine")


func test_weapon_hitscan_damages_target() -> void:
	var result := _tools.weapon_create(_weapon_params("test_rail", {"damage": 40, "spread_degrees": 0}))
	assert_has_key(result, "data", str(result))
	var weapon := _tool_weapon(result.data)
	var target := StaticBody3D.new()
	target.name = "DamageTarget"
	target.set_script(_damage_receiver_script())
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 1)
	shape.shape = box
	target.add_child(shape)
	_root().add_child(target)
	_added.append(target)
	target.global_position = weapon.global_position + Vector3(0, 0, -5)
	## Let the physics server pick up the new body's transform.
	PhysicsServer3D.body_set_state(target.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target.global_transform)
	assert_true(weapon.try_fire(target.global_position))
	assert_eq(target.received, 40.0, "hitscan ray delivered damage")


## Instantiates the weapon with a @tool copy of its script so its methods
## run inside the editor, and adds it to the edited scene.
func _tool_weapon(data: Dictionary) -> Node3D:
	var res := ResourceLoader.load(data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var weapon := Node3D.new()
	weapon.name = "ToolWeapon"
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	weapon.add_child(muzzle)
	weapon.set_script(_tool_copy(data.scripts.weapon.path))
	weapon.set("data", res)
	_root().add_child(weapon)
	_added.append(weapon)
	weapon.set_physics_process(false)
	## Far above whatever geometry the open scene has.
	weapon.global_position = Vector3(0, 500, 0)
	return weapon


func _tool_copy(path: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\n" + FileAccess.get_file_as_string(path)
	assert_eq(script.reload(), OK, "tool copy of %s compiles" % path)
	return script


func _damage_receiver_script() -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\nextends StaticBody3D\nvar received := 0.0\nfunc take_damage(amount: float, _info: Dictionary = {}) -> void:\n\treceived += amount\n"
	script.reload()
	return script


func test_weapon_attach_to_player_mount() -> void:
	var player_result := _tools.player_scaffold(_player_params())
	var player := _track(player_result.data.instance_path)
	var result := _tools.weapon_create(_weapon_params("test_rifle", {"attach_to": player_result.data.instance_path}))
	assert_has_key(result, "data", str(result))
	var inst := McpScenePath.resolve(result.data.instance_path, _root())
	assert_true(inst != null)
	assert_eq(inst.get_parent(), player.get_node("Aim/WeaponMount"))
	assert_eq(inst.owner, _root())
	assert_true(_root().is_editable_instance(player), "player instance gets Editable Children so the weapon is saved")
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root()), OK)
	var state := packed.get_state()
	var saved := false
	for i in state.get_node_count():
		if String(state.get_node_name(i)) == String(inst.name) and String(state.get_node_path(i, true)).ends_with("WeaponMount"):
			saved = true
	assert_true(saved, "packing the edited scene keeps the attached weapon")
	assert_true(editor_undo(_undo_redo))
	assert_false(_root().is_editable_instance(player), "undo turns Editable Children back off")


func test_weapon_create_rejects_bad_params() -> void:
	assert_is_error(_tools.weapon_create({}), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("Bad-Id")), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"fire_mode": "laser"})), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"pellets": 1.5})), "INVALID_PARAMS")
	assert_is_error(_tools.weapon_create(_weapon_params("ok_id", {"attach_to": "Nope"})), "NODE_NOT_FOUND")


# --- enemy -------------------------------------------------------------------

const TARGET_GROUP := &"mcp_test_td_target"


func _enemy_params(id: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"enemy_id": id,
		"scene_dir": WORK_DIR + "/enemies",
		"script_dir": WORK_DIR + "/scripts",
		"overwrite": true,
		"add_to_scene": false,
	}
	params.merge(extra, true)
	return params


func test_enemy_scaffold_writes_scene() -> void:
	var result := _tools.enemy_scaffold(_enemy_params("test_grunt", {"max_health": 80, "sight_angle_degrees": 90}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/enemy_ai.gd"))
	assert_eq(data.instances, [])
	var packed := ResourceLoader.load(data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var enemy := packed.instantiate()
	assert_true(enemy is CharacterBody3D)
	assert_eq(String(enemy.name), "TestGrunt")
	assert_true(enemy.is_in_group(&"enemy"))
	for child in ["CollisionShape3D", "Body", "Nose", "WeaponMount", "NavigationAgent3D"]:
		assert_true(enemy.get_node_or_null(child) != null, "has %s" % child)
	assert_eq(enemy.get("max_health"), 80.0)
	assert_eq(enemy.get("sight_angle_degrees"), 90.0)
	assert_eq(enemy.get("attack_mode"), "melee")
	assert_eq(enemy.get("attack_range"), 1.8)
	assert_eq(enemy.get("target_group"), &"player")
	enemy.free()


func test_enemy_scaffold_ranged_mounts_weapon_scene() -> void:
	var weapon := _tools.weapon_create(_weapon_params("test_enemy_rifle"))
	assert_has_key(weapon, "data", str(weapon))
	var result := _tools.enemy_scaffold(_enemy_params("test_gunner", {"attack_mode": "ranged", "weapon_scene": weapon.data.scene_path}))
	assert_has_key(result, "data", str(result))
	var packed := ResourceLoader.load(result.data.scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var enemy := packed.instantiate()
	assert_eq(enemy.get("attack_mode"), "ranged")
	assert_eq(enemy.get("attack_range"), 12.0, "ranged default range")
	var mount := enemy.get_node("WeaponMount")
	assert_eq(mount.get_child_count(), 1)
	assert_eq(mount.get_child(0).scene_file_path, weapon.data.scene_path, "weapon is linked as an instance")
	enemy.free()


func test_enemy_scaffold_rejects_bad_params() -> void:
	assert_is_error(_tools.enemy_scaffold({}), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("Bad-Id")), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"attack_mode": "magic"})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"weapon_scene": "res://x.tscn"})), "INVALID_PARAMS", "weapon on melee")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"attack_mode": "ranged", "weapon_scene": WORK_DIR + "/nope.tscn"})), "NODE_NOT_FOUND")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"positions": [[1, 2]]})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"patrol_points": "here"})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"sight_angle_degrees": 400})), "INVALID_PARAMS")
	assert_is_error(_tools.enemy_scaffold(_enemy_params("ok_enemy", {"add_to_scene": true, "parent_path": "Nope"})), "NODE_NOT_FOUND")


func test_enemy_scaffold_refuses_existing_scene_without_overwrite() -> void:
	_tools.enemy_scaffold(_enemy_params("test_dupe"))
	assert_is_error(_tools.enemy_scaffold(_enemy_params("test_dupe", {"overwrite": false})), "ALREADY_EXISTS")


func test_enemy_scaffold_places_instances_and_bakes_navigation() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "TestNavFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	shape.shape = box
	floor_body.add_child(shape)
	_root().add_child(floor_body)
	floor_body.owner = _root()
	shape.owner = _root()
	_added.append(floor_body)
	floor_body.position = Vector3(0, -300.5, 0)
	var was_in_group := _root().is_in_group(Tools.NAV_SOURCE_GROUP)

	var result := _tools.enemy_scaffold(_enemy_params("test_patroller", {
		"add_to_scene": true,
		"positions": [[2, -300, 3], [-2, -300, 3]],
		"patrol_points": [[0, -300, 0], [5, -300, 5]],
	}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.instances.size(), 2)
	var first := _track(data.instances[0]) as Node3D
	var second := _track(data.instances[1]) as Node3D
	assert_true(first != null and second != null)
	assert_ne(String(first.name), String(second.name))
	assert_eq(first.position, Vector3(2, -300, 3))
	assert_eq(first.owner, _root())
	assert_eq(first.get("patrol_points"), PackedVector3Array([Vector3(0, -300, 0), Vector3(5, -300, 5)]))
	assert_eq(data.navigation.status, "created", str(data.navigation))
	var region := _track(data.navigation.region_path) as NavigationRegion3D
	assert_true(region != null, "navigation region added")
	assert_gt(data.navigation.polygons, 0, "bake found the floor")
	assert_true(_root().is_in_group(Tools.NAV_SOURCE_GROUP))

	assert_true(editor_undo(_undo_redo))
	assert_true(not is_instance_valid(first) or first.get_parent() == null, "undo removes the enemies")
	assert_true(not is_instance_valid(region) or region.get_parent() == null, "undo removes the region")
	assert_eq(_root().is_in_group(Tools.NAV_SOURCE_GROUP), was_in_group, "undo restores the root's groups")


## Builds a running (@tool copy) enemy far from the open scene's geometry.
func _tool_enemy(extra: Dictionary = {}) -> CharacterBody3D:
	var result := _tools.enemy_scaffold(_enemy_params("test_ai"))
	assert_has_key(result, "data", str(result))
	var enemy := CharacterBody3D.new()
	enemy.name = "ToolEnemy"
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	enemy.add_child(shape)
	enemy.set_script(_tool_copy(result.data.script.path))
	enemy.set("target_group", TARGET_GROUP)
	enemy.set("free_on_death", false)
	enemy.set("perception_interval", 0.0)
	enemy.set("alert_radius", 0.0)
	for key in extra:
		enemy.set(key, extra[key])
	_root().add_child(enemy)
	_added.append(enemy)
	enemy.set_physics_process(false)
	enemy.global_position = Vector3(0, 500, 0)
	_sync_body(enemy)
	return enemy


func _target(offset: Vector3, enemy: Node3D) -> StaticBody3D:
	var target := StaticBody3D.new()
	target.name = "AiTarget"
	target.set_script(_damage_receiver_script())
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 3.0, 0.8)
	shape.shape = box
	shape.position = Vector3(0, 1.5, 0)
	target.add_child(shape)
	target.add_to_group(TARGET_GROUP)
	_root().add_child(target)
	_added.append(target)
	target.global_position = enemy.global_position + offset
	_sync_body(target)
	return target


func _wall(at: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = "AiWall"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 6, 0.5)
	shape.shape = box
	wall.add_child(shape)
	_root().add_child(wall)
	_added.append(wall)
	wall.global_position = at
	_sync_body(wall)
	return wall


## Lets the physics server see a body's transform without a physics step.
func _sync_body(body: CollisionObject3D) -> void:
	PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)


func test_enemy_sees_target_in_cone_and_chases() -> void:
	var enemy := _tool_enemy()
	var target := _target(Vector3(0, 0, -6), enemy)
	var spotted := []
	enemy.target_spotted.connect(func(t): spotted.append(t))
	assert_true(enemy.can_see(target), "in front, in range, clear line")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	assert_eq(enemy.target, target)
	assert_eq(spotted, [target])


func test_enemy_ignores_target_behind_or_out_of_range() -> void:
	var enemy := _tool_enemy({"sight_range": 10.0})
	var behind := _target(Vector3(0, 0, 6), enemy)
	assert_false(enemy.can_see(behind), "outside the vision cone")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "PATROL")
	behind.global_position = enemy.global_position + Vector3(0, 0, 2)
	_sync_body(behind)
	assert_true(enemy.can_see(behind), "within proximity_radius any direction counts")
	behind.global_position = enemy.global_position + Vector3(0, 0, -12)
	_sync_body(behind)
	assert_false(enemy.can_see(behind), "beyond sight_range")


func test_enemy_sight_blocked_by_wall() -> void:
	var enemy := _tool_enemy()
	var target := _target(Vector3(0, 0, -8), enemy)
	_wall(enemy.global_position + Vector3(0, 1, -4))
	assert_false(enemy.can_see(target), "wall blocks line of sight")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "PATROL")


func test_enemy_melee_windup_then_damage() -> void:
	var enemy := _tool_enemy({"attack_windup": 0.3, "attack_damage": 15.0, "attack_cooldown": 1.0})
	var target := _target(Vector3(0, 0, -1.5), enemy)
	var started := []
	enemy.attack_started.connect(func(t): started.append(t))
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "ATTACK", "in range goes straight to attack")
	enemy.think(0.1)
	assert_eq(started.size(), 1, "windup started")
	assert_eq(target.received, 0.0, "no damage during windup")
	enemy.think(0.35)
	assert_eq(target.received, 15.0, "hit after windup")
	enemy.think(0.1)
	enemy.think(0.5)
	assert_eq(target.received, 15.0, "cooldown blocks the next hit")
	enemy.think(0.5)
	enemy.think(0.4)
	assert_eq(target.received, 30.0, "second hit after cooldown and windup")


func test_enemy_ranged_ray_damages_target() -> void:
	var enemy := _tool_enemy({"attack_mode": "ranged", "attack_range": 12.0, "attack_windup": 0.0, "aim_error_degrees": 0.0, "attack_damage": 7.0})
	var target := _target(Vector3(0, 0, -8), enemy)
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "ATTACK")
	enemy.think(0.1)
	assert_eq(target.received, 7.0, "ranged ray hit")


func test_enemy_damage_aggro_and_death() -> void:
	var enemy := _tool_enemy({"max_health": 30.0})
	var attacker := _target(Vector3(0, 0, 10), enemy)
	var deaths := []
	enemy.died.connect(func(): deaths.append(true))
	enemy.take_damage(10.0, {"source": attacker, "position": enemy.global_position})
	assert_eq(enemy.health, 20.0)
	assert_eq(enemy.get_state_name(), "CHASE", "damage from an unseen attacker starts a chase")
	assert_eq(enemy.target, attacker)
	enemy.take_damage(25.0, {"source": attacker})
	assert_eq(enemy.get_state_name(), "DEAD")
	assert_true(enemy.is_dead)
	assert_eq(deaths.size(), 1)
	assert_eq(enemy.collision_layer, 0, "corpse stops blocking bullets")
	enemy.take_damage(5.0, {})
	assert_eq(deaths.size(), 1, "dies once")


func test_enemy_loses_target_searches_then_patrols() -> void:
	var enemy := _tool_enemy({"lose_sight_time": 0.5, "search_time": 0.5})
	var target := _target(Vector3(0, 0, -6), enemy)
	var lost := []
	enemy.target_lost.connect(func(): lost.append(true))
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	target.remove_from_group(TARGET_GROUP)
	enemy.think(0.1)
	assert_eq(enemy.target, null, "a target that left the group is dropped")
	assert_eq(enemy.get_state_name(), "SEARCH")
	## The enemy cannot walk here (no physics step), so the search gives up on
	## reaching the spot after its leg timer and looks around instead.
	for i in 25:
		enemy.think(0.5)
	assert_eq(enemy.get_state_name(), "PATROL")
	assert_eq(lost.size(), 1)


func test_enemy_alerts_nearby_allies() -> void:
	var enemy := _tool_enemy({"alert_radius": 10.0})
	var ally := _tool_enemy({"alert_radius": 0.0})
	ally.name = "ToolAlly"
	ally.global_position = enemy.global_position + Vector3(3, 0, 0)
	ally.rotation.y = PI
	_sync_body(ally)
	var target := _target(Vector3(0, 0, -6), enemy)
	assert_false(ally.can_see(target), "ally faces away")
	enemy.think(0.1)
	assert_eq(enemy.get_state_name(), "CHASE")
	assert_eq(ally.get_state_name(), "CHASE", "ally joins the chase")
	assert_eq(ally.target, target)


# --- items -------------------------------------------------------------------

const ITEM_DIR := WORK_DIR + "/items"

const ITEM_CSV := """id,이름,category,rarity,무게,price,stack,tags,description,durability
bandage,Bandage,medical,common,0.1,50,5,heal;cheap,"Stops bleeding, slowly",
ammo_9mm,9mm Round,ammo,Common,0.01,2,60,ammo,,
# comment row
gold_watch,"Gold ""Rolex"" Watch",valuable,rare,0.2,1500,1,,"Line one
line two",80
"""


func _item_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"csv_text": ITEM_CSV,
		"data_dir": ITEM_DIR,
		"script_dir": WORK_DIR + "/scripts",
		"weapon_data_dir": WORK_DIR + "/data",
	}
	params.merge(extra, true)
	return params


func _load_fresh(path: String) -> Resource:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)


## Item ids in a database file, read from its stored `items` list.
func _db_ids(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	for item in _load_fresh(path).get("items"):
		out.append(item.get("item_id"))
	return out


## The database with a @tool copy of its script, so its lookup methods run.
func _tool_db(path: String) -> Resource:
	var stored := _load_fresh(path)
	var db := Resource.new()
	db.set_script(_tool_copy(WORK_DIR + "/scripts/item_database.gd"))
	db.set("items", stored.get("items"))
	return db


func _clear_items() -> void:
	_remove_tree(ProjectSettings.globalize_path(ITEM_DIR))


func test_item_csv_parser_handles_quotes_and_newlines() -> void:
	var rows := ItemTools.parse_csv("a,b,c\r\n1,\"x, y\",\"he said \"\"hi\"\"\"\n2,\"multi\nline\",\n\n3,,", ",")
	assert_eq(rows.size(), 4)
	assert_eq(rows[1].cells, PackedStringArray(["1", "x, y", "he said \"hi\""]))
	assert_eq(rows[2].cells, PackedStringArray(["2", "multi\nline", ""]))
	assert_eq(rows[2].line, 3)
	assert_eq(rows[3].line, 6, "line numbers count the newline inside quotes and the blank line")
	assert_eq(rows[3].cells, PackedStringArray(["3", "", ""]))


func test_item_db_import_creates_items_and_database() -> void:
	_clear_items()
	var result := _items.item_db_import(_item_params())
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.item_count, 3)
	assert_eq(data.created, ["bandage", "ammo_9mm", "gold_watch"])
	assert_eq(data.columns["이름"], "display_name")
	assert_eq(data.columns["price"], "value")
	assert_eq(data.extra_columns, ["durability"])
	assert_eq(data.blank_or_comment_rows, 1)

	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_true(bandage != null, "bandage.tres loads")
	assert_eq(bandage.get("item_id"), "bandage")
	assert_eq(bandage.get("category"), "medical")
	assert_eq(bandage.get("weight"), 0.1)
	assert_eq(bandage.get("value"), 50)
	assert_eq(bandage.get("max_stack"), 5)
	assert_eq(bandage.get("tags"), ["heal", "cheap"])
	assert_eq(bandage.get("description"), "Stops bleeding, slowly")
	assert_eq(bandage.get("extra"), {})
	var ammo := _load_fresh(ITEM_DIR + "/ammo_9mm.tres")
	assert_eq(ammo.get("rarity"), "common", "enum match ignores case")
	var watch := _load_fresh(ITEM_DIR + "/gold_watch.tres")
	assert_eq(watch.get("display_name"), "Gold \"Rolex\" Watch")
	assert_eq(watch.get("description"), "Line one\nline two")
	assert_eq(watch.get("extra"), {"durability": 80})

	assert_eq(data.database.item_count, 3)
	var db := _tool_db(data.database.path)
	assert_eq(db.get_ids(), PackedStringArray(["bandage", "ammo_9mm", "gold_watch"]))
	assert_eq(db.get_item("gold_watch").get("value"), 1500)
	assert_true(db.has_item("bandage"))
	assert_false(db.has_item("nope"))
	assert_eq(db.find_by("category", "ammo").size(), 1)
	assert_eq(db.find_by_tag("heal").size(), 1)


func test_item_db_import_reimport_updates_in_place_and_merges_database() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var result := _items.item_db_import(_item_params({"csv_text": "id,price,name\nbandage,75,\nmedkit,300,Medkit\n"}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.updated, ["bandage"])
	assert_eq(result.data.created, ["medkit"])
	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_eq(bandage.get("value"), 75)
	assert_eq(bandage.get("display_name"), "Bandage", "blank cell keeps the old value")
	assert_eq(bandage.get("max_stack"), 5, "missing column keeps the old value")
	assert_eq(_db_ids(result.data.database.path), PackedStringArray(["bandage", "ammo_9mm", "gold_watch", "medkit"]))


func test_item_db_import_existing_modes() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var sheet := "id,price\nbandage,99\n"
	assert_is_error(_items.item_db_import(_item_params({"csv_text": sheet, "existing": "error"})), "ALREADY_EXISTS")
	var skipped := _items.item_db_import(_item_params({"csv_text": sheet, "existing": "skip"}))
	assert_eq(skipped.data.skipped, ["bandage"])
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 50)
	var replaced := _items.item_db_import(_item_params({"csv_text": sheet, "existing": "replace"}))
	assert_eq(replaced.data.replaced, ["bandage"])
	var bandage := _load_fresh(ITEM_DIR + "/bandage.tres")
	assert_eq(bandage.get("value"), 99)
	assert_eq(bandage.get("max_stack"), 1, "replace starts from a fresh item")


func test_item_db_import_bad_rows_write_nothing() -> void:
	_clear_items()
	var sheet := "id,category,weight,price\ngood_item,misc,1,5\nbad item!,misc,1,5\nworse,food_court,heavy,1.5\ngood_item,misc,1,5\n"
	var result := _items.item_db_import(_item_params({"csv_text": sheet}))
	assert_is_error(result, "INVALID_PARAMS")
	var msg: String = result.error.message
	assert_contains(msg, "line 3")
	assert_contains(msg, "'food_court' is not one of")
	assert_contains(msg, "'heavy' is not a number")
	assert_contains(msg, "'1.5' is not a whole number")
	assert_contains(msg, "repeats line 2")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/good_item.tres"), "nothing written")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/item_database.tres"))


func test_item_db_import_param_errors() -> void:
	assert_is_error(_items.item_db_import({"data_dir": ITEM_DIR}), "INVALID_PARAMS", "no source")
	assert_is_error(_items.item_db_import(_item_params({"csv_path": WORK_DIR + "/x.csv"})), "INVALID_PARAMS", "both sources")
	assert_is_error(_items.item_db_import({"csv_path": WORK_DIR + "/missing.csv"}), "NODE_NOT_FOUND")
	assert_is_error(_items.item_db_import(_item_params({"csv_text": "name,price\nA,1\n"})), "INVALID_PARAMS", "no id column")
	assert_is_error(_items.item_db_import(_item_params({"data_dir": "res://addons/x"})), "INVALID_PARAMS")
	assert_is_error(_items.item_db_import(_item_params({"existing": "merge"})), "INVALID_PARAMS")
	assert_is_error(_items.item_db_import(_item_params({"column_map": {"price": "nope"}})), "INVALID_PARAMS")


func test_item_db_import_dry_run_writes_nothing() -> void:
	_clear_items()
	var result := _items.item_db_import(_item_params({"dry_run": true}))
	assert_has_key(result, "data", str(result))
	assert_true(result.data.dry_run)
	assert_eq(result.data.created.size(), 3)
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ITEM_DIR)), "no item folder")


func test_item_db_import_reads_file_tsv_column_map_and_weapon() -> void:
	_clear_items()
	assert_has_key(_tools.weapon_create(_weapon_params("test_item_rifle")), "data")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR))
	var path := WORK_DIR + "/sheet.tsv"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	f.store_string("Code\tGun\tKind\t#note\tSize\nrifle_item\ttest_item_rifle\tweapon\tignored\t4\n")
	f.close()
	var result := _items.item_db_import(_item_params({
		"csv_text": null,
		"csv_path": path,
		"column_map": {"Code": "item_id", "Gun": "weapon", "Kind": "category", "Size": "grid_width"},
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.ignored_columns, ["#note"])
	var rifle := _load_fresh(ITEM_DIR + "/rifle_item.tres")
	assert_eq(rifle.get("grid_width"), 4)
	assert_true(rifle.get("weapon") != null, "weapon id resolves to the weapon .tres")
	assert_eq(rifle.get("weapon").resource_path, WORK_DIR + "/data/test_item_rifle.tres")

	var latin1 := WORK_DIR + "/latin1.csv"
	var g := FileAccess.open(latin1, FileAccess.WRITE)
	g.store_buffer(PackedByteArray([0x69, 0x64, 0x0A, 0xE9, 0x0A]))
	g.close()
	assert_is_error(_items.item_db_import(_item_params({"csv_text": null, "csv_path": latin1})), "INVALID_PARAMS", "non-UTF-8 file")


func test_item_db_import_undo_restores_files() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var result := _items.item_db_import(_item_params({"csv_text": "id,price\nbandage,75\nmedkit,300\n"}))
	assert_has_key(result, "data", str(result))
	assert_has_key(result.data, "undo")
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo runs")
	assert_false(FileAccess.file_exists(ITEM_DIR + "/medkit.tres"), "undo deletes the new item")
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 50, "undo restores the old value")
	assert_eq(_db_ids(ITEM_DIR + "/item_database.tres").size(), 3)
	assert_true(global_ur.redo(), "redo runs")
	assert_true(FileAccess.file_exists(ITEM_DIR + "/medkit.tres"))
	assert_eq(_load_fresh(ITEM_DIR + "/bandage.tres").get("value"), 75)


# --- loot tables ---------------------------------------------------------------

const LOOT_DIR := WORK_DIR + "/loot"


func _loot_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"table_id": "test_grunt",
		"data_dir": LOOT_DIR,
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"seed": 7,
		"simulate": 4000,
	}
	params.merge(extra, true)
	return params


const LOOT_ENTRIES := [
	{"item_id": "bandage", "weight": 3, "min_count": 1, "max_count": 2},
	{"item_id": "ammo_9mm", "weight": 1, "min_count": 10, "max_count": 30},
	{"item_id": "gold_watch", "guaranteed": true},
]


func _fresh_loot() -> void:
	_remove_tree(ProjectSettings.globalize_path(LOOT_DIR))
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")


func _row(data: Dictionary, id: String) -> Dictionary:
	for row in data.entries:
		if row.item_id == id:
			return row
	return {}


func test_loot_chances_math() -> void:
	var t := {"rolls_min": 1, "rolls_max": 1, "empty_weight": 0.0, "entries": [
		{"item_id": "a", "weight": 1.0, "min": 1, "max": 1, "guaranteed": false},
		{"item_id": "b", "weight": 3.0, "min": 2, "max": 4, "guaranteed": false},
	]}
	var odds := LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 0.25)
	assert_eq(odds.per_item.b.expected, 0.75 * 3.0)
	assert_eq(odds.nothing, 0.0)
	t.rolls_max = 2
	t.rolls_min = 2
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 1.0 - 0.75 * 0.75)
	t.rolls_min = 1
	t.rolls_max = 1
	t.empty_weight = 4.0
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.a.drop, 0.125)
	assert_eq(odds.nothing, 0.5)
	t.entries.append({"item_id": "g", "weight": 0.0, "min": 0, "max": 1, "guaranteed": true})
	odds = LootTools.chances(t)
	assert_eq(odds.per_item.g.drop, 0.5, "min 0 guaranteed drops half the time")
	assert_eq(odds.nothing, 0.25)


func test_loot_table_create_and_simulate() -> void:
	_fresh_loot()
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "empty_weight": 4}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.status, "created")
	assert_eq(data.added, ["bandage", "ammo_9mm", "gold_watch"])
	assert_eq(data.total_weight, 8.0)
	assert_eq(_row(data, "bandage").roll_percent, 37.5)
	assert_eq(_row(data, "gold_watch").drop_percent, 100.0)
	assert_eq(_row(data, "gold_watch").simulated_drop_percent, 100.0)
	for id in ["bandage", "ammo_9mm"]:
		var row := _row(data, id)
		assert_true(absf(row.drop_percent - row.simulated_drop_percent) < 3.0, "%s simulated %s vs exact %s" % [id, row.simulated_drop_percent, row.drop_percent])
		assert_true(absf(row.expected_count - row.simulated_avg_count) < row.expected_count * 0.15 + 0.05, "%s average count" % id)
	assert_eq(data.nothing_chance_percent, 0.0, "the watch always drops")
	assert_eq(data.simulation.samples.size(), 5)
	assert_contains(data.simulation.samples[0], "gold_watch")

	var again := _loot.loot_table_edit(_loot_params())
	assert_eq(again.data.status, "unchanged", "table_id alone only simulates")
	assert_eq(again.data.simulation.samples, data.simulation.samples, "same seed, same samples")

	var table := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	assert_eq(table.get("table_id"), "test_grunt")
	assert_eq(table.get("empty_weight"), 4.0)
	assert_eq(table.get("entries").size(), 3)
	assert_eq(table.get("entries")[1], {"item_id": "ammo_9mm", "weight": 1.0, "min": 10, "max": 30, "guaranteed": false})
	assert_eq(table.get("item_database").resource_path, ITEM_DIR + "/item_database.tres")


func test_loot_table_roll_resolves_items() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var stored := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	var t := Resource.new()
	t.set_script(_tool_copy(WORK_DIR + "/scripts/loot_table.gd"))
	t.set("entries", stored.get("entries"))
	t.set("item_database", _tool_db(ITEM_DIR + "/item_database.tres"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var drops: Array = t.roll(rng)
	assert_eq(drops.size(), 2, "the watch plus one rolled item")
	assert_eq(drops[0].item_id, "gold_watch")
	assert_eq(drops[0].item.get("value"), 1500)
	assert_eq(t.get_roll_chances().bandage, 0.75)


func test_loot_table_edit_upserts_removes_and_expands_categories() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var result := _loot.loot_table_edit(_loot_params({
		"entries": [{"item_id": "bandage", "weight": 10}, {"category": "valuable", "weight": 2, "max_count": 2}],
		"remove_items": ["ammo_9mm"],
		"rolls_max": 3,
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "updated")
	assert_eq(result.data.changed, ["bandage", "gold_watch"])
	assert_eq(result.data.removed, ["ammo_9mm"])
	assert_eq(result.data.rolls, [1, 3])
	var entries: Array = _load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")
	assert_eq(entries.size(), 2)
	assert_eq(entries[0].weight, 10.0)
	assert_eq(entries[1], {"item_id": "gold_watch", "weight": 2.0, "min": 1, "max": 2, "guaranteed": false})

	result = _loot.loot_table_edit(_loot_params({"entries": [{"tag": "heal", "weight": 1}, {"item_id": "bandage", "weight": 5}], "replace_entries": true}))
	assert_eq(result.data.added, ["bandage"])
	assert_eq(result.data.changed, [], "a later entry for an item added in the same call is not a change")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 5.0, "the later entry wins")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries").size(), 1)


func test_loot_table_errors_write_nothing() -> void:
	_fresh_loot()
	assert_is_error(_loot.loot_table_edit({}), "INVALID_PARAMS", "no table_id")
	assert_is_error(_loot.loot_table_edit(_loot_params({"table_id": "Bad Id"})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params()), "INVALID_PARAMS", "new table without entries")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "nope"}]})), "INVALID_PARAMS", "unknown item")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "chance": 1}]})), "INVALID_PARAMS", "unknown key")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "tag": "heal"}]})), "INVALID_PARAMS", "two selectors")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "min_count": 3, "max_count": 1}]})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": [{"category": "weapon"}]})), "INVALID_PARAMS", "no matching items")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "rolls_min": 3, "rolls_max": 1})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "data_dir": "res://addons/x"})), "INVALID_PARAMS")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "database_path": WORK_DIR + "/none.tres"})), "NODE_NOT_FOUND")
	assert_is_error(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": ["/Nope"]})), "NODE_NOT_FOUND")
	assert_false(FileAccess.file_exists(LOOT_DIR + "/test_grunt.tres"))
	var loose := _loot.loot_table_edit(_loot_params({"entries": [{"item_id": "mystery"}], "allow_unknown_items": true, "database_path": WORK_DIR + "/none.tres"}))
	assert_has_key(loose, "data", str(loose))
	assert_eq(loose.data.warnings.size(), 1)


func test_loot_table_dry_run_writes_nothing() -> void:
	_fresh_loot()
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "dry_run": true}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "would create")
	assert_eq(_row(result.data, "bandage").drop_percent, 75.0)
	assert_false(FileAccess.file_exists(LOOT_DIR + "/test_grunt.tres"))


func test_loot_table_undo_restores_file() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var result := _loot.loot_table_edit(_loot_params({"entries": [{"item_id": "bandage", "weight": 50}]}))
	assert_has_key(result.data, "undo")
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo runs")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 3.0)
	assert_true(global_ur.redo(), "redo runs")
	assert_eq(_load_fresh(LOOT_DIR + "/test_grunt.tres").get("entries")[0].weight, 50.0)


func _died_source() -> Node3D:
	var script := GDScript.new()
	script.source_code = "@tool\nextends Node3D\nsignal died\n"
	script.reload()
	var node := Node3D.new()
	node.set_script(script)
	node.name = "LootTestEnemy"
	node.add_to_group(&"mcp_test_loot", true)
	_root().add_child(node)
	node.owner = _root()
	_added.append(node)
	return node


func test_loot_attach_adds_dropper_with_undo() -> void:
	_fresh_loot()
	var enemy := _died_source()
	var plain := Node3D.new()
	plain.name = "LootTestCrate"
	_root().add_child(plain)
	plain.owner = _root()
	_added.append(plain)
	var result := _loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": [Util_path(plain)], "attach_to_group": "mcp_test_loot"}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.attached.size(), 2)
	assert_eq(result.data.warnings.size(), 1, "the crate has no died signal: " + str(result.data.warnings))
	var dropper := enemy.get_node_or_null(^"LootDropper")
	assert_true(dropper != null, "dropper added under the enemy")
	assert_eq(dropper.owner, _root())
	assert_eq(dropper.get("loot_table").resource_path, LOOT_DIR + "/test_grunt.tres")
	assert_eq(dropper.get("pickup_script_path"), WORK_DIR + "/scripts/loot_pickup.gd")
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/loot_dropper.gd"))

	var again := _loot.loot_table_edit(_loot_params({"attach_to": [Util_path(enemy)], "trigger_signal": "opened"}))
	assert_eq(again.data.attached, [Util_path(enemy) + "/LootDropper (updated)"])
	assert_eq(enemy.get_child_count(), 1, "no second dropper")
	assert_eq(dropper.get("trigger_signal"), &"opened")

	var scene_ur := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root()))
	assert_true(scene_ur.undo(), "undo the update")
	assert_eq(dropper.get("trigger_signal"), &"died")
	assert_true(scene_ur.undo(), "undo the attach")
	assert_eq(enemy.get_child_count(), 0)
	assert_eq(plain.get_child_count(), 0)


func Util_path(node: Node) -> String:
	return "/" + String(_root().name) + "/" + String(_root().get_path_to(node))


func test_loot_dropper_spawns_pickups_and_pickup_collects() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES, "attach_to": []})), "data")
	var stored := _load_fresh(LOOT_DIR + "/test_grunt.tres")
	var t := Resource.new()
	t.set_script(_tool_copy(WORK_DIR + "/scripts/loot_table.gd"))
	t.set("entries", stored.get("entries"))
	t.set("item_database", _tool_db(ITEM_DIR + "/item_database.tres"))

	var holder := Node3D.new()
	holder.name = "LootTestHolder"
	_root().add_child(holder)
	_added.append(holder)
	var enemy := Node3D.new()
	holder.add_child(enemy)
	enemy.position = Vector3(4, 0, 2)
	var dropper := Node3D.new()
	dropper.set_script(_tool_copy(_install_template("loot_dropper")))
	dropper.set("loot_table", t)
	dropper.set("pickup_script_path", _install_template("loot_pickup"))
	enemy.add_child(dropper)
	var got := []
	dropper.dropped.connect(func(d): got.append(d))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var drops: Array = dropper.drop(rng)
	assert_eq(drops.size(), 2)
	assert_eq(got.size(), 1, "dropped signal")
	assert_eq(dropper.drop(rng), [], "drops once")
	var pickups := holder.get_children().filter(func(n): return n != enemy)
	assert_eq(pickups.size(), 2, "pickups land next to the enemy, not under it")
	var watch: Node3D = pickups[0]
	assert_eq(watch.get("item_id"), "gold_watch")
	assert_eq(watch.get("count"), 1)
	assert_true(watch.global_position.distance_to(enemy.global_position) <= 0.81)

	var pickup := Area3D.new()
	pickup.set_script(_tool_copy(_install_template("loot_pickup")))
	pickup.set("item_id", "bandage")
	pickup.set("count", 2)
	holder.add_child(pickup)
	assert_true(pickup.get_node_or_null(^"Visual") != null, "builds its visual")
	var bag_script := GDScript.new()
	bag_script.source_code = "@tool\nextends Node3D\nvar got := {}\nvar full := false\nfunc add_item(item, count):\n\tif full: return false\n\tgot[item] = count\n\treturn true\n"
	bag_script.reload()
	var bag := Node3D.new()
	bag.set_script(bag_script)
	bag.add_to_group(&"player")
	holder.add_child(bag)
	bag.set("full", true)
	assert_false(pickup._try_collect(bag), "a full inventory leaves it")
	bag.set("full", false)
	assert_false(pickup._try_collect(enemy), "only the collector group")
	assert_true(pickup._try_collect(bag))
	assert_eq(bag.get("got"), {"bandage": 2})
	assert_true(pickup.is_queued_for_deletion())


## Installs a loot template into the test scripts folder and returns its path.
func _install_template(name: String) -> String:
	var path := WORK_DIR + "/scripts/%s.gd" % name
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/%s.gd.tmpl" % name))
		f.close()
	return path


# --- inventory -------------------------------------------------------------------

## A @tool item resource with the item_data.gd fields the inventory reads.
func _test_item(id: String, w := 1, h := 1, stack := 1, weight := 1.0, value := 10) -> Resource:
	var script := _tool_copy(_install_item_template())
	var item := Resource.new()
	item.set_script(script)
	item.set("item_id", id)
	item.set("display_name", id)
	item.set("grid_width", w)
	item.set("grid_height", h)
	item.set("max_stack", stack)
	item.set("weight", weight)
	item.set("value", value)
	return item


func _install_item_template() -> String:
	var path := WORK_DIR + "/scripts/item_data.gd"
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(FileAccess.get_file_as_string("res://addons/topdown_shooter_tools/templates/item_data.gd.tmpl"))
		f.close()
	return path


## An inventory (tool copy of the template) under a body with move_speed.
func _test_bag(w := 4, h := 3, max_weight := 0.0) -> Node:
	_install_item_template()
	var body_script := GDScript.new()
	body_script.source_code = "@tool\nextends Node3D\nvar move_speed := 6.0\n"
	body_script.reload()
	var body := Node3D.new()
	body.set_script(body_script)
	body.name = "InvTestBody"
	var bag := Node.new()
	bag.set_script(_tool_copy(_install_template("inventory")))
	bag.set("grid_width", w)
	bag.set("grid_height", h)
	bag.set("max_weight", max_weight)
	bag.set("encumbered_weight", 0.0)
	body.add_child(bag)
	_root().add_child(body)
	_added.append(body)
	return bag


func test_inventory_stacks_and_fills_grid_all_or_nothing() -> void:
	var bag := _test_bag(4, 3)
	var ammo := _test_item("ammo", 1, 1, 30, 0.01)
	var rifle := _test_item("rifle", 4, 2, 1, 3.5)
	assert_true(bag.add_item(ammo, 45), "45 rounds")
	assert_eq(bag.entries.size(), 2, "two stacks of up to 30")
	assert_eq(bag.count_of(ammo), 45)
	assert_true(bag.add_item(ammo, 15), "tops up the partial stack")
	assert_eq(bag.entries.size(), 2)
	assert_true(bag.add_item(rifle), "4x2 rifle fits under the ammo")
	assert_eq([bag.entries[2].x, bag.entries[2].y], [0, 1])
	var before: Array = bag.to_data()
	assert_false(bag.add_item(rifle), "no room for a second rifle")
	assert_false(bag.add_item(ammo, 100), "no room for 100 more rounds")
	assert_eq(bag.to_data(), before, "a failed add changes nothing")
	assert_true(bag.add_item(ammo, 30), "one more stack fits in the last free cells")
	assert_eq(bag.remove_item(ammo, 50), 50)
	assert_eq(bag.count_of(ammo), 40)


func test_inventory_rotates_to_fit_and_respects_weight() -> void:
	var bag := _test_bag(2, 4, 5.0)
	var long := _test_item("long", 3, 1, 1, 1.0)
	assert_true(bag.add_item(long), "3x1 fits a 2-wide bag turned")
	assert_true(bag.entries[0].rotated)
	assert_eq(bag.entry_size(0), Vector2i(1, 3))
	bag.set("allow_rotation", false)
	assert_false(bag.add_item(long), "not without rotation")
	bag.set("allow_rotation", true)
	var brick := _test_item("brick", 1, 1, 10, 1.0)
	assert_true(bag.add_item(brick, 4), "4 kg more: 5 kg total")
	assert_false(bag.add_item(brick, 1), "over max_weight")
	assert_true(is_equal_approx(bag.get_total_weight(), 5.0), "5 kg")


func test_inventory_move_merge_split_sort_and_speed() -> void:
	var bag := _test_bag(4, 2)
	var med := _test_item("med", 1, 1, 5, 0.5, 100)
	var box := _test_item("box", 2, 2, 1, 2.0, 300)
	assert_true(bag.add_item(med, 4))
	assert_true(bag.split_entry(0), "split 4 into 2 + 2")
	assert_eq(bag.entries.size(), 2)
	assert_true(bag.move_entry(1, Vector2i(0, 0)), "drop on the same item merges")
	assert_eq(bag.entries.size(), 1)
	assert_eq(int(bag.entries[0].count), 4)
	assert_true(bag.add_item(box))
	assert_false(bag.move_entry(1, Vector2i(3, 0)), "2x2 does not fit at the right edge")
	assert_true(bag.move_entry(1, Vector2i(2, 0)))
	assert_eq(bag.entry_at(Vector2i(3, 1)), 1)
	assert_true(bag.sort_items())
	assert_eq([bag.entries[0].x, bag.entries[0].y], [0, 0], "largest first")
	assert_eq(bag.item_id_of(bag.entries[0].item), "box")
	assert_eq(bag.get_total_value(), 700)
	var body := bag.get_parent()
	bag.set("encumbered_weight", 1.0)
	bag.set("max_weight", 6.0)
	bag._base_speed = 6.0
	bag._update_speed()
	assert_true(is_equal_approx(float(body.get("move_speed")), 4.2), "4 kg of 1..6 kg slows to 70%%: %s" % body.get("move_speed"))


func _inventory_player() -> Node3D:
	var path := WORK_DIR + "/scripts/inv_test_player.gd"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("extends Node3D\n\nvar move_speed := 6.0\n")
	f.close()
	var player := Node3D.new()
	player.name = "InvTestPlayer"
	player.set_script(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE))
	_root().add_child(player)
	player.owner = _root()
	_added.append(player)
	return player


func _inventory_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"player_path": "InvTestPlayer",
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"toggle_action": ACTION_PREFIX + "inventory",
	}
	params.merge(extra, true)
	return params


func test_inventory_scaffold_adds_nodes_patches_player_with_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var player := _inventory_player()
	var result := _inventory.inventory_ui_scaffold(_inventory_params({"grid_width": 5, "starting_items": [{"item_id": "bandage", "count": 2}]}))
	assert_has_key(result, "data", str(result))
	var inv := player.get_node_or_null(^"Inventory")
	assert_true(inv != null, "Inventory under the player")
	assert_eq(inv.owner, _root())
	assert_eq(inv.get("grid_width"), 5)
	assert_eq(inv.get("starting_items").size(), 1)
	assert_eq(inv.get("starting_items")[0], {"item_id": "bandage", "count": 2})
	assert_eq(inv.get("item_database").resource_path, ITEM_DIR + "/item_database.tres")
	var ui := _root().get_node_or_null(^"InventoryUI")
	assert_true(ui != null and ui is CanvasLayer, "InventoryUI under the scene root")
	_added.append(ui)
	assert_eq(ui.get("inventory_path"), NodePath("../InvTestPlayer/Inventory"))
	assert_eq(ui.get("toggle_action"), StringName(ACTION_PREFIX + "inventory"))
	assert_true(InputMap.has_action(ACTION_PREFIX + "inventory"), "toggle action added")
	var source := FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd")
	assert_true(source.contains("func add_item(item: Variant, count: int = 1) -> bool:"), "add_item appended")
	assert_true(player.get_script().get_script_method_list().any(func(m): return m.name == "add_item"), "cached script reloaded")

	var again := _inventory.inventory_ui_scaffold(_inventory_params({"max_weight": 80}))
	assert_eq(again.data.inventory, "/%s/InvTestPlayer/Inventory (updated)" % _root().name)
	assert_eq(again.data.player_script, "kept (already has add_item)")
	assert_eq(inv.get("max_weight"), 80.0)
	assert_eq(player.get_child_count(), 1, "no second inventory")

	var scene_ur := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root()))
	assert_true(scene_ur.undo(), "undo the update")
	assert_eq(inv.get("max_weight"), 40.0)
	assert_true(scene_ur.undo(), "undo the nodes")
	assert_eq(player.get_child_count(), 0)
	assert_true(_root().get_node_or_null(^"InventoryUI") == null)
	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the script patch")
	assert_false(FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd").contains("add_item"))


func test_inventory_scaffold_errors_change_nothing() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var player := _inventory_player()
	for bad in [
		{"starting_items": [{"item_id": "nope"}]},
		{"encumbered_weight": 50, "max_weight": 40},
		{"player_path": "Missing"},
		{"inventory_name": "bad name"},
	]:
		var result := _inventory.inventory_ui_scaffold(_inventory_params(bad))
		assert_has_key(result, "error", "%s -> %s" % [bad, result])
	var dry := _inventory.inventory_ui_scaffold(_inventory_params({"dry_run": true}))
	assert_eq(dry.data.would, {"inventory": "create", "ui": "create"})
	assert_eq(dry.data.player_script, "will patch")
	assert_eq(player.get_child_count(), 0)
	assert_false(FileAccess.get_file_as_string(WORK_DIR + "/scripts/inv_test_player.gd").contains("add_item"))


# --- raid map ------------------------------------------------------------------

func _raid_params(extra: Dictionary = {}) -> Dictionary:
	var params := {
		"name": "RaidTestMap",
		"seed": 1234,
		"room_count": 4,
		"room_size_min": 9,
		"room_size_max": 12,
		"origin": [200, 0, 0],
		"script_dir": WORK_DIR + "/scripts",
		"interact_action": ACTION_PREFIX + "interact",
		"move_player": false,
		"add_light": false,
		"setup_navigation": false,
	}
	params.merge(extra, true)
	return params


func _raid_layout(extra: Dictionary = {}) -> Dictionary:
	var p: Variant = _raid._read_params(_raid_params(extra))
	assert_false(p is Dictionary and p.has("status"), str(p))
	var layout: Variant = _raid._plan(p)
	assert_false(layout.has("status"), str(layout))
	return layout


## Walkable cells reachable from the first walkable cell.
func _flood(grid: Dictionary) -> int:
	var start := -1
	for i in grid.cells.size():
		if grid.cells[i] != 0:
			start = i
			break
	var seen := {start: true}
	var stack := [start]
	while not stack.is_empty():
		var c: int = stack.pop_back()
		var x := c % int(grid.w)
		var z := c / int(grid.w)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var nz: int = z + d.y
			var n: int = nz * int(grid.w) + nx
			if nx >= 0 and nz >= 0 and nx < grid.w and nz < grid.h and grid.cells[n] != 0 and not seen.has(n):
				seen[n] = true
				stack.append(n)
	return seen.size()


func test_raid_layout_connected_walls_outside_and_seeded() -> void:
	var layout := _raid_layout()
	assert_eq(layout.rooms.size(), 4)
	var walkable := 0
	for c in layout.grid.cells:
		if c != 0:
			walkable += 1
	assert_eq(_flood(layout.grid), walkable, "every room and corridor is reachable")
	assert_true(layout.links.size() >= 3, "spanning tree plus extra")
	assert_true(layout.walls.size() >= 8)
	var grid: Dictionary = layout.grid
	for r in layout.walls:
		var c: Vector2 = r.get_center()
		assert_false(RaidTools._walk(grid, int(floor(c.x)) - grid.x0, int(floor(c.y)) - grid.z0), "wall %s stands outside the floor" % r)
	assert_eq(layout.extraction_indices.size(), 1)
	assert_ne(layout.extraction_indices[0], layout.spawn_index, "extraction away from the spawn")
	assert_eq(layout.enemy_spawns.size(), 3, "one per room except the spawn room")
	assert_eq(layout.crates.size(), 3)
	## Props keep ROOM_MARGIN from their room's walls.
	for room in layout.rooms:
		var inner := Rect2(room.rect).grow(-RaidTools.ROOM_MARGIN + 0.01)
		for c in layout.cover:
			if c.room == room.name:
				assert_true(inner.encloses(c.rect), "cover %s inside %s" % [c.rect, inner])
	var again := _raid_layout()
	assert_eq(_raid._preview(again), _raid._preview(layout), "same seed, same map")
	var other := _raid_layout({"seed": 99})
	assert_ne(_raid._preview(other), _raid._preview(layout))


func test_raid_explicit_rooms_connections_and_roles() -> void:
	var layout := _raid_layout({
		"rooms": [
			{"name": "Gate", "position": [0, 20], "size": [10, 10], "enemies": 0},
			{"name": "Yard", "position": [0, 0], "size": [16, 14], "cover": 5, "crates": 2, "enemies": 2},
			{"name": "Bunker", "position": [24, 0], "size": [10, 10]},
		],
		"connections": [["Gate", "Yard"], ["Yard", 2]],
		"extraction_rooms": ["Bunker", "Gate"],
		"player_spawn_room": "Gate",
	})
	assert_eq(layout.links, [[0, 1], [1, 2]])
	assert_eq(layout.spawn_index, 0)
	assert_eq(layout.extractions.size(), 2)
	assert_eq(layout.rooms[1].counts, {"cover": 5, "crates": 2, "enemies": 2})
	assert_eq(layout.rooms[0].roles, ["player_spawn", "extraction"])
	var walkable := 0
	for c in layout.grid.cells:
		if c != 0:
			walkable += 1
	assert_eq(_flood(layout.grid), walkable)
	var spawn: Vector3 = layout.player_spawn
	for e in layout.extractions:
		assert_true(e.position.distance_to(spawn) >= 2.0, "zone and spawn do not overlap in a shared room")
	assert_eq(layout.enemy_spawns[0].patrol.size(), 4)


func test_raid_rejects_bad_params() -> void:
	for bad in [
		{"room_size_min": 14, "room_size_max": 8},
		{"rooms": [{"position": [0, 0], "size": [2, 2]}]},
		{"rooms": [{"position": [0, 0], "size": [8, 8], "color": "red"}]},
		{"rooms": [{"position": [0, 0], "size": [8, 8]}], "connections": [[0, 5]]},
		{"player_spawn_room": "Nowhere"},
		{"enemy_scenes": ["res://zz_missing/enemy.tscn"]},
		{"crate_loot_table": "no_such_table"},
		{"script_dir": "res://addons/x"},
		{"name": "bad/name"},
		{"room_count": 64, "room_size_max": 100, "room_size_min": 100, "room_gap": 100},
	]:
		var result := _raid.raid_map_blockout(_raid_params(bad))
		assert_has_key(result, "error", "%s -> %s" % [bad, result])
	var dry := _raid.raid_map_blockout(_raid_params({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.status, "dry_run")
	assert_true(dry.data.preview.size() > 5)
	assert_true(_root().get_node_or_null(^"RaidTestMap") == null, "dry run adds nothing")


func test_raid_builds_map_in_scene_with_navigation_and_undo() -> void:
	var regions_before := _root().find_children("*", "NavigationRegion3D", true, false).size()
	var result := _raid.raid_map_blockout(_raid_params({"setup_navigation": true, "room_count": 3, "seed": 5}))
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.data
	assert_eq(data.status, "created")
	var map := _track(data.map_path) as Node3D
	assert_true(map != null)
	assert_eq(map.owner, _root())
	assert_eq(map.position, Vector3(200, 0, 0))
	var wall := map.get_node("Walls").get_child(0) as StaticBody3D
	assert_true(wall != null and wall.get_node("Shape").shape is BoxShape3D)
	assert_eq(wall.owner, _root(), "walls are saved with the scene")
	assert_eq(map.get_node("Walls").get_child_count(), data.counts.walls)
	assert_eq(map.get_node("Rooms").get_child_count(), 3)
	var spawn := map.get_node("PlayerSpawn") as Marker3D
	assert_true(spawn.is_in_group(&"player_spawn"))
	assert_eq(map.get_node("Extractions").get_child_count(), 1)
	var zone := map.get_node("Extractions/Extraction1")
	assert_eq(zone.get_script().resource_path, WORK_DIR + "/scripts/raid_extraction.gd")
	var crate := map.get_node("Crates/Crate1")
	assert_eq(crate.get_script().resource_path, WORK_DIR + "/scripts/loot_crate.gd")
	assert_eq(crate.get("interact_action"), StringName(ACTION_PREFIX + "interact"))
	assert_true(InputMap.has_action(ACTION_PREFIX + "interact"), "interact action created")
	assert_true(data.counts.enemy_spawns >= 1)
	assert_eq(map.get_node("EnemySpawns").get_child_count(), data.counts.enemy_spawns)
	## Navigation: a new region baked from the map.
	assert_eq(data.navigation.status, "created", str(data.navigation))
	assert_true(data.navigation.polygons > 0, "nav mesh covers the floor")
	assert_true(map.is_in_group(&"navigation_source") or _root().is_in_group(&"navigation_source"))
	var region := McpScenePath.resolve(data.navigation.region_path, _root())
	assert_true(region != null)

	assert_true(editor_undo(_undo_redo))
	assert_true(map.get_parent() == null, "undo removes the map")
	assert_eq(_root().find_children("*", "NavigationRegion3D", true, false).size(), regions_before, "and the new region")


func test_raid_replace_places_enemies_crate_loot_and_restores_on_undo() -> void:
	_fresh_loot()
	assert_has_key(_loot.loot_table_edit(_loot_params({"entries": LOOT_ENTRIES})), "data")
	var enemy_result := _tools.enemy_scaffold({
		"enemy_id": "raid_test_grunt",
		"scene_dir": WORK_DIR + "/enemies",
		"script_dir": WORK_DIR + "/scripts",
		"add_to_scene": false,
		"overwrite": true,
	})
	assert_has_key(enemy_result, "data", str(enemy_result))
	var first := _raid.raid_map_blockout(_raid_params({"room_count": 2, "enemies_per_room": 0}))
	assert_has_key(first, "data", str(first))
	var old_map := _track(first.data.map_path)
	assert_is_error(_raid.raid_map_blockout(_raid_params()), "ALREADY_EXISTS")

	var result := _raid.raid_map_blockout(_raid_params({
		"replace": true,
		"enemy_scenes": [enemy_result.data.scene_path],
		"crate_loot_table": LOOT_DIR + "/test_grunt.tres",
	}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.status, "replaced")
	assert_eq(result.data.enemies_placed, 3)
	var map := _track(result.data.map_path)
	assert_true(old_map.get_parent() == null, "old map removed")
	var enemy := map.get_node("Enemies").get_child(0)
	assert_eq(enemy.scene_file_path, enemy_result.data.scene_path)
	assert_eq(enemy.owner, _root())
	var route: PackedVector3Array = enemy.get("patrol_points")
	assert_eq(route.size(), 4, "patrol loop through the room corners")
	assert_true(route[0].x > 150.0, "route in world space (origin x=200)")
	var dropper := map.get_node("Crates/Crate1/LootDropper")
	assert_eq(dropper.get("trigger_signal"), &"opened")
	assert_eq(dropper.get("loot_table").resource_path, LOOT_DIR + "/test_grunt.tres")
	assert_eq(dropper.owner, _root())

	assert_true(editor_undo(_undo_redo))
	assert_true(map.get_parent() == null)
	assert_eq(old_map.get_parent(), _root(), "undo brings the old map back")
	assert_eq(old_map.get_node("Walls").get_child(0).owner, _root(), "with its owners, so it still saves")


func test_raid_crate_search_and_open() -> void:
	var crate := StaticBody3D.new()
	crate.set_script(_tool_copy(_install_raid_template("loot_crate")))
	crate.set("search_time", 0.5)
	var holder := Node3D.new()
	holder.name = "RaidCrateHolder"
	_root().add_child(holder)
	_added.append(holder)
	holder.add_child(crate)
	var player := Node3D.new()
	player.add_to_group(&"player")
	holder.add_child(player)
	player.position = Vector3(5, 0, 0)
	assert_true(crate.nearest_player() == null, "too far")
	player.position = Vector3(1, 0, 0.5)
	assert_eq(crate.nearest_player(), player)
	var opened := []
	crate.opened.connect(func(by): opened.append(by))
	crate.start_search(player)
	assert_false(crate.get("is_open"))
	crate.open(player)
	assert_true(crate.get("is_open"))
	assert_eq(opened, [player])
	crate.open(player)
	assert_eq(opened.size(), 1, "opens once")


func test_raid_extraction_extracts_player() -> void:
	var zone := Area3D.new()
	zone.set_script(_tool_copy(_install_raid_template("raid_extraction")))
	zone.set("restart_delay", 0.0)
	var holder := Node3D.new()
	holder.name = "RaidZoneHolder"
	_root().add_child(holder)
	_added.append(holder)
	holder.add_child(zone)
	var bag_script := GDScript.new()
	bag_script.source_code = "@tool\nextends Node\nfunc get_total_value():\n\treturn 1550\n"
	bag_script.reload()
	var player := CharacterBody3D.new()
	player.add_to_group(&"player")
	var bag := Node.new()
	bag.name = "Inventory"
	bag.set_script(bag_script)
	player.add_child(bag)
	holder.add_child(player)
	var other := CharacterBody3D.new()
	holder.add_child(other)
	zone._on_body_entered(other)
	assert_eq(zone.time_left(), -1.0, "only the player group")
	zone._on_body_entered(player)
	assert_eq(zone.time_left(), 5.0)
	zone._on_body_exited(player)
	assert_eq(zone.time_left(), -1.0, "leaving cancels")
	var got := []
	zone.extracted.connect(func(b): got.append(b))
	zone.extract(player)
	assert_eq(got, [player])
	assert_eq(player.process_mode, Node.PROCESS_MODE_DISABLED, "player frozen")
	assert_contains(zone._hud.text, "1550")
	zone.extract(player)
	assert_eq(got.size(), 1, "extracts once")


func _install_raid_template(name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _install_template(name)


# --- raid playtest -----------------------------------------------------------------

func _agent() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("raid_playtest_agent"))


func test_playtest_run_params_defaults_and_errors() -> void:
	var p: Dictionary = PlaytestTools.read_run_params({})
	assert_eq(p.duration, 60.0)
	assert_eq(p.time_scale, 1.0)
	assert_true(p.wait)
	assert_true(p.crates and p.loot and p.fight and p.extract and p.stop_after)
	assert_false(p.hunt or p.explore or p.invulnerable)
	assert_eq(p.max_crates, -1)
	assert_eq(p.script_dir, "res://scripts/topdown")
	assert_is_error(PlaytestTools.read_run_params({"bogus": 1}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"duration": 1}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"time_scale": 9}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"hunt": "yes"}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"max_crates": 1.5}), "INVALID_PARAMS")
	assert_is_error(PlaytestTools.read_run_params({"script_dir": "res://addons/x"}), "INVALID_PARAMS")


func test_playtest_tool_rejects_bad_calls() -> void:
	assert_is_error(_playtest.raid_playtest({"op": "dance"}), "INVALID_PARAMS")
	assert_is_error(_playtest.raid_playtest({"op": "report", "duration": 5}), "INVALID_PARAMS")
	assert_is_error(_playtest.raid_playtest({"scene": "res://nope/missing.tscn"}), "NODE_NOT_FOUND")
	assert_is_error(_playtest.raid_playtest({"scene": "scenes/raid.tscn"}), "INVALID_PARAMS")
	## wait=true must fit the tool's 120 s budget in real seconds.
	assert_is_error(_playtest.raid_playtest({"duration": 300}), "INVALID_PARAMS")
	## No deferred context (e.g. a direct call): refuses before touching anything.
	assert_is_error(_playtest.raid_playtest({"duration": 300, "time_scale": 4}), "INTERNAL_ERROR")


func test_playtest_request_matches_agent_defaults() -> void:
	var agent := _agent()
	var defaults: Dictionary = agent.get_script_constant_map()["DEFAULTS"]
	var request := PlaytestTools.build_request(PlaytestTools.read_run_params({"hunt": true, "duration": 30}), "abc")
	assert_eq(request.token, "abc")
	assert_true(request.hunt)
	assert_eq(request.duration, 30.0)
	assert_gt(float(request.created_unix), 0.0)
	for key in request:
		if key != "created_unix":
			assert_true(defaults.has(key), "agent understands '%s'" % key)


func test_playtest_input_inverts_camera_relative_movement() -> void:
	var agent := _agent()
	## The player controller's _camera_relative(), for comparison.
	var forward_of := func(cam: Basis, input: Vector2) -> Vector3:
		var f := -cam.z
		f.y = 0.0
		var r := cam.x
		r.y = 0.0
		return (r.normalized() * input.x - f.normalized() * input.y).limit_length(1.0)
	var cam := Basis.from_euler(Vector3(deg_to_rad(-55.0), deg_to_rad(30.0), 0.0))
	for dir in [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-0.6, 0, 0.8), Vector3(0.3, 0, 0.3)]:
		var input: Vector2 = agent.input_for_direction(dir, cam)
		var moved: Vector3 = forward_of.call(cam, input)
		var want: Vector3 = dir.limit_length(1.0)
		assert_true(moved.distance_to(want) < 0.001, "input %s moves %s, wanted %s" % [input, moved, want])
	assert_eq(agent.input_for_direction(Vector3.ZERO, cam), Vector2.ZERO)
	## A straight-down camera falls back to world axes.
	var down := Basis.from_euler(Vector3(deg_to_rad(-90.0), 0.0, 0.0))
	var input2: Vector2 = agent.input_for_direction(Vector3(1, 0, 0), down)
	assert_true(input2.distance_to(Vector2(1, 0)) < 0.001, "top-down camera: %s" % input2)


func test_playtest_agent_inert_without_request() -> void:
	var agent := _agent()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PlaytestTools.REQUEST_PATH))
	assert_eq(agent.read_request(), null)
	## A stale request is consumed and ignored.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PlaytestTools.DIR))
	var f := FileAccess.open(PlaytestTools.REQUEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "old", "created_unix": Time.get_unix_time_from_system() - 3600}))
	f.close()
	assert_eq(agent.read_request(), null)
	assert_false(FileAccess.file_exists(PlaytestTools.REQUEST_PATH), "consumed")
	f = FileAccess.open(PlaytestTools.REQUEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "new", "created_unix": Time.get_unix_time_from_system(), "hunt": true}))
	f.close()
	var request: Dictionary = agent.read_request()
	assert_eq(request.token, "new")
	var config: Dictionary = agent.merge_config(request)
	assert_true(config.hunt)
	assert_eq(config.duration, 60.0, "defaults fill the rest")


func test_playtest_performance_summary() -> void:
	var agent := _agent()
	var frames := PackedFloat32Array()
	for i in 99:
		frames.append(10.0)
	frames.append(50.0)
	var perf: Dictionary = agent.performance_summary(frames, [100, 60, 95])
	assert_eq(perf.frames, 100)
	assert_eq(perf.frame_ms_max, 50.0)
	assert_eq(perf.fps_min, 60.0)
	assert_eq(perf.fps_1pct_low, 20.0)
	assert_true(absf(perf.fps_avg - 1000.0 / 10.4) < 0.1, "avg %s" % perf.fps_avg)
	var empty: Dictionary = agent.performance_summary(PackedFloat32Array(), [])
	assert_eq(empty.frames, 0)


func test_playtest_issues_and_verdict() -> void:
	var agent := _agent()
	var clean := {
		"result": "extracted", "game_time": 40.0,
		"errors": {"count": 0},
		"combat": {"weapon": "Smg", "shots": 10, "hits": 5, "enemies_killed": 2, "enemies_total": 2},
		"navigation": {"nav_ready": true, "stuck": [], "unreachable": []},
		"loot": {"pickups_refused": 0, "crates_opened": 3, "crates_total": 3},
		"performance": {"frames": 100, "fps_min": 58.0, "fps_avg": 60.0},
	}
	assert_eq(agent.find_issues(clean, {}), [])
	clean["issues"] = []
	var ok := PlaytestTools.summarize(clean, {"token": "t"})
	assert_eq(ok.verdict, "pass")
	assert_eq(ok.token, "t")
	assert_contains(ok.summary, "crates 3/3")
	var bad := clean.duplicate(true)
	bad.result = "died"
	bad.errors = {"count": 2}
	bad.combat.weapon = ""
	bad.navigation = {"nav_ready": false, "stuck": [{"t": 1}], "unreachable": [{"kind": "crate", "target": "Crate2", "reason": "stuck"}]}
	bad.loot.pickups_refused = 1
	bad.performance.fps_min = 12.0
	var issues: Array = agent.find_issues(bad, {"min_fps": 30.0})
	assert_eq(issues.size(), 8, str(issues))
	assert_contains(str(issues), "Crate2")
	bad["issues"] = issues
	assert_eq(PlaytestTools.summarize(bad).verdict, "issues")
	## A timeout only counts when extraction was the goal.
	var timeout := clean.duplicate(true)
	timeout.result = "timeout"
	assert_eq(agent.find_issues(timeout, {"extract": false}), [])
	assert_eq(agent.find_issues(timeout, {"extract": true}).size(), 1)


func test_playtest_report_op_reads_matching_token() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PlaytestTools.DIR))
	var f := FileAccess.open(PlaytestTools.REPORT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"token": "r1", "result": "extracted", "issues": []}))
	f.close()
	assert_eq(PlaytestTools.read_report("other"), null)
	assert_eq(PlaytestTools.read_report("r1").result, "extracted")
	var out: Dictionary = _playtest.raid_playtest({"op": "report"})
	assert_eq(out.data.verdict, "pass")
	assert_eq(out.data.result, "extracted")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PlaytestTools.REPORT_PATH))
	assert_eq(_playtest.raid_playtest({"op": "report"}).data.status, "no_report")


func test_playtest_install_registers_autoload_with_undo() -> void:
	var key := PlaytestTools.autoload_key()
	var before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var dir := WORK_DIR + "/agent"
	var out: Dictionary = _playtest.raid_playtest({"op": "install", "script_dir": dir})
	assert_eq(out.data.script, dir + "/raid_playtest_agent.gd")
	assert_eq(out.data.script_status, "created")
	assert_true(FileAccess.file_exists(dir + "/raid_playtest_agent.gd"))
	assert_eq(ProjectSettings.get_setting(key), "*" + dir + "/raid_playtest_agent.gd")
	assert_contains(FileAccess.get_file_as_string("res://project.godot"), dir + "/raid_playtest_agent.gd", "saved to project.godot")
	var again: Dictionary = _playtest.raid_playtest({"op": "install", "script_dir": dir})
	assert_eq(again.data.script_status, "kept")
	assert_eq(again.data.autoload_status, "kept")
	EditorInterface.get_editor_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY).undo()
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, before, "undo restores the autoload")
	_playtest.raid_playtest({"op": "install", "script_dir": dir})
	var removed: Dictionary = _playtest.raid_playtest({"op": "uninstall"})
	assert_true(removed.data.removed)
	assert_false(ProjectSettings.has_setting(key))
	assert_true(FileAccess.file_exists(dir + "/raid_playtest_agent.gd"), "script kept")
	if before != null:
		ProjectSettings.set_setting(key, before)
		ProjectSettings.save()


# --- hideout -------------------------------------------------------------------------

const HIDEOUT_SAVE := "user://zz_mcp_test_hideout/save.json"


## A @tool item database holding bandage (stack 5, 0.1 kg, 50), rifle (3x1,
## 3.5 kg, 9000) and watch (0.2 kg, 1500).
func _hideout_db() -> Resource:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	var db := Resource.new()
	db.set_script(_tool_copy(_install_template("item_database")))
	var items: Array[Resource] = [
		_test_item("bandage", 1, 1, 5, 0.1, 50),
		_test_item("rifle", 3, 1, 1, 3.5, 9000),
		_test_item("watch", 1, 1, 1, 0.2, 1500),
	]
	db.set("items", items)
	return db


func _hideout_bag(db: Resource, w: int, h: int, max_weight := 0.0) -> Node:
	var bag := _test_bag(w, h, max_weight)
	bag.set("item_database", db)
	return bag


func _hideout_state_script() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("hideout_state"))


## A HideoutState (tool copy) outside the tree, saving to HIDEOUT_SAVE.
func _hideout_state(db: Resource) -> Node:
	var state := Node.new()
	state.set_script(_hideout_state_script())
	state.set("save_path", HIDEOUT_SAVE)
	state.set("hideout_scene", "")
	state.set("_db", db)
	_added.append(state)
	return state


func _read_json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func test_hideout_fill_transfer_and_move_all() -> void:
	var db := _hideout_db()
	var S := _hideout_state_script()
	var stash := _hideout_bag(db, 4, 3)
	var bag := _hideout_bag(db, 2, 2, 4.0)
	var left: Array = S.fill_inventory(stash, [
		{"item_id": "rifle", "count": 1, "x": 1, "y": 0, "rotated": false},
		{"item_id": "bandage", "count": 4, "x": 0, "y": 0, "rotated": false},
		{"item_id": "bandage", "count": 3, "x": 1, "y": 0, "rotated": false},
		{"item_id": "ghost", "count": 1, "x": 0, "y": 2, "rotated": false},
	])
	assert_eq(left, [{"item_id": "ghost", "count": 1, "unknown": true}], "unknown ids come back")
	assert_eq([stash.entries[0].x, stash.entries[0].y], [1, 0], "saved cell kept")
	assert_eq(stash.count_of("bandage"), 7, "a stack on a taken cell is placed elsewhere")
	var rifle_index := 0
	assert_eq(S.transfer(stash, rifle_index, bag, Vector2i(0, 0)), 0, "3x1 rifle does not fit a 2x2 bag")
	assert_eq(S.transfer(stash, rifle_index, bag, Vector2i(0, 0), true), 0, "nor turned")
	assert_eq(stash.count_of("rifle"), 1, "a failed move changes nothing")
	var full_stack := -1
	for i in stash.entries.size():
		if stash.item_id_of(stash.entries[i].item) == "bandage" and int(stash.entries[i].count) == 5:
			full_stack = i
	assert_eq(S.transfer(stash, full_stack, bag, Vector2i(0, 0)), 5, "stack dropped on a cell")
	assert_eq(S.transfer(stash, stash.entries.size() - 1, bag, Vector2i(0, 0)), 0, "full stack under it: no merge")
	assert_eq(S.transfer(stash, stash.entries.size() - 1, bag, Vector2i(1, 0)), 2, "free cell")
	assert_eq(stash.count_of("bandage"), 0)
	assert_true(is_equal_approx(bag.get_total_weight(), 0.7), "0.7 kg in the bag")
	bag.set("max_weight", 1.0)
	stash.add_item("bandage", 5)
	var idx: int = stash.entries.size() - 1
	assert_eq(S.transfer(stash, idx, bag), 3, "weight limit lets 3 more in")
	assert_eq(stash.count_of("bandage"), 2, "the rest stays")
	assert_eq(S.move_all(bag, stash), {"bandage": 10})
	assert_true(bag.entries.is_empty())
	var tiny := _hideout_bag(db, 1, 1)
	tiny.add_item("watch")
	assert_eq(S.move_all(stash, tiny), {}, "nothing fits a full grid")
	assert_eq(stash.count_of("rifle"), 1, "and nothing is lost")
	assert_eq(S.count_items([{"item_id": "a", "count": 2}, {"item_id": "a", "count": 3}, {"item_id": "b", "count": 1}]), {"a": 5, "b": 1})


func test_hideout_state_extract_death_mia_and_save() -> void:
	_remove_tree(ProjectSettings.globalize_path(HIDEOUT_SAVE.get_base_dir()))
	var db := _hideout_db()
	var state := _hideout_state(db)
	var bag := _hideout_bag(db, 4, 3)
	bag.name = "Inventory"
	var body: Node = bag.get_parent()
	bag.add_item("bandage", 3)
	bag.add_item("watch")
	state.set("raid_active", true)
	state.set("_player", body)
	state.set("_kit_value", 150)
	state._on_extracted(null)
	assert_true(state.pending_return, "bag is on its way home")
	assert_eq(state.loadout, bag.to_data())
	assert_eq(state.stats.extracted, 1)
	assert_eq(state.stats.raids, 1)
	assert_eq(state.last_raid.value, 1650)
	assert_eq(state.last_raid.profit, 1500)
	assert_eq(state.last_raid.items, {"bandage": 3, "watch": 1})
	var saved: Dictionary = _read_json(HIDEOUT_SAVE)
	assert_true(saved.pending_return, "saved at extraction")
	assert_eq(saved.loadout.size(), 2)
	state._on_extracted(null)
	assert_eq(state.stats.extracted, 1, "ends once")

	## Back in the hideout: the bag moves into the stash.
	var home := _hideout_state(db)
	home.load_game()
	assert_true(home.pending_return)
	var stash := _hideout_bag(db, 4, 3)
	var bag2 := _hideout_bag(db, 2, 2)
	var got := []
	home.hideout_ready.connect(func(_h, s): got.append(s))
	var summary: Dictionary = home.enter_hideout(null, stash, bag2)
	assert_true(summary.returned)
	assert_eq(summary.moved, {"bandage": 3, "watch": 1})
	assert_true(bag2.entries.is_empty(), "bag emptied into the stash")
	assert_eq(stash.count_of("watch"), 1)
	assert_false(home.pending_return)
	assert_eq(got.size(), 1, "hideout_ready")
	saved = _read_json(HIDEOUT_SAVE)
	assert_eq(saved.stash.size(), 2)
	assert_eq(saved.loadout, [])
	assert_false(saved.pending_return)

	## Dying loses the bag.
	state.set("_ending", false)
	state.set("raid_active", true)
	state._on_player_died()
	assert_eq(state.loadout, [])
	assert_eq(state.stats.died, 1)
	assert_eq(state.stats.raids, 2)
	assert_eq(state.last_raid.result, "died")
	assert_eq(state.last_raid.value_lost, 1650)
	assert_eq(state.stats.value_lost, 1650)

	## Closing the game mid-raid counts as a loss on the next start.
	state.set("in_raid", true)
	state.set("loadout", [{"item_id": "rifle", "count": 1, "x": 0, "y": 0, "rotated": false}])
	state.save_game()
	var next := _hideout_state(db)
	next.load_game()
	assert_eq(next.stats.mia, 1)
	assert_eq(next.last_raid.result, "mia")
	assert_eq(next.last_raid.value_lost, 9000)
	assert_eq(next.loadout, [])
	assert_false(next.in_raid)
	assert_false(_read_json(HIDEOUT_SAVE).in_raid, "loss saved")

	## A new game waits to put starting_stash into the stash.
	next.set("starting_stash", [{"item_id": "bandage", "count": 2}])
	next.new_game()
	assert_eq(next.overflow, [{"item_id": "bandage", "count": 2}])
	assert_eq(next.stats.raids, 0)
	var fresh := _hideout_bag(db, 3, 3)
	var s2: Dictionary = next.enter_hideout(null, fresh, _hideout_bag(db, 2, 2))
	assert_eq(s2.placed_waiting, {"bandage": 2})
	assert_eq(fresh.count_of("bandage"), 2)
	assert_eq(next.overflow, [])

	## A broken save is set aside.
	var f := FileAccess.open(HIDEOUT_SAVE, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	var broken := _hideout_state(db)
	broken.load_game()
	assert_true(FileAccess.file_exists(HIDEOUT_SAVE + ".bad"), "kept as .bad")
	assert_eq(broken.stash, [])


func test_hideout_state_deploy_gives_player_the_bag() -> void:
	var db := _hideout_db()
	var state := _hideout_state(db)
	var bag := _hideout_bag(db, 4, 3)
	bag.name = "Inventory"
	var body: Node = bag.get_parent()
	body.add_to_group(&"player")
	bag.add_item("bandage", 2)
	var zone := Area3D.new()
	zone.set_script(_tool_copy(_install_raid_template("raid_extraction")))
	zone.set("restart_delay", 4.0)
	body.get_parent().add_child(zone)
	_added.append(zone)
	_root().add_child(state)
	state.set_process(false)
	state.set("save_path", HIDEOUT_SAVE)
	state.set("hideout_scene", "res://zz_mcp_test_topdown/hideout.tscn")
	state.set("_db", db)
	state.set("loadout", [{"item_id": "rifle", "count": 1, "x": 0, "y": 0, "rotated": false}])
	state.set("_deploy_pending", true)
	var got := []
	state.raid_started.connect(func(f): got.append(f))
	state.begin_raid()
	assert_eq(got, [true], "raid from the hideout")
	assert_eq(bag.count_of("rifle"), 1, "the bag replaces the starting kit")
	assert_eq(bag.count_of("bandage"), 0)
	assert_true(state.raid_active)
	assert_true(zone.is_connected(&"extracted", Callable(state, "_on_extracted")), "extraction hooked")
	assert_eq(zone.get("restart_delay"), 0.0, "the zone no longer reloads the raid")
	assert_eq(state.deploy(bag, bag, "res://zz_mcp_test_topdown/nope.tscn"), ERR_FILE_NOT_FOUND)


func test_hideout_ui_builds_and_moves_between_grids() -> void:
	var db := _hideout_db()
	var inv_script := _tool_copy(_install_template("inventory"))
	var ui := Control.new()
	ui.name = "HideoutUiTest"
	ui.set_script(_tool_copy(_install_template("hideout")))
	ui.set("raid_scene", "res://zz_mcp_test_topdown/nope.tscn")
	for spec in [["Stash", 6, 4, 0.0], ["Loadout", 2, 2, 5.0]]:
		var inv := Node.new()
		inv.name = spec[0]
		inv.set_script(inv_script)
		inv.set("grid_width", spec[1])
		inv.set("grid_height", spec[2])
		inv.set("max_weight", spec[3])
		inv.set("item_database", db)
		ui.add_child(inv)
	_root().add_child(ui)
	_added.append(ui)
	assert_true(ui.is_hideout())
	var stash: Node = ui.get("stash")
	var bag: Node = ui.get("loadout")
	assert_true(stash != null and bag != null, "finds both grids")
	stash.add_item("rifle")
	stash.add_item("watch")
	assert_contains(ui.get("_stash_label").text, "10,500")
	assert_eq(ui.transfer_entry(stash, 0), 0, "rifle does not fit the 2x2 bag")
	assert_eq(ui.transfer_entry(stash, 1), 1, "watch goes in")
	assert_eq(bag.count_of("watch"), 1)
	assert_contains(ui.get("_bag_label").text, "0.2")
	ui.unpack_bag()
	assert_eq(stash.count_of("watch"), 1)
	assert_true(bag.entries.is_empty())
	assert_eq(ui.deploy(), ERR_FILE_NOT_FOUND, "missing raid scene")


## A raid scene file with an extraction zone and a player whose Inventory
## is 5x4 / 22 kg and starts with 2 bandages.
func _hideout_raid_scene() -> String:
	_install_raid_template("raid_extraction")
	_install_template("inventory")
	_install_template("player_controller")
	var root := Node3D.new()
	root.name = "RaidTest"
	var zone := Area3D.new()
	zone.name = "Exit"
	zone.set_script(load(WORK_DIR + "/scripts/raid_extraction.gd"))
	root.add_child(zone)
	zone.owner = root
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load(WORK_DIR + "/scripts/player_controller.gd"))
	root.add_child(player)
	player.owner = root
	var inv := Node.new()
	inv.name = "Inventory"
	inv.set_script(load(WORK_DIR + "/scripts/inventory.gd"))
	inv.set("grid_width", 5)
	inv.set("grid_height", 4)
	inv.set("max_weight", 22.0)
	var start: Array[Dictionary] = [{"item_id": "bandage", "count": 2}]
	inv.set("starting_items", start)
	player.add_child(inv)
	inv.owner = root
	var path := WORK_DIR + "/raid_test.tscn"
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	ResourceSaver.save(packed, path)
	return path


func _hideout_params(raid: String, extra: Dictionary = {}) -> Dictionary:
	var params := {
		"raid_scene": raid,
		"hideout_scene": WORK_DIR + "/hideout.tscn",
		"script_dir": WORK_DIR + "/scripts",
		"database_path": ITEM_DIR + "/item_database.tres",
		"save_path": HIDEOUT_SAVE,
	}
	params.merge(extra, true)
	return params


func test_hideout_scaffold_scene_settings_and_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var info := HideoutTools.inspect_scene(raid)
	assert_eq(info.extractions, 1)
	assert_true(info.player)
	assert_eq(info.inventory.grid_width, 5)
	var key := "autoload/" + HideoutTools.AUTOLOAD_NAME
	var autoload_before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var main_before := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var scene_path := WORK_DIR + "/hideout.tscn"

	var dry := _hideout.hideout_scaffold(_hideout_params(raid, {"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.loadout.grid, [5, 4], "bag size from the raid player's inventory")
	assert_eq(dry.data.loadout.max_weight, 22.0)
	assert_eq(dry.data.starting_stash, [{"item_id": "bandage", "count": 2}], "starting stash from its starting_items")
	assert_false(FileAccess.file_exists(scene_path), "dry run writes nothing")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before)

	var result := _hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 8, "stash_height": 9}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.hideout_scene_status, "created")
	assert_true(FileAccess.file_exists(scene_path))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/hideout_state.gd"))
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/hideout.gd"))
	var scene := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq(scene.get_node("Stash").get("grid_width"), 8)
	assert_eq(scene.get_node("Stash").get("grid_height"), 9)
	assert_eq(scene.get_node("Stash").get("max_weight"), 0.0)
	assert_eq(scene.get_node("Loadout").get("grid_width"), 5)
	assert_eq(scene.get_node("Loadout").get("max_weight"), 22.0)
	assert_eq(scene.get_node("Loadout").get("item_database").resource_path, ITEM_DIR + "/item_database.tres")
	scene.free()
	assert_eq(ProjectSettings.get_setting(key), "*" + WORK_DIR + "/scripts/hideout_state.gd")
	assert_eq(ProjectSettings.get_setting("game/hideout/raid_scene"), raid)
	assert_eq(ProjectSettings.get_setting("game/hideout/save_path"), HIDEOUT_SAVE)
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), scene_path)
	assert_contains(FileAccess.get_file_as_string("res://project.godot"), "hideout_state.gd", "saved to project.godot")

	var again := _hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 12, "return_delay": 1.0}))
	assert_eq(again.data.hideout_scene_status, "kept")
	assert_eq(again.data.starting_stash_from, "kept")
	assert_true(again.data.warnings.any(func(w): return String(w).contains("kept")), "says the scene was kept")
	assert_eq(ProjectSettings.get_setting("game/hideout/return_delay"), 1.0)

	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the rerun")
	assert_eq(ProjectSettings.get_setting("game/hideout/return_delay"), 3.0)
	assert_true(FileAccess.file_exists(scene_path), "the rerun did not write the scene")
	assert_true(global_ur.undo(), "undo the scaffold")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before, "autoload removed")
	assert_eq(str(ProjectSettings.get_setting("application/run/main_scene", "")), main_before, "main scene restored")
	assert_false(ProjectSettings.has_setting("game/hideout/raid_scene"))
	assert_false(FileAccess.file_exists(scene_path), "scene file removed")


func test_hideout_scaffold_rejects_bad_params() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"bogus": 1})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"save_path": "res://save.json"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"save_path": "user://save.txt"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"hideout_scene": "res://addons/x.tscn"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"hideout_scene": raid})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(WORK_DIR + "/missing.tscn")), "NODE_NOT_FOUND")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"stash_width": 0})), "INVALID_PARAMS")
	var unknown := _hideout.hideout_scaffold(_hideout_params(raid, {"starting_stash": [{"item_id": "nope"}]}))
	assert_is_error(unknown, "INVALID_PARAMS")
	assert_contains(unknown.error.message, "nope")
	var none := _hideout.hideout_scaffold(_hideout_params(""))
	if str(ProjectSettings.get_setting("game/hideout/raid_scene", "")).is_empty():
		assert_is_error(none, "INVALID_PARAMS", "no raid scene to find")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout.tscn"), "errors write nothing")
	assert_false(ProjectSettings.has_setting("game/hideout/raid_scene"))


func test_hideout_map_scaffold_builds_room_and_undo() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var key := "autoload/" + HideoutTools.AUTOLOAD_NAME
	var autoload_before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var main_before := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var menu_path := WORK_DIR + "/hideout.tscn"
	var map_path := WORK_DIR + "/hideout_map.tscn"
	var params := _hideout_params(raid, {"style": "map", "map_scene": map_path, "map_size": [16, 12], "deploy_time": 2.0, "interact_action": ACTION_PREFIX + "interact"})

	var dry := _hideout.hideout_scaffold(params.merged({"dry_run": true}))
	assert_has_key(dry, "data", str(dry))
	assert_eq(dry.data.would.map_scene, "create")
	assert_eq(dry.data.map.room, [16.0, 12.0])
	assert_false(FileAccess.file_exists(map_path), "dry run writes nothing")

	var result := _hideout.hideout_scaffold(params)
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.map.status, "created")
	assert_eq(result.data.hideout_scene_status, "created")
	assert_true(FileAccess.file_exists(map_path))
	for f in ["hideout_map.gd", "hideout_door.gd", "hideout_locker.gd", "topdown_camera_rig.gd"]:
		assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/" + f), f)
	assert_true(InputMap.has_action(ACTION_PREFIX + "interact"), "interact action created")
	assert_eq(ProjectSettings.get_setting("game/hideout/hideout_scene"), map_path, "raids come home to the map")
	assert_eq(ProjectSettings.get_setting("game/hideout/menu_scene"), menu_path)
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), map_path)

	var map := (ResourceLoader.load(map_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	assert_eq((map.get_script() as Script).resource_path.get_file(), "hideout_map.gd")
	assert_eq(map.get("interact_action"), StringName(ACTION_PREFIX + "interact"))
	for path in ["Player", "TopdownCamera/Camera3D", "StashLocker/Label", "DeployDoor/Shape", "Room/Floor", "Room/WallFarLeft", "PlayerSpawn", "StashScreen/Hideout/Stash", "StashScreen/Hideout/Loadout"]:
		assert_true(map.get_node_or_null(path) != null, "map has " + path)
	assert_eq(map.get_node("StashScreen/Hideout").scene_file_path, menu_path, "stash screen is the menu hideout")
	assert_false(map.get_node("StashScreen").visible, "stash screen starts hidden")
	assert_eq(map.get_node("DeployDoor").get("deploy_time"), 2.0)
	assert_eq(map.get_node("TopdownCamera").get("target_path"), NodePath("../Player"))
	assert_true(map.get_node("Player").get_script() != null, "player has a controller")
	## The room is 16 x 12: the door pad sits inside, at the far wall.
	assert_true(absf(map.get_node("DeployDoor").position.z - (-6.0 + 1.2)) < 0.01)
	map.free()

	var again := _hideout.hideout_scaffold(params)
	assert_eq(again.data.map.status, "kept")
	assert_true(again.data.warnings.any(func(w): return String(w).contains("hideout_map.tscn exists")), "says the map was kept")

	var global_ur := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	assert_true(global_ur.undo(), "undo the rerun")
	assert_true(FileAccess.file_exists(map_path), "the rerun did not write the map")
	assert_true(global_ur.undo(), "undo the scaffold")
	assert_false(FileAccess.file_exists(map_path), "map file removed")
	assert_false(FileAccess.file_exists(menu_path), "menu scene removed")
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, autoload_before, "autoload removed")
	assert_eq(str(ProjectSettings.get_setting("application/run/main_scene", "")), main_before, "main scene restored")
	assert_false(ProjectSettings.has_setting("game/hideout/hideout_scene"))


func test_hideout_map_rejects_bad_params() -> void:
	_clear_items()
	assert_has_key(_items.item_db_import(_item_params()), "data")
	var raid := _hideout_raid_scene()
	var base := {"style": "map", "map_scene": WORK_DIR + "/hideout_map.tscn"}
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, {"style": "3d"})), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_size": [4, 4]}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_size": "big"}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"map_scene": raid}, true))), "INVALID_PARAMS")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"player_scene": WORK_DIR + "/nope.tscn"}, true))), "NODE_NOT_FOUND")
	assert_is_error(_hideout.hideout_scaffold(_hideout_params(raid, base.merged({"interact_action": "bad action"}, true))), "INVALID_PARAMS")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout_map.tscn"), "errors write nothing")
	assert_false(FileAccess.file_exists(WORK_DIR + "/hideout.tscn"))


func test_hideout_map_locker_door_and_disarm() -> void:
	var db := _hideout_db()
	var inv_script := _tool_copy(_install_template("inventory"))
	_install_template("player_controller")
	var map := Node3D.new()
	map.name = "HideoutMapTest"
	map.set_script(_tool_copy(_install_template("hideout_map")))
	map.set("interact_action", StringName(ACTION_PREFIX + "interact"))
	var screen := CanvasLayer.new()
	screen.name = "StashScreen"
	map.add_child(screen)
	var ui := Control.new()
	ui.name = "Hideout"
	ui.set_script(_tool_copy(_install_template("hideout")))
	ui.set("raid_scene", "res://zz_mcp_test_topdown/nope.tscn")
	for spec in [["Stash", 6, 4, 0.0], ["Loadout", 3, 3, 0.0]]:
		var inv := Node.new()
		inv.name = spec[0]
		inv.set_script(inv_script)
		inv.set("grid_width", spec[1])
		inv.set("grid_height", spec[2])
		inv.set("max_weight", spec[3])
		inv.set("item_database", db)
		ui.add_child(inv)
	screen.add_child(ui)
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(_tool_copy(WORK_DIR + "/scripts/player_controller.gd"))
	var aim := Node3D.new()
	aim.name = "Aim"
	player.add_child(aim)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	aim.add_child(mount)
	var gun_script := GDScript.new()
	gun_script.source_code = "@tool\nextends Node3D\nfunc try_fire(_at: Vector3) -> bool:\n\treturn true\n"
	assert_eq(gun_script.reload(), OK)
	var gun := Node3D.new()
	gun.name = "Gun"
	gun.set_script(gun_script)
	mount.add_child(gun)
	map.add_child(player)
	var locker := StaticBody3D.new()
	locker.name = "StashLocker"
	locker.set_script(_tool_copy(_install_template("hideout_locker")))
	locker.position = Vector3(-5, 0, 0)
	map.add_child(locker)
	var door := Area3D.new()
	door.name = "DeployDoor"
	door.set_script(_tool_copy(_install_template("hideout_door")))
	door.position = Vector3(0, 0, -5)
	map.add_child(door)
	_root().add_child(map)
	_added.append(map)

	assert_true(map.is_hideout())
	assert_eq(map.get("player"), player)
	assert_eq(map.get("ui"), ui)
	assert_false(screen.visible, "stash screen starts hidden")
	assert_true(gun.is_queued_for_deletion() or gun.get_parent() == null, "no guns at home")
	var deploy_button: Button = ui.get("_deploy_button")
	assert_false(deploy_button.visible, "the menu's deploy button gives way to the door")
	assert_true(ui.find_child("CloseButton", true, false) is Button, "close button instead")
	assert_eq(map.get_stash(), ui.get("stash"))

	player.global_position = Vector3(0, 0, 3)
	assert_true(map.nearest_locker() == null, "locker out of reach")
	player.global_position = Vector3(-3.5, 0, 0.5)
	assert_eq(map.nearest_locker(), locker, "locker in reach")
	map.open_stash()
	assert_true(screen.visible)
	assert_true(map.is_stash_open)
	assert_false(player.is_physics_processing(), "player frozen while the stash is open")
	map.close_stash()
	assert_false(screen.visible)
	assert_true(player.is_physics_processing())

	ui.get("stash").add_item("bandage", 2)
	map._refresh_info()
	assert_contains(map.get("_info").text, "창고 ₩100")

	assert_eq(door.get_map(), map)
	assert_eq(door.time_left(), -1.0, "nobody on the pad")
	assert_eq(door.deploy(player), ERR_FILE_NOT_FOUND, "missing raid scene")
	assert_false(door.is_done, "the door stays usable after a failed deploy")
	assert_false(map.is_deploying)
	assert_eq(map.key_label(&"mcp_test_td_nope"), "mcp_test_td_nope")


func test_playtest_hideout_issues() -> void:
	var agent := _agent()
	var base := {"result": "extracted", "game_time": 30.0, "combat": {"weapon": "Rifle"}, "navigation": {"nav_ready": true}}
	var good := base.duplicate(true)
	good["hideout"] = {"linked": true, "raid_result": "extracted", "returned": true, "missing": {}, "unexpected": {}, "save_matches": true, "redeploy": {"ok": true}}
	assert_eq(agent.find_issues(good, {}), [])
	var not_linked := base.duplicate(true)
	not_linked["hideout"] = {"linked": false}
	assert_eq(agent.find_issues(not_linked, {}), [], "no hideout, no hideout issues")
	var lost := base.duplicate(true)
	lost["hideout"] = {"linked": true, "raid_result": "extracted", "returned": false, "error": "timeout while returning"}
	assert_contains(str(agent.find_issues(lost, {})), "은신처로 돌아가지 못함")
	var bad := base.duplicate(true)
	bad["hideout"] = {"linked": true, "raid_result": "extracted", "returned": true, "missing": {"watch": 1}, "unexpected": {}, "save_matches": false, "redeploy": {"ok": false, "expected_bag": {"a": 1}, "bag": {}}}
	var issues := str(agent.find_issues(bad, {}))
	assert_contains(issues, "watch x1")
	assert_contains(issues, "세이브")
	assert_contains(issues, "다시 출격")
	var summary: Dictionary = PlaytestTools.summarize({"result": "extracted", "issues": [], "hideout": good.hideout})
	assert_contains(str(summary.get("hideout", "")), "redeploy ok")
# --- playtest notes ------------------------------------------------------------------

func _notes_dir() -> String:
	return WORK_DIR + "/notes/"


## Writes a note file the way the in-game overlay does.
func _write_note(id: String, extra: Dictionary = {}) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_notes_dir()))
	var note := {
		"id": id, "status": "open", "text": "wall %s has a gap" % id, "category": "bug",
		"scene": "res://scenes/raid.tscn", "position": [1.0, 0.0, -2.0],
		"created": "2026-11-20T20:00:00", "created_unix": 1000.0 + float(id.hash() % 100),
		"screenshot": _notes_dir() + id + ".png",
	}
	note.merge(extra, true)
	var f := FileAccess.open(_notes_dir() + id + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(note))
	f.close()
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.save_png(_notes_dir() + id + ".png")
	return note


func _clear_notes() -> void:
	_remove_tree(ProjectSettings.globalize_path(_notes_dir()))


func _overlay() -> GDScript:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WORK_DIR + "/scripts"))
	return _tool_copy(_install_template("playtest_notes_overlay"))


func _global_undo() -> UndoRedo:
	return EditorInterface.get_editor_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func test_notes_list_filters_and_hints() -> void:
	_clear_notes()
	var empty: Dictionary = _notes.playtest_notes({})
	assert_eq(empty.data.count, 0)
	_write_note("n-a", {"created_unix": 10.0})
	_write_note("n-b", {"created_unix": 20.0, "category": "idea", "scene": "res://scenes/other.tscn"})
	_write_note("n-c", {"created_unix": 30.0, "status": "resolved"})
	var f := FileAccess.open(_notes_dir() + "broken.json", FileAccess.WRITE)
	f.store_string("{nope")
	f.close()
	var out: Dictionary = _notes.playtest_notes({"op": "list"}).data
	assert_eq(out.count, 2, "open only by default")
	assert_eq(out.notes[0].id, "n-a", "oldest first")
	assert_eq(out.open_total, 2)
	assert_eq(out.resolved_total, 1)
	assert_eq(out.broken_files.size(), 1)
	assert_true(String(out.notes[0].screenshot_path).ends_with("n-a.png"))
	assert_eq(_notes.playtest_notes({"status": "all"}).data.count, 3)
	assert_eq(_notes.playtest_notes({"status": "resolved"}).data.notes[0].id, "n-c")
	assert_eq(_notes.playtest_notes({"category": "idea"}).data.notes[0].id, "n-b")
	assert_eq(_notes.playtest_notes({"scene": "res://scenes/raid.tscn", "status": "all"}).data.count, 2)
	var limited: Dictionary = _notes.playtest_notes({"status": "all", "limit": 1}).data
	assert_eq(limited.shown, 1)
	assert_eq(limited.notes[0].id, "n-c", "limit keeps the newest")
	_clear_notes()


func test_notes_rejects_bad_calls() -> void:
	assert_is_error(_notes.playtest_notes({"op": "dance"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "list", "id": "x"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"status": "maybe"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"scene": "scenes/a.tscn"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get", "id": "../../project"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "get", "id": "missing-1"}), "NODE_NOT_FOUND")
	assert_is_error(_notes.playtest_notes({"op": "resolve", "ids": "a"}), "INVALID_PARAMS")
	assert_is_error(_notes.playtest_notes({"op": "install", "script_dir": "res://addons/x"}), "INVALID_PARAMS")


func test_notes_get_returns_full_note_and_screenshot() -> void:
	_clear_notes()
	_write_note("g-1", {"recent_errors": [{"kind": "error", "message": "boom"}], "cursor_node": "/Raid/Wall3"})
	var out: Dictionary = _notes.playtest_notes({"op": "get", "id": "g-1"}).data
	assert_eq(out.text, "wall g-1 has a gap")
	assert_eq(out.recent_errors[0].message, "boom")
	assert_true(out.screenshot_exists)
	assert_true(String(out.screenshot_path).begins_with("/") or String(out.screenshot_path).contains(":"), "absolute path")
	assert_true(String(out.note_path).ends_with("g-1.json"))
	_clear_notes()


func test_notes_resolve_reopen_with_undo() -> void:
	_clear_notes()
	_write_note("r-1")
	_write_note("r-2")
	var before := FileAccess.get_file_as_string(_notes_dir() + "r-1.json")
	var out: Dictionary = _notes.playtest_notes({"op": "resolve", "ids": ["r-1", "r-2"], "resolution": "closed the gap"}).data
	assert_eq(out.changed, ["r-1", "r-2"])
	var note: Dictionary = _notes.read_note("r-1")
	assert_eq(note.status, "resolved")
	assert_eq(note.resolution, "closed the gap")
	assert_true(note.has("resolved"))
	assert_eq(_notes.playtest_notes({}).data.count, 0)
	_global_undo().undo()
	assert_eq(FileAccess.get_file_as_string(_notes_dir() + "r-1.json"), before, "undo restores the file byte for byte")
	_global_undo().redo()
	assert_eq(_notes.read_note("r-2").status, "resolved", "redo")
	var again: Dictionary = _notes.playtest_notes({"op": "resolve", "id": "r-1"}).data
	assert_eq(again.changed, [], "already resolved")
	var reopened: Dictionary = _notes.playtest_notes({"op": "reopen", "id": "r-1"}).data
	assert_eq(reopened.changed, ["r-1"])
	assert_eq(_notes.read_note("r-1").status, "open")
	assert_false(_notes.read_note("r-1").has("resolved"))
	## A missing id fails before anything is written.
	assert_is_error(_notes.playtest_notes({"op": "resolve", "ids": ["r-2", "nope-9"]}), "NODE_NOT_FOUND")
	_clear_notes()


func test_notes_delete_with_undo() -> void:
	_clear_notes()
	_write_note("d-1")
	var out: Dictionary = _notes.playtest_notes({"op": "delete", "id": "d-1"}).data
	assert_eq(out.files.size(), 2, "json + png")
	assert_false(FileAccess.file_exists(_notes_dir() + "d-1.json"))
	assert_false(FileAccess.file_exists(_notes_dir() + "d-1.png"))
	_global_undo().undo()
	assert_true(FileAccess.file_exists(_notes_dir() + "d-1.json"), "undo brings the note back")
	assert_true(FileAccess.file_exists(_notes_dir() + "d-1.png"), "and its screenshot")
	_clear_notes()


func test_notes_markers_are_view_only() -> void:
	var root := _root()
	if not root is Node3D:
		skip("needs a 3D scene")
		return
	_clear_notes()
	var scene := root.scene_file_path
	_write_note("m-1", {"scene": scene, "position": [2.0, 0.0, 3.0]})
	_write_note("m-2", {"scene": scene, "status": "resolved"})
	_write_note("m-3", {"scene": "res://elsewhere.tscn"})
	var out: Dictionary = _notes.playtest_notes({"op": "markers"}).data
	assert_eq(out.count, 1, "open notes of the open scene")
	var holder := root.get_node_or_null(NotesTools.MARKERS_NAME)
	if holder == null:
		for child in root.get_children(true):
			if child.name == NotesTools.MARKERS_NAME:
				holder = child
	assert_true(holder != null, "pins added")
	assert_eq(holder.owner, null, "never saved")
	assert_eq(holder.get_child(0).position, Vector3(2, 0, 3))
	assert_eq(holder.get_child(0).get_meta(&"playtest_note_id"), "m-1")
	assert_false(out.undoable)
	## Resolving redraws the pins with the same filter.
	_notes.playtest_notes({"op": "resolve", "id": "m-1"})
	var count := 0
	for child in root.get_children(true):
		if child.name == NotesTools.MARKERS_NAME:
			count += 1
	assert_eq(count, 0, "no open notes left, so no pins")
	assert_eq(_notes.playtest_notes({"op": "markers", "status": "all"}).data.count, 2)
	assert_true(_notes.playtest_notes({"op": "clear_markers"}).data.removed)
	for child in root.get_children(true):
		assert_true(child.name != NotesTools.MARKERS_NAME, "cleared")
	_clear_notes()


func test_notes_install_registers_autoload_with_undo() -> void:
	var key := NotesTools.autoload_key()
	var before: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var dir := WORK_DIR + "/notes_script"
	var out: Dictionary = _notes.playtest_notes({"op": "install", "script_dir": dir})
	assert_eq(out.data.script, dir + "/playtest_notes_overlay.gd")
	assert_eq(out.data.script_status, "created")
	assert_eq(ProjectSettings.get_setting(key), "*" + dir + "/playtest_notes_overlay.gd")
	assert_eq(_notes.playtest_notes({"op": "install", "script_dir": dir}).data.autoload_status, "kept")
	_global_undo().undo()
	assert_eq(ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null, before, "undo restores the autoload")
	_notes.playtest_notes({"op": "install", "script_dir": dir})
	assert_true(_notes.playtest_notes({"op": "uninstall"}).data.removed)
	assert_false(ProjectSettings.has_setting(key))
	if before != null:
		ProjectSettings.set_setting(key, before)
		ProjectSettings.save()


func test_notes_overlay_note_key() -> void:
	var overlay := _overlay()
	var f8 := InputEventKey.new()
	f8.physical_keycode = KEY_F8
	f8.pressed = true
	if InputMap.has_action(&"playtest_note"):
		skip("project defines its own playtest_note action")
		return
	assert_true(overlay.is_note_key(f8), "F8")
	var f9 := f8.duplicate()
	f9.physical_keycode = KEY_F9
	assert_true(overlay.is_note_key(f9), "F9 (Windows editor eats F8)")
	var echo := f8.duplicate()
	echo.echo = true
	assert_false(overlay.is_note_key(echo), "no key repeat")
	var ctrl_n := InputEventKey.new()
	ctrl_n.physical_keycode = KEY_N
	ctrl_n.ctrl_pressed = true
	ctrl_n.pressed = true
	assert_true(overlay.is_note_key(ctrl_n), "Ctrl+N")
	var cmd_n := ctrl_n.duplicate()
	cmd_n.ctrl_pressed = false
	cmd_n.meta_pressed = true
	assert_true(overlay.is_note_key(cmd_n), "Cmd+N")
	var n := InputEventKey.new()
	n.physical_keycode = KEY_N
	n.pressed = true
	assert_false(overlay.is_note_key(n), "plain N is a game key")
	var id: String = overlay.new_id()
	assert_true(NotesTools.valid_id(id), "id %s is file safe" % id)


func test_notes_overlay_saves_note_the_tool_reads() -> void:
	_clear_notes()
	var script := _overlay()
	var overlay: Node = script.new()
	overlay.notes_folder = _notes_dir()
	overlay.set("_context", {
		"scene": "res://scenes/raid.tscn", "scene_name": "Raid",
		"cursor_position": [4.0, 0.0, 1.0], "player_position": [0.0, 0.0, 0.0],
		"cursor_node": "/Raid/Crate2", "fps": 60.0,
	})
	var shot := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	shot.fill(Color.BLACK)
	overlay.set("_shot", shot)
	var note: Dictionary = overlay.save_note("  crate floats  ", "bug", false)
	assert_false(note.has("error"), str(note))
	assert_eq(note.text, "crate floats")
	assert_eq(note.position, [4.0, 0.0, 1.0], "mouse spot by default")
	assert_eq(note.position_source, "cursor")
	assert_true(FileAccess.file_exists(_notes_dir() + ".gdignore"), "editor skips the folder")
	assert_true(FileAccess.file_exists(note.screenshot))
	var by_player: Dictionary = overlay.save_note("here", "idea", true)
	assert_eq(by_player.position, [0.0, 0.0, 0.0])
	assert_eq(by_player.position_source, "player")
	var listed: Dictionary = _notes.playtest_notes({"status": "all"}).data
	assert_eq(listed.count, 2, "the tool reads what the game wrote")
	var got: Dictionary = _notes.playtest_notes({"op": "get", "id": note.id}).data
	assert_eq(got.cursor_node, "/Raid/Crate2")
	assert_true(got.screenshot_exists)
	overlay.free()
	_clear_notes()


func test_notes_overlay_pin_and_ring() -> void:
	var script := _overlay()
	var pin: Node3D = script.make_pin(Vector3(1, 2, 3), Color.RED, "label")
	assert_eq(pin.position, Vector3(1, 2, 3))
	assert_eq(pin.get_child_count(), 4, "stick, head, ring, label")
	pin.free()
	var img := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	script.call("_ring", img, Vector2(20, 20), 10.0, 2.0, Color.RED)
	assert_eq(img.get_pixel(30, 20), Color.RED, "ring drawn")
	assert_eq(img.get_pixel(20, 20), Color.BLACK, "center left clear")
	var tool_pin := NotesTools.make_pin(Vector3.ZERO, Color.RED, "x")
	assert_eq(tool_pin.get_child_count(), 4, "editor pins match the game's")
	tool_pin.free()


# --- combat feedback -----------------------------------------------------------

func _feedback_params(extra: Dictionary = {}) -> Dictionary:
	var params := {"script_dir": WORK_DIR + "/scripts", "name": "TestCombatFeedback"}
	params.merge(extra, true)
	return params


func test_combat_feedback_setup_adds_node_with_undo() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	var result := _feedback.combat_feedback_setup(_feedback_params({"shell_casings": false, "shake_strength": 0.5}))
	assert_has_key(result, "data", str(result))
	assert_eq(result.data.mode, "created")
	var node := _track(result.data.node_path)
	assert_true(node != null, "node added")
	assert_eq((node.get_script() as Script).resource_path, WORK_DIR + "/scripts/combat_feedback.gd")
	assert_eq(node.get("shell_casings"), false, "switch applied")
	assert_eq(node.get("shake_strength"), 0.5, "tuning applied")
	assert_eq(result.data.effects.shell_casings, false)
	assert_eq(result.data.effects.muzzle_flash, true, "untouched switches keep the script default")
	assert_true(FileAccess.file_exists(WORK_DIR + "/scripts/combat_feedback.gd"))
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).undo()
	assert_true(McpScenePath.resolve(result.data.node_path, _root()) == null, "undo removes the node")
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).redo()
	assert_true(McpScenePath.resolve(result.data.node_path, _root()) != null, "redo adds it back")


func test_combat_feedback_rerun_retunes_existing_node() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	var first := _feedback.combat_feedback_setup(_feedback_params())
	assert_has_key(first, "data", str(first))
	var node := _track(first.data.node_path)
	var second := _feedback.combat_feedback_setup(_feedback_params({"screen_shake": false, "hitmarker_size": 20}))
	assert_has_key(second, "data", str(second))
	assert_eq(second.data.mode, "updated")
	assert_eq(second.data.node_path, first.data.node_path, "no second node")
	assert_eq(node.get("screen_shake"), false)
	assert_eq(node.get("hitmarker_size"), 20.0)
	assert_has_key(second.data.changed, "screen_shake")
	_undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root())).undo()
	assert_eq(node.get("screen_shake"), true, "undo restores the old settings")


func test_combat_feedback_rejects_bad_params() -> void:
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	for bad in [{"shake_strength": 9}, {"hitmarker": "yes"}, {"damage_number_font_size": 1.5}, {"name": "a/b"}, {"parent_path": "Nope/Missing"}, {"flesh_color": "not a color"}]:
		var result := _feedback.combat_feedback_setup(_feedback_params(bad))
		assert_eq(result.get("status"), "error", "rejects %s" % bad)


func _health_body_script(base: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = "@tool\nextends " + base + "\nsignal health_changed(current: float, maximum: float)\nvar health := 30.0\nvar max_health := 30.0\nfunc take_damage(amount: float, _info: Dictionary = {}) -> void:\n\thealth = maxf(health - amount, 0.0)\n\thealth_changed.emit(health, max_health)\n"
	assert_eq(script.reload(), OK)
	return script


func test_combat_feedback_reacts_to_shots_hits_kills_and_hurt() -> void:
	var weapon_result := _tools.weapon_create(_weapon_params("test_fx_gun", {"damage": 20, "spread_degrees": 0, "fire_rate": 100}))
	assert_has_key(weapon_result, "data", str(weapon_result))
	var setup := _feedback.combat_feedback_setup(_feedback_params({"name": "FxProbe"}))
	if not _root() is Node3D:
		skip("needs a 3D scene open")
		return
	assert_has_key(setup, "data", str(setup))
	_track(setup.data.node_path)

	var arena := Node3D.new()
	arena.name = "FxArena"
	_root().add_child(arena)
	_added.append(arena)
	arena.global_position = Vector3(0, 700, 0)
	var camera := Camera3D.new()
	camera.name = "Cam"
	arena.add_child(camera)
	## The shooter: a body in the player group, hurt by take_damage.
	var player := StaticBody3D.new()
	player.name = "FxPlayer"
	player.set_script(_health_body_script("StaticBody3D"))
	player.add_to_group(&"player")
	arena.add_child(player)
	var weapon := Node3D.new()
	weapon.name = "Gun"
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	weapon.add_child(muzzle)
	weapon.set_script(_tool_copy(weapon_result.data.scripts.weapon.path))
	weapon.set("data", ResourceLoader.load(weapon_result.data.data_path, "", ResourceLoader.CACHE_MODE_IGNORE))
	player.add_child(weapon)
	weapon.set_physics_process(false)
	var target := StaticBody3D.new()
	target.name = "FxTarget"
	target.set_script(_health_body_script("StaticBody3D"))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 1)
	shape.shape = box
	target.add_child(shape)
	arena.add_child(target)
	target.position = Vector3(0, 0, -5)
	PhysicsServer3D.body_set_state(target.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target.global_transform)

	var fx := Node.new()
	fx.name = "Fx"
	fx.set_script(_tool_copy(WORK_DIR + "/scripts/combat_feedback.gd"))
	fx.set("camera_path", NodePath("../Cam"))
	arena.add_child(fx)

	assert_true(weapon.try_fire(target.global_position), "shot 1")
	var stats: Dictionary = fx.get("stats")
	assert_eq(stats.shots, 1)
	assert_eq(stats.hits, 1, "hit on a damageable body")
	assert_eq(stats.kills, 0)
	var flash := muzzle.get_node_or_null("MuzzleFlash") as Node3D
	assert_true(flash != null and flash.visible, "muzzle flash shown at the muzzle")
	var effects: Node = fx.get_node("Effects")
	var labels := effects.get_children().filter(func(n: Node) -> bool: return n is Label3D)
	assert_eq(labels.size(), 1, "one damage number")
	assert_eq(labels[0].text, "20")
	assert_true(effects.get_children().any(func(n: Node) -> bool: return n is CPUParticles3D), "hit particles")
	assert_true(effects.get_children().any(func(n: Node) -> bool: return n is MeshInstance3D), "shell casing")
	assert_eq(fx.get("_markers").size(), 1, "hitmarker")

	weapon.set("_cooldown", 0.0)
	assert_true(weapon.try_fire(target.global_position), "shot 2")
	assert_eq(stats.kills, 1, "second hit kills (10 hp left)")
	labels = effects.get_children().filter(func(n: Node) -> bool: return n is Label3D)
	assert_eq(labels.size(), 1, "quick hits merge into one number")
	assert_eq(labels[0].text, "30", "merged total counts only the health actually lost")
	assert_eq(labels[0].modulate.r, (fx.get("kill_number_color") as Color).r, "kill color")
	assert_true(fx.get("_markers").back().kill, "kill marker")

	weapon.set("_cooldown", 0.0)
	weapon.try_fire(target.global_position)
	assert_eq(stats.hits, 2, "no hit counted on a dead body")

	player.take_damage(15.0)
	assert_eq(stats.hurts, 1, "player hurt")
	assert_true(float(fx.get("_vignette_alpha")) > 0.0, "vignette")
	assert_true(float(fx.get("_trauma")) > 0.0, "screen shake")
	fx.call("_update_shake", 0.016)
	assert_true(absf(camera.h_offset) + absf(camera.v_offset) > 0.0, "camera shakes")

	fx.set("enabled", false)
	weapon.set("_cooldown", 0.0)
	weapon.try_fire(target.global_position + Vector3(3, 0, 0))
	assert_eq(stats.shots, 3, "master switch off: nothing reacts")

