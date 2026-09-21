@tool
extends RefCounted

## Per-call, native-only resource graphs. Limits bound output and traversal,
## not time spent inside native engine getters.
const Serializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const FAMILIES: Array[String] = [
	"Shape2D", "Shape3D", "Mesh", "Material", "PhysicsMaterial", "StyleBox",
	"Gradient", "Curve", "Curve2D", "Curve3D", "GradientTexture1D",
	"GradientTexture2D", "CurveTexture", "CurveXYZTexture",
]
const MAX_RESOURCES := 32
const MAX_PROPERTIES := 64
const MAX_ENTRIES := 64
const MAX_VALUES := 512
const MAX_DEPTH := 3
const MAX_CONTAINER_DEPTH := 8
const MAX_STRING_BYTES := 1024
const MAX_STRING_CHARS := 256
const MAX_TRUNCATIONS := 32
const MAX_RESULT_BYTES := 65536
const BUILD_BYTES := 49152

var _depth: int
var _resources: Array[Dictionary] = []
var _references: Dictionary = {}
var _pending: Array[Dictionary] = []
var _truncations: Array[Dictionary] = []
var _values := 0
var _bytes_left := BUILD_BYTES


static func supported(resource: Resource) -> bool:
	if resource.get_script() != null:
		return false
	for family in FAMILIES:
		if resource.is_class(family):
			return true
	return false


func inspect(resource: Resource, depth: int) -> Dictionary:
	_depth = depth
	var root := _resource(resource, 0, "root")
	var index := 0
	while index < _pending.size():
		var item := _pending[index]
		_expand(item.resource, item.level, item.reference, item.row)
		index += 1
	var graph := {"root": root, "resources": _resources, "truncations": _truncations}
	var result := {"data": graph}
	if JSON.stringify(result).to_utf8_buffer().size() > MAX_RESULT_BYTES:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Resource inspection exceeded the 65536-byte result limit; inspect at a lower depth")
	return result


func _omit(location: String, reason: String) -> Dictionary:
	if _truncations.size() < MAX_TRUNCATIONS:
		_truncations.append({"location": location.substr(0, 96), "reason": reason})
	else:
		_truncations[MAX_TRUNCATIONS - 1] = {"location": "root", "reason": "truncation_limit"}
	return {"omitted": reason}


func _charge(bytes: int) -> bool:
	if bytes > _bytes_left:
		return false
	_bytes_left -= bytes
	return true


func _string(value: String, location: String) -> String:
	var bounded := value.substr(0, MAX_STRING_CHARS)
	while JSON.stringify(bounded).to_utf8_buffer().size() > MAX_STRING_BYTES:
		bounded = bounded.substr(0, bounded.length() - 1)
	if bounded.length() < value.length():
		_omit(location, "string_bytes")
	return bounded


func _resource(resource: Resource, level: int, location: String) -> Dictionary:
	var identity := resource.get_instance_id()
	if _references.has(identity):
		return {"ref": _references[identity]}
	if _resources.size() >= MAX_RESOURCES:
		return _omit(location, "resources")
	var bounded_path := _string(resource.resource_path, location)
	if not _charge(128 + resource.get_class().length() * 6 + JSON.stringify(bounded_path).to_utf8_buffer().size()):
		return _omit(location, "result_bytes")
	var reference := "r%d" % (_resources.size() + 1)
	_references[identity] = reference
	var row := {
		"id": reference, "type": resource.get_class(),
		"path": bounded_path, "properties": {},
	}
	_resources.append(row)
	_pending.append({"resource": resource, "level": level, "reference": reference, "row": row})
	return {"ref": reference}


func _expand(resource: Resource, level: int, reference: String, row: Dictionary) -> void:
	if resource.get_script() != null:
		row["omitted"] = _omit(reference, "scripted_resource").omitted
		return
	if not supported(resource):
		row["omitted"] = _omit(reference, "unsupported_resource").omitted
		return
	if level > _depth:
		row["omitted"] = _omit(reference, "depth").omitted
		return
	var count := 0
	for property in ClassDB.class_get_property_list(resource.get_class()):
		var name: String = property.name
		if name == "script" or not (int(property.usage) & PROPERTY_USAGE_EDITOR) or int(property.type) == TYPE_NIL:
			continue
		if count >= MAX_PROPERTIES or _values >= MAX_VALUES:
			_omit(reference, "properties" if count >= MAX_PROPERTIES else "values")
			break
		if not _charge(name.length() * 6 + 64):
			_omit(reference, "result_bytes")
			break
		count += 1
		if int(property.type) in [TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]:
			row.properties[name] = _omit(reference + "." + name, "unsupported_value")
			continue
		row.properties[name] = _value(ClassDB.class_get_property(resource, name), level, 0, reference + "." + name)


func _value(value: Variant, level: int, nesting: int, location: String) -> Variant:
	if _values >= MAX_VALUES:
		return _omit(location, "values")
	_values += 1
	if not _charge(64):
		return _omit(location, "result_bytes")
	match typeof(value):
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Resource:
				return _resource(value, level + 1, location)
			return _omit(location, "unsupported_object")
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			var bounded := _string(str(value), location)
			if not _charge(JSON.stringify(bounded).to_utf8_buffer().size()):
				return _omit(location, "result_bytes")
			return bounded
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			if nesting >= MAX_CONTAINER_DEPTH:
				return _omit(location, "container_depth")
			var result: Array = []
			for index in mini(value.size(), MAX_ENTRIES):
				if _values >= MAX_VALUES or _bytes_left < 64:
					_omit(location, "values" if _values >= MAX_VALUES else "result_bytes")
					break
				result.append(_value(value[index], level, nesting + 1, location + "[%d]" % index))
			if value.size() > MAX_ENTRIES:
				_omit(location, "collection_entries")
			return result
		TYPE_DICTIONARY:
			if nesting >= MAX_CONTAINER_DEPTH:
				return _omit(location, "container_depth")
			var entries: Array = []
			var examined := 0
			for key in value:
				if examined >= MAX_ENTRIES or _values >= MAX_VALUES or _bytes_left < 128:
					_omit(location, "collection_entries" if examined >= MAX_ENTRIES else "values" if _values >= MAX_VALUES else "result_bytes")
					break
				examined += 1
				if typeof(key) not in [TYPE_STRING, TYPE_STRING_NAME, TYPE_INT, TYPE_BOOL]:
					_omit(location, "unsupported_key")
					continue
				var at := location + "[%d]" % entries.size()
				entries.append({"key": _value(key, level, nesting + 1, at), "value": _value(value[key], level, nesting + 1, at)})
			return {"entries": entries}
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_RECT2, TYPE_RECT2I, TYPE_AABB, TYPE_PLANE, TYPE_QUATERNION, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_PROJECTION, TYPE_COLOR:
			var serialized: Variant = Serializer.serialize(value)
			if not _charge(JSON.stringify(serialized).to_utf8_buffer().size()):
				return _omit(location, "result_bytes")
			return serialized
		_:
			return _omit(location, "unsupported_value")
