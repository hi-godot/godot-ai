@tool
extends RefCounted

## Value coercion helpers for material authoring.
##
## Extends node_handler._coerce_value with material-specific cases:
##   - enum-by-name (transparency="alpha" → TRANSPARENCY_ALPHA)
##   - texture path → Texture2D
##   - {r,g,b,a} dict → Color (also handled by node coerce, but we want it inline)


const _ENUM_TABLES := {
	"transparency": {
		"disabled": BaseMaterial3D.TRANSPARENCY_DISABLED,
		"alpha": BaseMaterial3D.TRANSPARENCY_ALPHA,
		"alpha_scissor": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,
		"alpha_hash": BaseMaterial3D.TRANSPARENCY_ALPHA_HASH,
		"alpha_depth_pre_pass": BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS,
	},
	"shading_mode": {
		"unshaded": BaseMaterial3D.SHADING_MODE_UNSHADED,
		"per_pixel": BaseMaterial3D.SHADING_MODE_PER_PIXEL,
		"per_vertex": BaseMaterial3D.SHADING_MODE_PER_VERTEX,
	},
	"blend_mode": {
		"mix": BaseMaterial3D.BLEND_MODE_MIX,
		"add": BaseMaterial3D.BLEND_MODE_ADD,
		"sub": BaseMaterial3D.BLEND_MODE_SUB,
		"mul": BaseMaterial3D.BLEND_MODE_MUL,
	},
	"cull_mode": {
		"back": BaseMaterial3D.CULL_BACK,
		"front": BaseMaterial3D.CULL_FRONT,
		"disabled": BaseMaterial3D.CULL_DISABLED,
	},
	"depth_draw_mode": {
		"opaque_only": BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY,
		"always": BaseMaterial3D.DEPTH_DRAW_ALWAYS,
		"disabled": BaseMaterial3D.DEPTH_DRAW_DISABLED,
	},
	"diffuse_mode": {
		"burley": BaseMaterial3D.DIFFUSE_BURLEY,
		"lambert": BaseMaterial3D.DIFFUSE_LAMBERT,
		"lambert_wrap": BaseMaterial3D.DIFFUSE_LAMBERT_WRAP,
		"toon": BaseMaterial3D.DIFFUSE_TOON,
	},
	"specular_mode": {
		"schlick_ggx": BaseMaterial3D.SPECULAR_SCHLICK_GGX,
		"toon": BaseMaterial3D.SPECULAR_TOON,
		"disabled": BaseMaterial3D.SPECULAR_DISABLED,
	},
	"billboard_mode": {
		"disabled": BaseMaterial3D.BILLBOARD_DISABLED,
		"enabled": BaseMaterial3D.BILLBOARD_ENABLED,
		"fixed_y": BaseMaterial3D.BILLBOARD_FIXED_Y,
		"particles": BaseMaterial3D.BILLBOARD_PARTICLES,
	},
	"texture_filter": {
		"nearest": BaseMaterial3D.TEXTURE_FILTER_NEAREST,
		"linear": BaseMaterial3D.TEXTURE_FILTER_LINEAR,
		"nearest_mipmap": BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
		"linear_mipmap": BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
	},
}


## Return the enum int for (property, string_name), or null if not a known enum string.
static func resolve_enum(property: String, value: Variant) -> Variant:
	if not (value is String):
		return null
	if not _ENUM_TABLES.has(property):
		return null
	var table: Dictionary = _ENUM_TABLES[property]
	var key: String = String(value).to_lower()
	if table.has(key):
		return table[key]
	return null


## Parse a color from Color, "#rrggbb", "#rrggbbaa", named (red/blue/...) or dict.
## Returns null if the input cannot be parsed.
static func parse_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if value is String:
		var s: String = value
		var sentinel_a := Color(0, 0, 0, 0)
		var sentinel_b := Color(1, 1, 1, 1)
		var a := Color.from_string(s, sentinel_a)
		var b := Color.from_string(s, sentinel_b)
		if a != b:
			return null
		return a
	if value is Dictionary:
		var d: Dictionary = value
		if d.has("r") and d.has("g") and d.has("b"):
			return Color(float(d.r), float(d.g), float(d.b), float(d.get("a", 1.0)))
	if value is Array and value.size() >= 3:
		var arr: Array = value
		var alpha := float(arr[3]) if arr.size() >= 4 else 1.0
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	return null


static func parse_vector3(value: Variant) -> Variant:
	if value is Vector3:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		return Vector3(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return null


static func parse_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return null


## Parse a {stops: [{time, color}]} gradient dict into a Gradient resource.
static func parse_gradient(value: Variant) -> Variant:
	if value is Gradient:
		return value
	if not (value is Dictionary):
		return null
	var d: Dictionary = value
	if not d.has("stops"):
		return null
	var stops_array = d.get("stops")
	if not (stops_array is Array):
		return null
	var offsets: PackedFloat32Array = PackedFloat32Array()
	var colors: PackedColorArray = PackedColorArray()
	for stop in stops_array:
		if not (stop is Dictionary):
			return null
		var t := float(stop.get("time", 0.0))
		var c = parse_color(stop.get("color"))
		if c == null:
			return null
		offsets.append(t)
		colors.append(c)
	var grad := Gradient.new()
	grad.offsets = offsets
	grad.colors = colors
	return grad


## Load a Texture2D from a res:// path. Returns null on failure.
static func load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not ResourceLoader.exists(path):
		return null
	var res := ResourceLoader.load(path)
	if res is Texture2D:
		return res
	return null


## Coerce a JSON-shaped value for a material property.
## Returns a dict {ok: true, value: ...} on success, or {ok: false, error: "..."} on failure.
## For properties the coercer doesn't have special logic for, falls back to target_type.
static func coerce_material_value(property: String, value: Variant, target_type: int) -> Dictionary:
	# Enum-by-name: must match before generic TYPE_INT coercion.
	if _ENUM_TABLES.has(property):
		if value is String:
			var enum_val = resolve_enum(property, value)
			if enum_val == null:
				return {
					"ok": false,
					"error": "Invalid %s value: '%s'. Valid: %s" % [
						property, value, ", ".join(_ENUM_TABLES[property].keys())
					],
				}
			return {"ok": true, "value": int(enum_val)}
		if value is int or value is float:
			return {"ok": true, "value": int(value)}

	match target_type:
		TYPE_COLOR:
			var c = parse_color(value)
			if c == null:
				return {"ok": false, "error": "Invalid color for %s: %s" % [property, value]}
			return {"ok": true, "value": c}
		TYPE_VECTOR3:
			var v3 = parse_vector3(value)
			if v3 == null:
				return {"ok": false, "error": "Invalid vector3 for %s: %s" % [property, value]}
			return {"ok": true, "value": v3}
		TYPE_VECTOR2:
			var v2 = parse_vector2(value)
			if v2 == null:
				return {"ok": false, "error": "Invalid vector2 for %s: %s" % [property, value]}
			return {"ok": true, "value": v2}
		TYPE_BOOL:
			if value is bool:
				return {"ok": true, "value": value}
			if value is int or value is float:
				return {"ok": true, "value": bool(value)}
			return {"ok": false, "error": "Expected bool for %s" % property}
		TYPE_INT:
			if value is int:
				return {"ok": true, "value": value}
			if value is float:
				return {"ok": true, "value": int(value)}
			return {"ok": false, "error": "Expected int for %s" % property}
		TYPE_FLOAT:
			if value is float:
				return {"ok": true, "value": value}
			if value is int:
				return {"ok": true, "value": float(value)}
			return {"ok": false, "error": "Expected number for %s" % property}
		TYPE_OBJECT:
			if value == null:
				return {"ok": true, "value": null}
			if value is Object:
				return {"ok": true, "value": value}
			if value is String:
				var tex := load_texture(value)
				if tex == null:
					return {"ok": false, "error": "Resource not found or wrong type: %s" % value}
				return {"ok": true, "value": tex}
			return {"ok": false, "error": "Expected resource path (string) for %s" % property}
		TYPE_STRING:
			return {"ok": true, "value": String(value)}

	# Unknown target type — pass through.
	return {"ok": true, "value": value}


## Serialize a Variant into JSON-friendly shape for responses.
static func serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Resource:
		var path := (value as Resource).resource_path
		if path.is_empty():
			return {"type": value.get_class(), "path": ""}
		return {"type": value.get_class(), "path": path}
	return value
