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
const ToolSpecs := preload("res://addons/topdown_shooter_tools/tool_specs.gd")

const WORK_DIR := "res://zz_mcp_test_topdown"
const ACTION_PREFIX := "mcp_test_td_"

var _tools: Tools
var _undo_redo: EditorUndoRedoManager
var _added: Array[Node] = []


func suite_name() -> String:
	return "topdown_shooter"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_tools = Tools.new()
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
	for suffix in Tools.INPUT_ACTIONS:
		var action: String = ACTION_PREFIX + suffix
		if ProjectSettings.has_setting("input/" + action):
			ProjectSettings.clear("input/" + action)
			changed = true
		if InputMap.has_action(action):
			InputMap.erase_action(action)
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
	assert_eq(specs.size(), 4)
	var names := []
	for spec in specs:
		assert_eq(spec.validate(), [] as Array[String], "spec %s" % spec.name)
		assert_true(spec.promoted)
		assert_true(spec.requires_writable)
		names.append(spec.name)
	assert_eq(names, ["topdown_camera_setup", "player_controller_scaffold", "weapon_create", "enemy_ai_scaffold"])


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
