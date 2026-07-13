@tool
class_name McpJsonValues
extends RefCounted

## Canonical JSON→Variant parsers for the wire shapes agents send.
##
## One parser family instead of five drifted per-handler copies (#714) —
## the canonical color set is the maintainer decision recorded on that
## issue. parse_color accepts: Color passthrough; "#rrggbb"/"#rrggbbaa"
## hex or named-color strings (two-sentinel Color.from_string
## validation); {r,g,b[,a]} dicts; [r,g,b[,a]] arrays. parse_vector2/3
## accept the Vector passthrough, {x,y[,z]} dicts, and [x,y[,z]] arrays.
##
## Strict WITHIN each shape (the #123/#126 contract): wrong dict keys,
## wrong array lengths, or non-numeric components return null instead of
## guessing zeros — callers turn null into their own typed error.

const COLOR_KEYS: Array[String] = ["r", "g", "b"]
const VECTOR2_KEYS: Array[String] = ["x", "y"]
const VECTOR3_KEYS: Array[String] = ["x", "y", "z"]


static func parse_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if value is String:
		## Color.from_string returns the fallback on parse failure — call
		## twice with distinct sentinels; agreement means a real parse.
		var a := Color.from_string(value, Color(0, 0, 0, 0))
		var b := Color.from_string(value, Color(1, 1, 1, 1))
		if a != b:
			return null
		return a
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(COLOR_KEYS):
			return null
		var alpha: Variant = d.get("a", 1.0)
		if not (_is_number(d.r) and _is_number(d.g) and _is_number(d.b) and _is_number(alpha)):
			return null
		return Color(float(d.r), float(d.g), float(d.b), float(alpha))
	if value is Array:
		var arr: Array = value
		if arr.size() != 3 and arr.size() != 4:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		var a4 := float(arr[3]) if arr.size() == 4 else 1.0
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), a4)
	return null


static func parse_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(VECTOR2_KEYS) or not (_is_number(d.x) and _is_number(d.y)):
			return null
		return Vector2(float(d.x), float(d.y))
	if value is Array:
		var arr: Array = value
		if arr.size() != 2 or not (_is_number(arr[0]) and _is_number(arr[1])):
			return null
		return Vector2(float(arr[0]), float(arr[1]))
	return null


static func parse_vector3(value: Variant) -> Variant:
	if value is Vector3:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(VECTOR3_KEYS):
			return null
		if not (_is_number(d.x) and _is_number(d.y) and _is_number(d.z)):
			return null
		return Vector3(float(d.x), float(d.y), float(d.z))
	if value is Array:
		var arr: Array = value
		if arr.size() != 3:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return null


static func _is_number(v: Variant) -> bool:
	return v is int or v is float
