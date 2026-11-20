@tool
extends RefCounted

## Descriptors for the top-down shooter MCP tools, built on Godot AI's
## published McpCustomToolSpec class (requires the godot_ai addon files).

const SOURCE_PATH := "res://addons/topdown_shooter_tools/plugin.cfg"
const HANDLER_PATH := "res://addons/topdown_shooter_tools/handlers/topdown_tools.gd"

const _NUM := {"type": "number"}
const _BOOL := {"type": "boolean"}
const _STR := {"type": "string"}


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
	]


static func build() -> Array[McpCustomToolSpec]:
	var out: Array[McpCustomToolSpec] = []
	for def in definitions():
		var spec := McpCustomToolSpec.new()
		spec.name = def.name
		spec.description = def.description
		spec.params_schema = def.schema
		spec.script_path = HANDLER_PATH
		spec.method = def.method
		spec.source_path = SOURCE_PATH
		spec.source = "Top-down Shooter Tools"
		spec.promoted = true
		spec.requires_writable = true
		spec.timeout_ms = 15000
		out.append(spec)
	return out


static func _range(min_value: float, max_value: float) -> Dictionary:
	return {"type": "number", "minimum": min_value, "maximum": max_value}


static func _desc(schema: Dictionary, text: String) -> Dictionary:
	var out := schema.duplicate()
	out["description"] = text
	return out
