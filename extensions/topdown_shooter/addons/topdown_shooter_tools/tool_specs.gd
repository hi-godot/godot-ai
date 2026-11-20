@tool
extends RefCounted

## Descriptors for the top-down shooter MCP tools, built on Godot AI's
## published McpCustomToolSpec class (requires the godot_ai addon files).

const SOURCE_PATH := "res://addons/topdown_shooter_tools/plugin.cfg"
const HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/topdown_tools.gd"
const ITEM_HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/item_tools.gd"

const _NUM := {"type": "number"}
const _BOOL := {"type": "boolean"}
const _STR := {"type": "string"}
const _VEC3 := {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}


static func definitions() -> Array[Dictionary]:
	return [
		{
			"name": "topdown_camera_setup",
			"method": &"camera_setup",
			"description": "Add a top-down follow camera rig (Node3D + Camera3D) to the open 3D scene. The rig follows a target on the XZ plane, leans toward the mouse cursor (aim lookahead) and has editable pitch/distance/yaw. Target defaults to the first node in group 'player'. Copies topdown_camera_rig.gd into script_dir (kept if it exists). One undo step.",
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"target_path": _desc(_STR, "Node3D to follow (scene path). Default: first node in group 'player'."),
					"parent_path": _desc(_STR, "Where to add the rig. Default: scene root."),
					"name": _desc(_STR, "Rig node name. Default TopdownCamera."),
					"pitch_degrees": _desc(_range(10, 89), "Look-down angle; 90 is straight down. Default 55."),
					"distance": _desc(_range(1, 200), "Arm length in meters. Default 14."),
					"yaw_degrees": _desc(_range(-180, 180), "Rig rotation around Y. Default 0."),
					"fov": _desc(_range(1, 179), "Camera3D field of view. Default 50."),
					"follow_smoothing": _desc(_range(0, 50), "Follow speed; 0 snaps. Default 8."),
					"aim_lookahead": _desc(_range(0, 1), "Fraction of target-to-cursor offset to lean. Default 0.25."),
					"max_lookahead": _desc(_range(0, 50), "Max lean in meters. Default 4."),
					"lookahead_smoothing": _desc(_range(0, 50), "Lean speed; 0 snaps. Default 6."),
					"make_current": _desc(_BOOL, "Make this the current camera (unsets others). Default true."),
					"script_dir": _desc(_STR, "res:// folder for the rig script. Default res://scripts/topdown."),
					"overwrite_scripts": _desc(_BOOL, "Replace an existing rig script with the template. Default false."),
				},
			},
		},
		{
			"name": "player_controller_scaffold",
			"method": &"player_scaffold",
			"description": "Create a top-down player scene (CharacterBody3D, capsule, Aim pivot, WeaponMount) with a controller script: camera-relative WASD movement, mouse aim on a ground plane, dodge roll with i-frames, health/take_damage, and fire/reload driving a mounted weapon. Adds missing input actions (WASD/arrows, Space, LMB, R) to project.godot and, by default, instances the player into the open scene.",
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"scene_path": _desc(_STR, "Player .tscn to write. Default res://scenes/player/player.tscn."),
					"script_dir": _desc(_STR, "res:// folder for player_controller.gd. Default res://scripts/topdown."),
					"move_speed": _desc(_range(0.1, 100), "m/s. Default 6."),
					"acceleration": _desc(_range(0.1, 1000), "Default 40."),
					"deceleration": _desc(_range(0.1, 1000), "Default 50."),
					"turn_speed": _desc(_range(0, 200), "Aim turn speed; 0 instant. Default 20."),
					"dodge_speed": _desc(_range(0.1, 200), "Default 14."),
					"dodge_duration": _desc(_range(0.01, 5), "Seconds. Default 0.25."),
					"dodge_cooldown": _desc(_range(0, 30), "Seconds. Default 0.6."),
					"max_health": _desc(_range(1, 100000), "Default 100."),
					"aim_height": _desc(_range(0, 10), "Aim plane / weapon height in meters. Default 1.2."),
					"create_input_actions": _desc(_BOOL, "Add missing input actions. Existing ones are kept. Default true."),
					"action_prefix": _desc(_STR, "Prefix for action names (e.g. p1_ -> p1_move_left). Default none."),
					"add_to_scene": _desc(_BOOL, "Instance the player into the open scene. Default true."),
					"parent_path": _desc(_STR, "Parent for the instance. Default scene root."),
					"position": _desc({"type": "array", "items": _NUM, "minItems": 3, "maxItems": 3}, "Instance position [x, y, z]. Default origin."),
					"overwrite": _desc(_BOOL, "Replace an existing player scene. Default false."),
					"overwrite_scripts": _desc(_BOOL, "Replace an existing controller script with the template. Default false."),
				},
			},
		},
		{
			"name": "weapon_create",
			"method": &"weapon_create",
			"description": "Create a weapon: a stats .tres (damage, fire rate, auto, magazine, reload, spread, pellets, range) and a weapon scene whose script fires hitscan rays or projectiles from a Muzzle toward the aim point and calls take_damage(amount, info) on what it hits. Optionally attaches it to a player (attach_to, uses Aim/WeaponMount when present). Shared scripts are copied once into script_dir.",
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"required": ["weapon_id"],
				"properties": {
					"weapon_id": _desc(_STR, "lower_snake_case id, also the file name (e.g. pistol, pump_shotgun)."),
					"display_name": _desc(_STR, "UI name. Default from weapon_id."),
					"fire_mode": _desc({"type": "string", "enum": ["hitscan", "projectile"]}, "Default hitscan."),
					"damage": _desc(_range(0, 100000), "Per pellet. Default 20."),
					"fire_rate": _desc(_range(0.01, 100), "Shots per second. Default 5."),
					"automatic": _desc(_BOOL, "Hold to fire. Default false."),
					"magazine_size": _desc({"type": "integer", "minimum": 1, "maximum": 10000}, "Default 12."),
					"reload_time": _desc(_range(0, 60), "Seconds. Default 1.5."),
					"auto_reload": _desc(_BOOL, "Reload when firing empty. Default true."),
					"spread_degrees": _desc(_range(0, 180), "Total cone angle. Default 3."),
					"pellets": _desc({"type": "integer", "minimum": 1, "maximum": 64}, "Rays/projectiles per shot. Default 1."),
					"max_range": _desc(_range(0.1, 10000), "Meters. Default 50."),
					"projectile_speed": _desc(_range(0.1, 10000), "m/s, projectile mode. Default 40."),
					"collision_mask": _desc({"type": "integer", "minimum": 1}, "Physics layers bullets hit. Default 1."),
					"attach_to": _desc(_STR, "Node in the open scene to attach an instance to (a player, or a mount)."),
					"data_dir": _desc(_STR, "Default res://data/weapons."),
					"scene_dir": _desc(_STR, "Default res://scenes/weapons."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown."),
					"overwrite": _desc(_BOOL, "Replace existing files for this weapon_id. Default false."),
					"overwrite_scripts": _desc(_BOOL, "Replace existing weapon scripts with the templates. Default false."),
				},
			},
		},
		{
			"name": "enemy_ai_scaffold",
			"method": &"enemy_scaffold",
			"description": "Create an enemy scene (CharacterBody3D, NavigationAgent3D, WeaponMount) with a state-machine AI: PATROL (route or wander) -> CHASE (seen in a vision cone with line of sight, damaged, or alerted by an ally) -> ATTACK (melee, or ranged with its own ray or a weapon_create weapon) -> SEARCH (last known position) -> PATROL. Uses take_damage(amount, info) like the player and weapons. Places instances in the open scene and, if it has no NavigationRegion3D, adds one baked from static colliders. One undo step.",
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"required": ["enemy_id"],
				"properties": {
					"enemy_id": _desc(_STR, "lower_snake_case id, also the scene file name (e.g. grunt, rifleman)."),
					"attack_mode": _desc({"type": "string", "enum": ["melee", "ranged"]}, "Default melee."),
					"weapon_scene": _desc(_STR, "Ranged only: res:// weapon .tscn (from weapon_create) mounted on the enemy. Without it the enemy fires its own ray."),
					"max_health": _desc(_range(1, 100000), "Default 60."),
					"patrol_speed": _desc(_range(0, 100), "m/s. Default 2.5."),
					"chase_speed": _desc(_range(0.1, 100), "m/s. Default 4.5."),
					"sight_range": _desc(_range(0.5, 1000), "Meters. Default 15."),
					"sight_angle_degrees": _desc(_range(1, 360), "Full vision cone width. Default 110."),
					"proximity_radius": _desc(_range(0, 100), "Noticed in any direction this close. Default 2.5."),
					"attack_range": _desc(_range(0.3, 1000), "Default 1.8 melee, 12 ranged."),
					"attack_damage": _desc(_range(0, 100000), "Per hit (weapon-less). Default 10."),
					"attack_cooldown": _desc(_range(0, 60), "Seconds between attacks. Default 1 melee, 0.8 ranged."),
					"attack_windup": _desc(_range(0, 10), "Telegraph / reaction time before attacking. Default 0.35."),
					"lose_sight_time": _desc(_range(0, 60), "Seconds chasing the last seen spot before searching. Default 3."),
					"search_time": _desc(_range(0, 60), "Seconds looking around before patrolling again. Default 4."),
					"alert_radius": _desc(_range(0, 1000), "Nearby enemies within this radius join the chase; 0 off. Default 8."),
					"wander_radius": _desc(_range(0, 1000), "Wander range around the spawn point when there are no patrol_points. Default 6."),
					"target_group": _desc(_STR, "Group of nodes the enemy hunts. Default player."),
					"add_to_scene": _desc(_BOOL, "Place instances in the open scene. Default true."),
					"parent_path": _desc(_STR, "Parent for the instances. Default scene root."),
					"positions": _desc({"type": "array", "items": _VEC3, "minItems": 1, "maxItems": 64}, "One instance per [x, y, z]. Default [[0, 0, -8]]."),
					"patrol_points": _desc({"type": "array", "items": _VEC3, "maxItems": 256}, "World [x, y, z] route, looped, set on every placed instance. Default none (wander)."),
					"setup_navigation": _desc(_BOOL, "Add and bake a NavigationRegion3D from static colliders when the scene has none. Default true."),
					"scene_dir": _desc(_STR, "Default res://scenes/enemies."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown."),
					"overwrite": _desc(_BOOL, "Replace an existing scene for this enemy_id. Default false."),
					"overwrite_scripts": _desc(_BOOL, "Replace an existing enemy_ai.gd with the template. Default false."),
				},
			},
		},
		{
			"name": "item_db_import",
			"method": &"item_db_import",
			"script": ITEM_HANDLER_PATH,
			"description": "Import an item spreadsheet (CSV/TSV, header row first) into one item .tres per row plus an item_database.tres index. Columns match item_data.gd @export properties by name, alias (id, name, price, 이름, 무게...) or column_map, and cells convert to each type (numbers, enums, ;-separated tags, res:// paths, weapon ids). Unmatched columns go to extra. All rows are validated first; one bad cell writes nothing. Re-import updates items in place. One undo step; dry_run previews.",
			"timeout_ms": 60000,
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"csv_path": _desc(_STR, "res:// or user:// .csv/.tsv file (UTF-8). Give this or csv_text."),
					"csv_text": _desc(_STR, "The sheet itself, header row first. Give this or csv_path."),
					"delimiter": _desc({"type": "string", "enum": ["auto", ",", ";", "|", "tab"]}, "Default auto (.tsv -> tab, else the most common of , tab ; | in the header)."),
					"column_map": _desc({"type": "object", "additionalProperties": {"type": "string"}}, "{\"CSV header\": \"property\"} for headers that do not match; \"-\" ignores a column. Headers starting with # or _ are always ignored."),
					"existing": _desc({"type": "string", "enum": ["update", "replace", "skip", "error"]}, "When an item .tres exists: update it in place (blank cells keep their value), replace it with a fresh item, skip it, or fail. Default update."),
					"data_dir": _desc(_STR, "Default res://data/items. Files are <data_dir>/<item_id>.tres."),
					"update_database": _desc(_BOOL, "Write/merge the item database .tres. Default true."),
					"database_path": _desc(_STR, "Default <data_dir>/item_database.tres."),
					"weapon_data_dir": _desc(_STR, "Where a bare weapon id in a 'weapon' column is looked up. Default res://data/weapons."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown (item_data.gd, item_database.gd)."),
					"overwrite_scripts": _desc(_BOOL, "Replace item_data.gd / item_database.gd with the templates. Default false."),
					"dry_run": _desc(_BOOL, "Validate and report what would happen without writing anything. Default false."),
				},
			},
		},
	]


static func build() -> Array[McpCustomToolSpec]:
	var out: Array[McpCustomToolSpec] = []
	for def in definitions():
		var spec := McpCustomToolSpec.new()
		spec.name = def.name
		spec.description = def.description
		spec.params_schema = def.schema
		spec.script_path = def.get("script", HANDLER_PATH)
		spec.method = def.method
		spec.source_path = SOURCE_PATH
		spec.source = "Top-down Shooter Tools"
		spec.promoted = true
		spec.requires_writable = true
		spec.timeout_ms = def.get("timeout_ms", 15000)
		out.append(spec)
	return out


static func _range(min_value: float, max_value: float) -> Dictionary:
	return {"type": "number", "minimum": min_value, "maximum": max_value}


static func _desc(schema: Dictionary, text: String) -> Dictionary:
	var out := schema.duplicate()
	out["description"] = text
	return out
