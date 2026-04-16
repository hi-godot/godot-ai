@tool
class_name ParticlePresets
extends RefCounted

## Curated particle effect blueprints.
##
## Each preset returns {main, process, draw}. The handler applies them
## through the normal write path (one undo action wraps all spawns).


const _PRESETS := {
	"fire": {
		"main": {
			"amount": 80,
			"lifetime": 1.2,
			"one_shot": false,
			"explosiveness": 0.0,
			"preprocess": 0.5,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "sphere",
			"emission_sphere_radius": 0.3,
			"direction": {"x": 0.0, "y": 1.0, "z": 0.0},
			"spread": 15.0,
			"initial_velocity_min": 2.0,
			"initial_velocity_max": 4.0,
			"gravity": {"x": 0.0, "y": 1.0, "z": 0.0},  # buoyancy
			"scale_min": 0.4,
			"scale_max": 0.8,
			"color_ramp": {
				"stops": [
					{"time": 0.0, "color": [1.0, 1.0, 0.9, 1.0]},
					{"time": 0.3, "color": [1.0, 0.6, 0.1, 1.0]},
					{"time": 0.7, "color": [0.8, 0.1, 0.05, 0.7]},
					{"time": 1.0, "color": [0.2, 0.05, 0.05, 0.0]},
				]
			},
		},
	},
	"smoke": {
		"main": {
			"amount": 40,
			"lifetime": 3.0,
			"one_shot": false,
			"explosiveness": 0.0,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "sphere",
			"emission_sphere_radius": 0.4,
			"direction": {"x": 0.0, "y": 1.0, "z": 0.0},
			"spread": 20.0,
			"initial_velocity_min": 0.5,
			"initial_velocity_max": 1.5,
			"gravity": {"x": 0.0, "y": 0.2, "z": 0.0},
			"scale_min": 0.6,
			"scale_max": 1.4,
			"color_ramp": {
				"stops": [
					{"time": 0.0, "color": [0.3, 0.3, 0.3, 0.0]},
					{"time": 0.25, "color": [0.35, 0.35, 0.35, 0.7]},
					{"time": 0.75, "color": [0.2, 0.2, 0.2, 0.5]},
					{"time": 1.0, "color": [0.1, 0.1, 0.1, 0.0]},
				]
			},
		},
	},
	"spark_burst": {
		"main": {
			"amount": 60,
			"lifetime": 0.8,
			"one_shot": true,
			"explosiveness": 1.0,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "point",
			"direction": {"x": 0.0, "y": 1.0, "z": 0.0},
			"spread": 180.0,
			"initial_velocity_min": 5.0,
			"initial_velocity_max": 12.0,
			"gravity": {"x": 0.0, "y": -9.8, "z": 0.0},
			"scale_min": 0.05,
			"scale_max": 0.12,
			"color": {"r": 1.0, "g": 0.9, "b": 0.2, "a": 1.0},
		},
	},
	"magic_swirl": {
		"main": {
			"amount": 120,
			"lifetime": 2.0,
			"one_shot": false,
			"explosiveness": 0.0,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "ring",
			"emission_ring_radius": 0.8,
			"emission_ring_inner_radius": 0.6,
			"emission_ring_height": 0.0,
			"direction": {"x": 0.0, "y": 1.0, "z": 0.0},
			"spread": 30.0,
			"initial_velocity_min": 1.0,
			"initial_velocity_max": 2.0,
			"gravity": {"x": 0.0, "y": 0.0, "z": 0.0},
			"angular_velocity_min": 90.0,
			"angular_velocity_max": 180.0,
			"scale_min": 0.1,
			"scale_max": 0.2,
			"color_ramp": {
				"stops": [
					{"time": 0.0, "color": [0.4, 0.9, 1.0, 0.0]},
					{"time": 0.3, "color": [0.5, 0.7, 1.0, 1.0]},
					{"time": 0.7, "color": [1.0, 0.4, 0.9, 1.0]},
					{"time": 1.0, "color": [0.8, 0.2, 0.7, 0.0]},
				]
			},
		},
	},
	"rain": {
		"main": {
			"amount": 500,
			"lifetime": 1.5,
			"one_shot": false,
			"explosiveness": 0.0,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "box",
			"emission_box_extents": {"x": 10.0, "y": 0.1, "z": 10.0},
			"direction": {"x": 0.0, "y": -1.0, "z": 0.0},
			"spread": 2.0,
			"initial_velocity_min": 15.0,
			"initial_velocity_max": 18.0,
			"gravity": {"x": 0.0, "y": -2.0, "z": 0.0},
			"scale_min": 0.02,
			"scale_max": 0.04,
			"color": {"r": 0.7, "g": 0.85, "b": 1.0, "a": 0.5},
		},
	},
	"explosion": {
		"main": {
			"amount": 200,
			"lifetime": 1.5,
			"one_shot": true,
			"explosiveness": 1.0,
			"local_coords": false,
		},
		"process": {
			"emission_shape": "sphere",
			"emission_sphere_radius": 0.1,
			"direction": {"x": 0.0, "y": 1.0, "z": 0.0},
			"spread": 180.0,
			"initial_velocity_min": 6.0,
			"initial_velocity_max": 10.0,
			"gravity": {"x": 0.0, "y": -4.0, "z": 0.0},
			"scale_min": 0.3,
			"scale_max": 0.7,
			"color_ramp": {
				"stops": [
					{"time": 0.0, "color": [1.0, 0.95, 0.5, 1.0]},
					{"time": 0.2, "color": [1.0, 0.4, 0.1, 1.0]},
					{"time": 0.7, "color": [0.3, 0.15, 0.1, 0.7]},
					{"time": 1.0, "color": [0.1, 0.1, 0.1, 0.0]},
				]
			},
		},
	},
}


static func list() -> Array:
	return _PRESETS.keys()


static func has(preset_name: String) -> bool:
	return _PRESETS.has(preset_name)


## Return deep-copied {main, process} blueprint with overrides merged in.
## Overrides may include top-level "main", "process", or bare keys that
## are routed to main/process based on which group they belong to.
static func build(preset_name: String, overrides: Dictionary) -> Variant:
	if not _PRESETS.has(preset_name):
		return null
	var entry: Dictionary = _PRESETS[preset_name].duplicate(true)
	var main: Dictionary = entry.get("main", {})
	var process: Dictionary = entry.get("process", {})
	for key in overrides:
		var val = overrides[key]
		if key == "main" and val is Dictionary:
			for k in val:
				main[k] = val[k]
		elif key == "process" and val is Dictionary:
			for k in val:
				process[k] = val[k]
		elif _MAIN_KEYS.has(key):
			main[key] = val
		else:
			process[key] = val
	entry["main"] = main
	entry["process"] = process
	return entry


const _MAIN_KEYS := {
	"amount": true,
	"lifetime": true,
	"one_shot": true,
	"explosiveness": true,
	"preprocess": true,
	"speed_scale": true,
	"randomness": true,
	"fixed_fps": true,
	"emitting": true,
	"local_coords": true,
	"interp_to_end": true,
}
