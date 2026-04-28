@tool
extends RefCounted

## Opinionated Camera2D / Camera3D presets.
##
## build(preset_name, overrides) -> {default_type, properties} | null
## properties are merged with caller overrides (overrides win).


const _PRESETS := {
	# Top-down roguelite / arena — damped follow feel, drag deadzone.
	"topdown_2d": {
		"default_type": "2d",
		"properties": {
			"zoom": {"x": 2.0, "y": 2.0},
			"anchor_mode": "drag_center",
			"position_smoothing_enabled": true,
			"position_smoothing_speed": 5.0,
			"rotation_smoothing_enabled": false,
			"drag_horizontal_enabled": true,
			"drag_vertical_enabled": true,
			"drag_left_margin": 0.2,
			"drag_right_margin": 0.2,
			"drag_top_margin": 0.2,
			"drag_bottom_margin": 0.2,
		},
	},
	# Platformer — tight horizontal follow, vertical snap with smoothing on.
	"platformer_2d": {
		"default_type": "2d",
		"properties": {
			"zoom": {"x": 1.5, "y": 1.5},
			"anchor_mode": "drag_center",
			"position_smoothing_enabled": true,
			"position_smoothing_speed": 8.0,
			"drag_horizontal_enabled": true,
			"drag_vertical_enabled": false,
			"drag_left_margin": 0.15,
			"drag_right_margin": 0.15,
		},
	},
	# Cinematic 3D — narrow FOV, long range. Good for dramatic wide shots.
	"cinematic_3d": {
		"default_type": "3d",
		"properties": {
			"fov": 40.0,
			"near": 0.1,
			"far": 500.0,
			"projection": "perspective",
		},
	},
	# Action 3D — wider FOV for first/third-person action gameplay.
	"action_3d": {
		"default_type": "3d",
		"properties": {
			"fov": 70.0,
			"near": 0.1,
			"far": 200.0,
			"projection": "perspective",
		},
	},
}


static func list_presets() -> Array:
	return _PRESETS.keys()


## Build a preset blueprint. Returns null if preset_name is unknown.
## overrides is merged on top of preset defaults (caller values win).
static func build(preset_name: String, overrides: Dictionary) -> Variant:
	if not _PRESETS.has(preset_name):
		return null
	var preset: Dictionary = _PRESETS[preset_name]
	var properties: Dictionary = (preset.get("properties", {}) as Dictionary).duplicate(true)
	for key in overrides:
		properties[key] = overrides[key]
	return {
		"default_type": preset.get("default_type", "2d"),
		"properties": properties,
	}
