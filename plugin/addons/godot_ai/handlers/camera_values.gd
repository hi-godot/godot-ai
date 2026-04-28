@tool
extends RefCounted

## Value coercion helpers for camera authoring.
##
## Handles:
##   - enum-by-name (keep_aspect="keep_height" -> Camera3D.KEEP_HEIGHT)
##   - {x, y} dict -> Vector2 (zoom, offset, drag_*_offset)
##   - serialization back to JSON-friendly shapes


const _ENUM_TABLES := {
	"projection": {
		"perspective": Camera3D.PROJECTION_PERSPECTIVE,
		"orthogonal": Camera3D.PROJECTION_ORTHOGONAL,
		"frustum": Camera3D.PROJECTION_FRUSTUM,
	},
	"keep_aspect": {
		"keep_width": Camera3D.KEEP_WIDTH,
		"keep_height": Camera3D.KEEP_HEIGHT,
	},
	"anchor_mode": {
		"fixed_top_left": Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT,
		"drag_center": Camera2D.ANCHOR_MODE_DRAG_CENTER,
	},
	"doppler_tracking": {
		"disabled": Camera3D.DOPPLER_TRACKING_DISABLED,
		"idle_step": Camera3D.DOPPLER_TRACKING_IDLE_STEP,
		"physics_step": Camera3D.DOPPLER_TRACKING_PHYSICS_STEP,
	},
	"process_callback": {
		"physics": Camera2D.CAMERA2D_PROCESS_PHYSICS,
		"idle": Camera2D.CAMERA2D_PROCESS_IDLE,
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


## Valid enum names for a property, for error messages.
static func enum_keys(property: String) -> Array:
	if not _ENUM_TABLES.has(property):
		return []
	return (_ENUM_TABLES[property] as Dictionary).keys()


static func parse_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is int or value is float:
		return Vector2(float(value), float(value))
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


## Coerce a JSON-shaped value for a camera property against the declared type.
## Returns {ok: true, value: ...} or {ok: false, error: "..."}.
static func coerce(property: String, value: Variant, target_type: int) -> Dictionary:
	# Enum-by-name: must match before generic TYPE_INT coercion.
	if _ENUM_TABLES.has(property):
		if value is String:
			var enum_val = resolve_enum(property, value)
			if enum_val == null:
				return {
					"ok": false,
					"error": "Invalid %s value: '%s'. Valid: %s" % [
						property, value, ", ".join(enum_keys(property))
					],
				}
			return {"ok": true, "value": int(enum_val)}
		if value is int or value is float:
			return {"ok": true, "value": int(value)}

	match target_type:
		TYPE_VECTOR2:
			var v2 = parse_vector2(value)
			if v2 == null:
				return {"ok": false, "error": "Invalid vector2 for %s: %s" % [property, value]}
			return {"ok": true, "value": v2}
		TYPE_VECTOR3:
			var v3 = parse_vector3(value)
			if v3 == null:
				return {"ok": false, "error": "Invalid vector3 for %s: %s" % [property, value]}
			return {"ok": true, "value": v3}
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
		TYPE_STRING:
			return {"ok": true, "value": String(value)}

	return {"ok": true, "value": value}


## Serialize a Variant into a JSON-friendly shape for responses.
static func serialize(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	return value
