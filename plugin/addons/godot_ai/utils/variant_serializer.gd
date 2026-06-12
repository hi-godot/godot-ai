@tool
extends RefCounted

## Converts Godot Variants into values that can be encoded as JSON.


static func serialize(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_RECT2, TYPE_RECT2I, TYPE_AABB:
			return {
				"position": serialize(value.position),
				"size": serialize(value.size),
			}
		TYPE_PLANE:
			return {"normal": serialize(value.normal), "d": value.d}
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
