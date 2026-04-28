@tool
extends RefCounted

## Curated material preset blueprints.
##
## Each preset returns {type, params}. Handler applies them through the
## normal material build path so they get undo + validation for free.


const _PRESETS := {
	"metal": {
		"type": "orm",
		"params": {
			"metallic": 1.0,
			"roughness": 0.25,
			"albedo_color": {"r": 0.85, "g": 0.85, "b": 0.88, "a": 1.0},
		},
	},
	"glass": {
		"type": "standard",
		"params": {
			"transparency": "alpha",
			"albedo_color": {"r": 0.9, "g": 0.95, "b": 1.0, "a": 0.3},
			"metallic": 0.0,
			"metallic_specular": 0.5,
			"roughness": 0.05,
			"refraction_enabled": true,
			"refraction_scale": 0.05,
		},
	},
	"emissive": {
		"type": "standard",
		"params": {
			"emission_enabled": true,
			"emission_energy_multiplier": 3.0,
			"emission": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
			"albedo_color": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
		},
	},
	"unlit": {
		"type": "standard",
		"params": {
			"shading_mode": "unshaded",
			"albedo_color": {"r": 1.0, "g": 1.0, "b": 1.0, "a": 1.0},
		},
	},
	"matte": {
		"type": "standard",
		"params": {
			"roughness": 1.0,
			"metallic": 0.0,
			"albedo_color": {"r": 0.7, "g": 0.7, "b": 0.7, "a": 1.0},
		},
	},
	"ceramic": {
		"type": "standard",
		"params": {
			"roughness": 0.4,
			"metallic": 0.0,
			"clearcoat_enabled": true,
			"clearcoat": 0.7,
			"clearcoat_roughness": 0.15,
			"albedo_color": {"r": 0.95, "g": 0.95, "b": 0.95, "a": 1.0},
		},
	},
}


static func list() -> Array:
	return _PRESETS.keys()


static func has(preset_name: String) -> bool:
	return _PRESETS.has(preset_name)


## Returns a deep-copied {type, params} blueprint for the named preset, or
## null if the preset is unknown. Overrides are merged into params.
static func build(preset_name: String, overrides: Dictionary) -> Variant:
	if not _PRESETS.has(preset_name):
		return null
	var entry: Dictionary = _PRESETS[preset_name].duplicate(true)
	var params: Dictionary = entry.get("params", {})
	# Allow overrides to change type, too.
	if overrides.has("type"):
		entry["type"] = overrides["type"]
	for key in overrides:
		if key == "type":
			continue
		params[key] = overrides[key]
	entry["params"] = params
	return entry
