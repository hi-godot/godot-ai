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
const VECTOR3I_KEYS: Array[String] = ["x", "y", "z"]
const QUATERNION_KEYS: Array[String] = ["x", "y", "z", "w"]
const BASIS_KEYS: Array[String] = ["x", "y", "z"]
const RECT2_KEYS: Array[String] = ["position", "size"]
const AABB_KEYS: Array[String] = ["position", "size"]


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


## Parse a scalar float from the wire shapes agents send: float passthrough,
## int (JSON integers land as numbers, not strings), and strictly-numeric
## strings — some MCP clients stringify float arguments ("4.0"; #964).
## Anything else returns null so callers turn it into their own typed
## error; null input stays null (callers gate on the input's type first
## when null is a meaningful "clear" value).
static func parse_float(value: Variant) -> Variant:
	if _is_number(value):
		return float(value)
	if value is String:
		var text := value as String
		if text.is_valid_float():
			return text.to_float()
	return null


static func parse_vector3i(value: Variant) -> Variant:
	if value is Vector3i:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(VECTOR3I_KEYS):
			return null
		if not (_is_number(d.x) and _is_number(d.y) and _is_number(d.z)):
			return null
		return Vector3i(int(d.x), int(d.y), int(d.z))
	if value is Array:
		var arr: Array = value
		if arr.size() != 3:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	return null


static func parse_quaternion(value: Variant) -> Variant:
	if value is Quaternion:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(QUATERNION_KEYS):
			return null
		if not (_is_number(d.x) and _is_number(d.y) and _is_number(d.z) and _is_number(d.w)):
			return null
		return Quaternion(float(d.x), float(d.y), float(d.z), float(d.w))
	if value is Array:
		var arr: Array = value
		if arr.size() != 4:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		return Quaternion(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
	return null


## Basis: accepts the canonical serializer shape ({x:{x,y,z}, y:{…}, z:{…}})
## and a 3-element array of axis vectors. Each axis goes through
## `parse_vector3`, so the component strictness is shared.
static func parse_basis(value: Variant) -> Variant:
	if value is Basis:
		return value
	var rows: Array = []
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(BASIS_KEYS):
			return null
		rows = [d.x, d.y, d.z]
	elif value is Array:
		var arr: Array = value
		if arr.size() != 3:
			return null
		rows = arr
	else:
		return null
	var axes: Array = []
	for row in rows:
		var axis: Variant = parse_vector3(row)
		if axis == null:
			return null
		axes.append(axis)
	return Basis(axes[0], axes[1], axes[2])


## Transform3D: accepts the canonical serializer shape
## ({basis:{x,y,z}, origin:{x,y,z}}) and the ergonomic
## ({position, rotation_degrees?, scale?}) shape — rotation defaults to zero
## and scale to one so a bare position is a valid translation.
static func parse_transform3d(value: Variant) -> Variant:
	if value is Transform3D:
		return value
	if not value is Dictionary:
		return null
	var d: Dictionary = value
	if d.has("basis") or d.has("origin"):
		if not (d.has("basis") and d.has("origin")):
			return null
		var basis: Variant = parse_basis(d.basis)
		var origin: Variant = parse_vector3(d.origin)
		if basis == null or origin == null:
			return null
		return Transform3D(basis, origin)
	if d.has("position"):
		var pos: Variant = parse_vector3(d.position)
		if pos == null:
			return null
		var rot_basis := Basis.IDENTITY
		if d.has("rotation_degrees"):
			var rot_deg: Variant = parse_vector3(d.rotation_degrees)
			if rot_deg == null:
				return null
			rot_basis = Basis.from_euler((rot_deg as Vector3) * (PI / 180.0))
		elif d.has("rotation"):
			var rot: Variant = parse_vector3(d.rotation)
			if rot == null:
				return null
			rot_basis = Basis.from_euler(rot)
		if d.has("scale"):
			var scale: Variant = parse_vector3(d.scale)
			if scale == null:
				return null
			## Local axes: the ergonomic shape describes a node transform, and
			## `scaled()` would apply the scale in global axes (skewing the
			## rotation for a non-uniform scale).
			rot_basis = rot_basis.scaled_local(scale)
		return Transform3D(rot_basis, pos)
	return null


static func parse_rect2(value: Variant) -> Variant:
	if value is Rect2:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(RECT2_KEYS):
			return null
		var pos: Variant = parse_vector2(d.position)
		var size: Variant = parse_vector2(d.size)
		if pos == null or size == null:
			return null
		return Rect2(pos, size)
	if value is Array:
		var arr: Array = value
		if arr.size() != 4:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		return Rect2(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
	return null


static func parse_aabb(value: Variant) -> Variant:
	if value is AABB:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not d.has_all(AABB_KEYS):
			return null
		var pos: Variant = parse_vector3(d.position)
		var size: Variant = parse_vector3(d.size)
		if pos == null or size == null:
			return null
		return AABB(pos, size)
	if value is Array:
		var arr: Array = value
		if arr.size() != 6:
			return null
		for item in arr:
			if not _is_number(item):
				return null
		return AABB(
			Vector3(float(arr[0]), float(arr[1]), float(arr[2])),
			Vector3(float(arr[3]), float(arr[4]), float(arr[5])),
		)
	return null


static func parse_node_path(value: Variant) -> Variant:
	if value is NodePath:
		return value
	if value is String:
		return NodePath(value)
	return null


static func parse_string_name(value: Variant) -> Variant:
	if value is StringName:
		return value
	if value is String:
		return StringName(value)
	return null


static func _is_number(v: Variant) -> bool:
	return v is int or v is float
