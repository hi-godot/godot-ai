@tool
extends RefCounted

## Descriptors for the top-down shooter MCP tools, built on Godot AI's
## published McpCustomToolSpec class (requires the godot_ai addon files).

const SOURCE_PATH := "res://addons/topdown_shooter_tools/plugin.cfg"
const HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/topdown_tools.gd"
const ITEM_HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/item_tools.gd"
const LOOT_HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/loot_tools.gd"
const INVENTORY_HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/inventory_tools.gd"
const RAID_HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/raid_tools.gd"

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
		{
			"name": "loot_table_edit",
			"method": &"loot_table_edit",
			"script": LOOT_HANDLER_PATH,
			"description": "Create or edit a drop table .tres for an enemy or crate (res://data/loot/<table_id>.tres): weighted entries with count ranges, guaranteed drops, rolls per drop and an empty weight. Item ids are checked against item_database.tres from item_db_import; category/tag entries add every matching item. Reports each item's exact drop chance, expected count and a seeded simulation with sample drops (only table_id: just simulate). attach_to / attach_to_group add a LootDropper child that drops pickups when the parent emits 'died'. Table and droppers are each one undo step; dry_run previews.",
			"timeout_ms": 30000,
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"required": ["table_id"],
				"properties": {
					"table_id": _desc(_STR, "lower_snake_case id, also the file name (e.g. grunt, medical_crate)."),
					"entries": _desc({"type": "array", "maxItems": 500, "items": {
						"type": "object",
						"additionalProperties": false,
						"properties": {
							"item_id": _desc(_STR, "Item id from the item database."),
							"category": _desc(_STR, "Instead of item_id: every item of this category, each with this weight."),
							"tag": _desc(_STR, "Instead of item_id: every item with this tag, each with this weight."),
							"weight": _desc(_range(0, 1e9), "Relative weight per roll. Default 1."),
							"min_count": _desc({"type": "integer", "minimum": 0}, "Default 1."),
							"max_count": _desc({"type": "integer", "minimum": 0}, "Default min_count."),
							"guaranteed": _desc(_BOOL, "Drops every time, outside the rolls. Default false."),
						},
					}}, "Entries to add, or to change when the item is already in the table (matched by item_id)."),
					"replace_entries": _desc(_BOOL, "Start from an empty entry list instead of editing the existing one. Default false."),
					"remove_items": _desc({"type": "array", "items": _STR}, "Item ids to take out of the table."),
					"rolls_min": _desc({"type": "integer", "minimum": 0, "maximum": 100}, "Rolls per drop, low end. Default 1 (new table)."),
					"rolls_max": _desc({"type": "integer", "minimum": 0, "maximum": 100}, "Rolls per drop, high end. Default 1 (new table)."),
					"empty_weight": _desc(_range(0, 1e9), "Weight of 'nothing' on each roll. Default 0 (new table)."),
					"database_path": _desc(_STR, "Item database. Default res://data/items/item_database.tres."),
					"allow_unknown_items": _desc(_BOOL, "Accept ids not in the database (or no database). Default false."),
					"simulate": _desc({"type": "integer", "minimum": 0, "maximum": 100000}, "Drops to simulate for the report; 0 skips. Default 1000."),
					"samples": _desc({"type": "integer", "minimum": 0, "maximum": 20}, "Sample drops listed in the report. Default 5."),
					"seed": _desc({"type": "integer", "minimum": 0}, "Simulation seed for repeatable results. Default random (reported)."),
					"attach_to": _desc({"type": "array", "items": _STR}, "Scene paths of enemies/crates in the open scene to give a LootDropper (updated if they have one)."),
					"attach_to_group": _desc(_STR, "Also attach to every 3D node in this group in the open scene (e.g. enemy)."),
					"trigger_signal": _desc(_STR, "Parent signal that drops the loot. Default died; empty means only drop() calls."),
					"dropper_name": _desc(_STR, "Dropper node name. Default LootDropper."),
					"data_dir": _desc(_STR, "Default res://data/loot."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown (loot_table.gd, loot_dropper.gd, loot_pickup.gd)."),
					"overwrite_scripts": _desc(_BOOL, "Replace the loot scripts with the templates. Default false."),
					"dry_run": _desc(_BOOL, "Validate and report odds without writing anything. Default false."),
				},
			},
		},
		{
			"name": "inventory_ui_scaffold",
			"method": &"inventory_ui_scaffold",
			"script": INVENTORY_HANDLER_PATH,
			"description": "Give the player a grid + weight inventory (Inventory child: items cover grid_width x grid_height cells, stack to max_stack, all-or-nothing add_item, max_weight cap, slower above encumbered_weight) and an inventory screen (CanvasLayer: Tab/I toggles, drag moves, R rotates, right click drops, Shift+click splits, sort, tooltips, pickup toasts, weight HUD). Adds the toggle action and, if the player script lacks add_item, appends one so loot pickups fill the bag. Rerun updates settings. Nodes are one undo step, the script change another.",
			"timeout_ms": 30000,
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"player_path": _desc(_STR, "Player in the open scene. Default: first node in group 'player'."),
					"grid_width": _desc({"type": "integer", "minimum": 1, "maximum": 64}, "Columns. Default 6."),
					"grid_height": _desc({"type": "integer", "minimum": 1, "maximum": 64}, "Rows. Default 8."),
					"max_weight": _desc(_range(0, 100000), "Kilograms the bag holds; 0 = no limit. Default 40."),
					"encumbered_weight": _desc(_range(0, 100000), "Above this the player slows down; 0 = never. Default 25."),
					"min_speed_factor": _desc(_range(0.05, 1), "Speed multiplier at max_weight. Default 0.5."),
					"allow_rotation": _desc(_BOOL, "Items may turn 90 degrees to fit. Default true."),
					"starting_items": _desc({"type": "array", "maxItems": 200, "items": {
						"type": "object",
						"additionalProperties": false,
						"required": ["item_id"],
						"properties": {
							"item_id": _desc(_STR, "Item id from the item database."),
							"count": _desc({"type": "integer", "minimum": 1}, "Default 1."),
						},
					}}, "Items in the bag when the game starts (replaces the list)."),
					"database_path": _desc(_STR, "Item database. Default res://data/items/item_database.tres."),
					"toggle_action": _desc(_STR, "Input action that opens the screen. Default inventory (created with Tab and I)."),
					"create_input_action": _desc(_BOOL, "Add the toggle action to project.godot when missing. Default true."),
					"title": _desc(_STR, "Screen title. Default 인벤토리."),
					"cell_size": _desc({"type": "integer", "minimum": 24, "maximum": 128}, "Grid cell size in pixels. Default 56."),
					"block_player_while_open": _desc(_BOOL, "Player stops moving and shooting while the screen is open. Default true."),
					"show_hud": _desc(_BOOL, "Bag weight line at the bottom left while closed. Default true."),
					"patch_player_script": _desc(_BOOL, "Append add_item(item, count) to the player script when it has none. Default true."),
					"inventory_name": _desc(_STR, "Inventory node name under the player. Default Inventory."),
					"ui_name": _desc(_STR, "UI node name under the scene root. Default InventoryUI."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown (inventory.gd, inventory_ui.gd)."),
					"overwrite_scripts": _desc(_BOOL, "Replace inventory.gd / inventory_ui.gd with the templates. Default false."),
					"dry_run": _desc(_BOOL, "Validate and report without changing anything. Default false."),
				},
			},
		},
		{
			"name": "raid_map_blockout",
			"method": &"raid_map_blockout",
			"script": RAID_HANDLER_PATH,
			"description": "Block out a raid map in the open 3D scene: rooms and corridors on a 1 m grid (generated from room_count + seed, or explicit rooms + connections) built as floor, wall and cover boxes (StaticBody3D: bullets, enemy sight and the nav bake see them). Places a PlayerSpawn (moves the player), enemy spawn markers (or enemy_scenes instances patrolling their room), loot crates (E to search; crate_loot_table drops loot) and extraction zones. Bakes navigation and returns an ASCII preview. One undo step; dry_run previews.",
			"timeout_ms": 60000,
			"schema": {
				"type": "object",
				"additionalProperties": false,
				"properties": {
					"room_count": _desc({"type": "integer", "minimum": 1, "maximum": 64}, "Generated rooms (ignored with rooms). Default 6."),
					"seed": _desc({"type": "integer", "minimum": 0}, "Layout seed; the same seed gives the same map. Default random (reported)."),
					"room_size_min": _desc({"type": "integer", "minimum": 4, "maximum": 100}, "Generated room side, meters. Default 8."),
					"room_size_max": _desc({"type": "integer", "minimum": 4, "maximum": 100}, "Default 14."),
					"room_gap": _desc({"type": "integer", "minimum": 1, "maximum": 100}, "Space between generated rooms (corridor length), meters. Default 6."),
					"rooms": _desc({"type": "array", "minItems": 1, "maxItems": 64, "items": {
						"type": "object",
						"additionalProperties": false,
						"required": ["position", "size"],
						"properties": {
							"name": _desc(_STR, "Node name. Default Room<n>."),
							"position": _desc({"type": "array", "items": _NUM, "minItems": 2, "maxItems": 3}, "Room center [x, z] (or [x, y, z]) relative to origin."),
							"size": _desc({"type": "array", "items": _NUM, "minItems": 2, "maxItems": 2}, "[width (x), depth (z)] in meters, 4 to 200."),
							"cover": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Cover blocks here (overrides cover_per_room)."),
							"crates": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Crates here."),
							"enemies": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Enemy spawns here."),
						},
					}}, "Explicit rooms instead of generating them."),
					"connections": _desc({"type": "array", "items": {"type": "array", "minItems": 2, "maxItems": 2}}, "With rooms: corridors as [room, room] (names or indices). Default: shortest spanning tree plus extra_connections."),
					"extra_connections": _desc({"type": "integer", "minimum": 0, "maximum": 64}, "Corridors added beyond a spanning tree, for loops. Default 1."),
					"corridor_width": _desc({"type": "integer", "minimum": 2, "maximum": 12}, "Meters. Default 3."),
					"wall_height": _desc(_range(0.5, 20), "Default 3."),
					"wall_thickness": _desc(_range(0.1, 1), "Default 0.4."),
					"build_floor": _desc(_BOOL, "Floor boxes (top at y=0) under rooms and corridors. Default true."),
					"floor_thickness": _desc(_range(0.05, 5), "Default 0.5."),
					"cover_per_room": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Low walls, boxes and pillars per room, kept 1.5 m from walls so doorways stay open. Default 3."),
					"crates_per_room": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Loot crates per room (none in the spawn room). Default 1."),
					"crate_loot_table": _desc(_STR, "Loot table id under res://data/loot (or a res:// .tres) from loot_table_edit; crates drop from it when opened."),
					"crate_search_time": _desc(_range(0, 30), "Seconds holding still near a crate after pressing interact. Default 1."),
					"interact_action": _desc(_STR, "Input action that searches crates; created with E when missing. Default interact."),
					"create_input_action": _desc(_BOOL, "Add interact_action to project.godot when missing. Default true."),
					"enemies_per_room": _desc({"type": "integer", "minimum": 0, "maximum": 32}, "Enemy spawn markers per room (none in the spawn room). Default 1."),
					"enemy_scenes": _desc({"type": "array", "items": _STR}, "res:// enemy .tscn files (enemy_ai_scaffold), used in turn: one instance per spawn marker."),
					"enemy_patrol": _desc(_BOOL, "Give placed enemies a loop through their room's corners. Default true."),
					"player_spawn_room": _desc({"type": ["string", "integer"]}, "Room name or index for the player spawn. Default the first room."),
					"move_player": _desc(_BOOL, "Move the scene's player (group player) to the spawn. Default true."),
					"extraction_count": _desc({"type": "integer", "minimum": 0, "maximum": 16}, "Extraction zones, in the rooms farthest from the spawn. Default 1."),
					"extraction_rooms": _desc({"type": "array", "items": {"type": ["string", "integer"]}}, "Rooms (names or indices) for extraction zones instead."),
					"extract_time": _desc(_range(0, 120), "Seconds inside a zone to extract. Default 5."),
					"extraction_radius": _desc(_range(0.5, 10), "Default 2."),
					"restart_delay": _desc(_range(0, 60), "Seconds after extracting before the scene reloads; 0 never. Default 4."),
					"setup_navigation": _desc(_BOOL, "Rebake the scene's NavigationRegion3D (or add one) to include the map. Default true."),
					"add_light": _desc(_BOOL, "Add a DirectionalLight3D when the scene has none. Default true."),
					"origin": _desc(_VEC3, "Map position [x, y, z]. Default [0, 0, 0]."),
					"parent_path": _desc(_STR, "Parent of the map node. Default scene root."),
					"name": _desc(_STR, "Map node name. Default RaidMap."),
					"replace": _desc(_BOOL, "Rebuild an existing map node of the same name (same undo step). Default false."),
					"script_dir": _desc(_STR, "Default res://scripts/topdown (loot_crate.gd, raid_extraction.gd, loot_dropper.gd, loot_pickup.gd)."),
					"overwrite_scripts": _desc(_BOOL, "Replace those scripts with the templates. Default false."),
					"dry_run": _desc(_BOOL, "Plan and preview the layout without changing anything. Default false."),
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
