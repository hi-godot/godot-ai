@tool
extends RefCounted

## Converts Godot Variants into values that can be encoded as JSON.


## Non-finite floats (NaN/INF) have no JSON representation: JSON.stringify
## emits them as the bare tokens `inf`/`nan`, which are invalid JSON — the
## server drops the whole frame and the pending request times out (#688).
## Serialize them as null instead (the same choice web JSON.stringify makes),
## applied uniformly across the supported 4.5+ floor — no version gate, so
## wire output is identical on every supported engine.
static func _safe_float(f: float) -> Variant:
	return f if is_finite(f) else null


static func serialize(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			return _safe_float(value)
		TYPE_STRING_NAME:
			return str(value)
		# Integer vector types are listed separately from their float twins so
		# int components stay ints on the wire (no float coercion via
		# _safe_float's typed parameter).
		TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR2:
			return {"x": _safe_float(value.x), "y": _safe_float(value.y)}
		TYPE_VECTOR3I:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR3:
			return {"x": _safe_float(value.x), "y": _safe_float(value.y), "z": _safe_float(value.z)}
		TYPE_VECTOR4I:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_VECTOR4, TYPE_QUATERNION:
			return {
				"x": _safe_float(value.x),
				"y": _safe_float(value.y),
				"z": _safe_float(value.z),
				"w": _safe_float(value.w),
			}
		TYPE_COLOR:
			return {
				"r": _safe_float(value.r),
				"g": _safe_float(value.g),
				"b": _safe_float(value.b),
				"a": _safe_float(value.a),
			}
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return {
				"position": serialize(value.position),
				"size": serialize(value.size),
			}
		TYPE_PLANE:
			return {"normal": serialize(value.normal), "d": _safe_float(value.d)}
		TYPE_BASIS:
			return {
				"x": serialize(value.x),
				"y": serialize(value.y),
				"z": serialize(value.z),
			}
		TYPE_TRANSFORM2D:
			return {
				"x": serialize(value.x),
				"y": serialize(value.y),
				"origin": serialize(value.origin),
			}
		TYPE_TRANSFORM3D:
			return {
				"basis": serialize(value.basis),
				"origin": serialize(value.origin),
			}
		TYPE_PROJECTION:
			return {
				"x": serialize(value.x),
				"y": serialize(value.y),
				"z": serialize(value.z),
				"w": serialize(value.w),
			}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(serialize(item))
			return arr
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[str(key)] = serialize(value[key])
			return out
		TYPE_OBJECT:
			if value is Resource and value.resource_path:
				return value.resource_path
			return str(value)
		_:
			return str(value)
