@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const _FINGERPRINT_CHUNK_BYTES := 256 * 1024
const _COLLECTION_ITEMS_PER_STEP := 128
const _LINK_VALUE_TYPES := [TYPE_NIL, TYPE_OBJECT, TYPE_ARRAY, TYPE_DICTIONARY]

var _source_path: String
var _edited_path: String
var _edited_uid := ResourceUID.INVALID_ID
var _directory: DirAccess
var _pending: Array[String] = []
var _visited: Dictionary = {}
var _checked_paths: Dictionary = {}
var _load_queue: Array[String] = []
var _states: Array[Dictionary] = []
var _queued_scenes: Dictionary = {}
var _scene_edges: Dictionary = {}
var _current_state: Dictionary = {}
var _state_index := 0
var _loaded_values: Array[Dictionary] = []
var _seen_resources: Dictionary = {}
var _file_versions: Dictionary = {}
var _version_checks: Array[String] = []
var _hash_file: FileAccess
var _hash_length := 0
var _hasher: HashingContext


func _init(path: String, edited_path: String) -> void:
	_source_path = path
	_edited_path = edited_path.replace("\\", "/").simplify_path()
	if not _edited_path.is_empty():
		_edited_uid = ResourceLoader.get_resource_uid(_edited_path)
		_directory = DirAccess.open("res://")
	_enqueue(path)
	_load_queue.push_back(path)


func take_scene_to_load() -> String:
	while not _load_queue.is_empty():
		var path: String = _load_queue.pop_back()
		if not _queued_scenes.has(path):
			return path
	return ""


func inspect_loaded_scene(key: String, packed_scene: PackedScene) -> void:
	if not _queued_scenes.has(key):
		_queued_scenes[key] = packed_scene
		_seen_resources[packed_scene] = true
		_scene_edges[key] = []
		_states.push_back({"key": key, "state": packed_scene.get_state()})


func has_dependencies() -> bool:
	return not _pending.is_empty() or not _states.is_empty() or not _current_state.is_empty() or not _loaded_values.is_empty()


func scan_dependency() -> Dictionary:
	if not _pending.is_empty():
		var current: String = _pending.back()
		if _is_edited_scene(current):
			return _cycle_error()
		var version := _read_file_version(current)
		if version.has("error"):
			return version
		if not version.has("digest"):
			return {}
		_pending.pop_back()
		_file_versions[current] = version.digest
		if version.digest.is_empty():
			return {}
		for dependency: String in ResourceLoader.get_dependencies(current):
			# The UID also identifies the target if its registered path was moved.
			var reference := dependency.get_slice("::", 0)
			if _edited_uid != ResourceUID.INVALID_ID and reference.begins_with("uid://") and ResourceUID.text_to_id(reference) == _edited_uid:
				return _cycle_error()
			_enqueue(_dependency_path(dependency, current.get_base_dir()))
		return {}

	if not _loaded_values.is_empty():
		return _scan_loaded_value()

	# Native dependency metadata omits InstancePlaceholder. Inspect those and
	# any linked state already loaded, including the inherited root's base.
	if _current_state.is_empty():
		_current_state = _states.pop_back()
	var state: SceneState = _current_state.state
	var node_count := state.get_node_count()
	if _state_index >= node_count:
		var conn := _state_index - node_count
		if conn < state.get_connection_count():
			_enqueue_loaded_value(state.get_connection_binds(conn))
			_state_index += 1
		else:
			_current_state = {}
			_state_index = 0
		return {}
	var index := _state_index
	_state_index += 1
	for property in state.get_node_property_count(index):
		_enqueue_loaded_value(state.get_node_property_value(index, property))
	if state.is_node_instance_placeholder(index):
		var placeholder := state.get_node_instance_placeholder(index)
		# The native editor passes this literal to ResourceLoader, whose
		# relative paths are project-root-relative.
		var path := _dependency_path(placeholder, "res://")
		if path.is_empty():
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "An instance placeholder in %s has no loadable scene path: %s" % [state.get_path(), placeholder])
		if _is_edited_scene(path):
			return _cycle_error()
		_scene_edges[_current_state.key].append(path)
		_enqueue(path)
		_load_queue.push_back(path)
	else:
		var instance := state.get_node_instance(index)
		if instance != null:
			var key := "embedded:%d" % instance.get_instance_id() if instance.is_built_in() else _dependency_path(instance.resource_path, "res://")
			if not instance.is_built_in() and _is_edited_scene(key):
				return _cycle_error()
			_scene_edges[_current_state.key].append(key)
			inspect_loaded_scene(key, instance)
	return {}


func _enqueue_loaded_value(value: Variant, ancestors: Array = []) -> void:
	if value is Array and (value.is_empty() or value.get_typed_builtin() not in _LINK_VALUE_TYPES):
		return
	if value is Dictionary and (value.is_empty() or (value.get_typed_key_builtin() not in _LINK_VALUE_TYPES and value.get_typed_value_builtin() not in _LINK_VALUE_TYPES)):
		return
	if value is Resource or value is Array or value is Dictionary:
		_loaded_values.append({"value": value, "ancestors": ancestors})


func _scan_loaded_value() -> Dictionary:
	var entry: Dictionary = _loaded_values.pop_back()
	var value: Variant = entry.value
	if value is Resource:
		if _seen_resources.has(value):
			return {}
		var key := ""
		if not value.is_built_in():
			key = _dependency_path(value.resource_path, "res://")
			if _is_edited_scene(key):
				return _cycle_error()
			_enqueue(key)
		if value is PackedScene:
			inspect_loaded_scene(key if not key.is_empty() else "embedded:%d" % value.get_instance_id(), value)
		else:
			_seen_resources[value] = true
			for property: Dictionary in value.get_property_list():
				if property.usage & PROPERTY_USAGE_STORAGE and property.type in _LINK_VALUE_TYPES:
					_enqueue_loaded_value(value.get(property.name))
		return {}

	if not entry.has("items"):
		# An unsaved cached resource can contain a self-referential container.
		for ancestor in entry.ancestors:
			if is_same(value, ancestor):
				return {}
		entry.ancestors = entry.ancestors.duplicate()
		entry.ancestors.append(value)
		entry.items = value.keys() if value is Dictionary else value
	var items: Array = entry.items
	var offset: int = entry.get("offset", 0)
	var end := mini(items.size(), offset + _COLLECTION_ITEMS_PER_STEP)
	if end < items.size():
		entry.offset = end
		_loaded_values.append(entry)
	for index in range(offset, end):
		var child: Variant = items[index]
		_enqueue_loaded_value(child, entry.ancestors)
		if value is Dictionary:
			_enqueue_loaded_value(value.get(child), entry.ancestors)
	return {}


func begin_version_recheck() -> void:
	_version_checks.assign(_file_versions.keys())


func has_version_checks() -> bool:
	return not _version_checks.is_empty()


func recheck_version() -> Dictionary:
	var path: String = _version_checks.back()
	var version := _read_file_version(path)
	if version.has("error"):
		return version
	if not version.has("digest"):
		return {}
	_version_checks.pop_back()
	if version.digest != _file_versions[path]:
		return _changed_dependency(path)
	return {}


## An empty digest denotes a missing file, so creation/deletion both count
## as changes. Keep one live file handle and hash a bounded chunk per step.
func _read_file_version(path: String) -> Dictionary:
	if _hash_file == null:
		if not FileAccess.file_exists(path):
			return {"digest": PackedByteArray()}
		_hash_file = FileAccess.open(path, FileAccess.READ)
		if _hash_file == null:
			return _changed_dependency(path)
		_hash_length = _hash_file.get_length()
		_hasher = HashingContext.new()
		_hasher.start(HashingContext.HASH_SHA256)
	var remaining := _hash_length - _hash_file.get_position()
	if remaining > 0:
		var length := mini(remaining, _FINGERPRINT_CHUNK_BYTES)
		var chunk := _hash_file.get_buffer(length)
		if chunk.size() != length:
			return _changed_dependency(path)
		_hasher.update(chunk)
		if remaining > length:
			return {}
	if _hash_file.get_length() != _hash_length:
		return _changed_dependency(path)
	_hash_file.close()
	_hash_file = null
	return {"digest": _hasher.finish()}


static func _changed_dependency(path: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.FILESYSTEM_DISCOVERY_FAILED, "The saved dependency '%s' changed or could not be read while preparing the scene instance. Retry once project files are stable." % path)


func validate_scene_links() -> Dictionary:
	# A placeholder can materialize during editor instantiation. Reject any
	# cycles among loaded instance, inherited, and placeholder edges first.
	var incoming: Dictionary = {}
	for links: Array in _scene_edges.values():
		for target: String in links:
			incoming[target] = int(incoming.get(target, 0)) + 1
	var ready: Array[String] = []
	for source: String in _scene_edges:
		if not incoming.has(source):
			ready.push_back(source)
	var completed := 0
	while not ready.is_empty():
		var source: String = ready.pop_back()
		completed += 1
		for target: String in _scene_edges[source]:
			incoming[target] -= 1
			if incoming[target] == 0:
				ready.push_back(target)
	if completed != _scene_edges.size():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Instancing %s would expand a cycle of linked scenes; check its instance placeholders" % _source_path)
	return {}


func _enqueue(path: String) -> void:
	if path.is_absolute_path() and not _visited.has(path):
		_visited[path] = true
		_pending.append(path)


func _is_edited_scene(path: String) -> bool:
	if path.is_empty() or _edited_path.is_empty() or _checked_paths.has(path):
		return false
	_checked_paths[path] = true
	return path == _edited_path or (_directory != null and _directory.is_equivalent(path, _edited_path))


func _cycle_error() -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Instancing %s here would create a scene dependency cycle through %s" % [_source_path, _edited_path])


static func _dependency_path(dependency: String, base_dir: String) -> String:
	var parts := dependency.split("::", true)
	var path := parts[0]
	if path.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(path)
		if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
			path = ResourceUID.get_id_path(uid)
		else:
			path = parts[2] if parts.size() >= 3 else ""
	if not path.is_empty() and path.is_relative_path():
		path = base_dir.path_join(path)
	return path.replace("\\", "/").simplify_path()


static func parse_fields(params: Dictionary) -> Dictionary:
	var fields := {}
	for field in ["position", "rotation_degrees", "scale"]:
		if not params.has(field):
			continue
		var result := _parse_field(field, params[field])
		if result.has("error"):
			return result
		fields[field] = result.value
	return {"fields": fields}


static func resolve_transform(node: Node, parent: Node, space: String, fields: Dictionary) -> Dictionary:
	if fields.is_empty():
		return {}
	if not (node is Node2D or node is Node3D):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Placement requires a Node2D or Node3D scene root")
	for field: String in fields:
		var required_type := TYPE_VECTOR3
		if node is Node2D:
			required_type = TYPE_FLOAT if field == "rotation_degrees" else TYPE_VECTOR2
		if typeof(fields[field]) != required_type:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must use %s for a %s scene root" % [field, type_string(required_type), node.get_class()])
	if node is Node2D:
		if space == "local":
			return _place_local_2d(node, fields)
		var parent_transform := Transform2D.IDENTITY
		if not node.top_level and parent is CanvasItem:
			parent_transform = parent.get_global_transform()
		return _place_world_2d(node.transform, parent_transform, fields)

	var parent_transform := Transform3D.IDENTITY
	if space == "world" and not node.top_level and parent is Node3D:
		parent_transform = parent.global_transform
	var rotation_order: EulerOrder = node.rotation_order if space == "local" else EULER_ORDER_YXZ
	return _place_3d(node.transform, parent_transform, fields, rotation_order, space == "world" and node.is_scale_disabled())


static func _parse_field(field: String, input: Variant) -> Dictionary:
	if field == "rotation_degrees" and _number(input):
		var angle := _angle(input)
		if not _native_number(angle):
			return _finite_error(field)
		return {"value": angle}
	if not input is Dictionary:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be numeric coordinates in an object%s" % [field, " or a number for 2D rotation" if field == "rotation_degrees" else ""])
	var axes := ["x", "y", "z"] if field == "rotation_degrees" or input.has("z") else ["x", "y"]
	if input.size() != axes.size():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be an object with numeric fields %s" % [field, ", ".join(axes)])
	var components: Array[float] = []
	for axis in axes:
		if not _number(input.get(axis)):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s.%s must be a number" % [field, axis])
		var component := _angle(input[axis]) if field == "rotation_degrees" else float(input[axis])
		if not _native_number(component):
			return _finite_error(field + "." + axis)
		components.append(component)
	var value: Variant = Vector2(components[0], components[1]) if axes.size() == 2 else Vector3(components[0], components[1], components[2])
	return {"value": value}


static func _number(value: Variant) -> bool:
	return value is float or value is int


static func _angle(input: Variant) -> float:
	# A rotation can be reduced before conversion to Godot's native precision.
	return deg_to_rad(fmod(float(input), 360.0))


static func _native_number(value: float) -> bool:
	var native := Vector2(value, 0.0).x
	return is_finite(native) and (native != 0.0 or value == 0.0)


static func _finite_error(field: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be a finite number representable in a Godot transform" % field)


static func _place_local_2d(node: Node2D, fields: Dictionary) -> Dictionary:
	if fields.has("rotation_degrees") or fields.has("scale"):
		var rotation: float = fields.get("rotation_degrees", node.rotation)
		var scale: Vector2 = fields.get("scale", node.scale)
		var candidate := Transform2D(rotation, scale, node.skew, Vector2.ZERO)
		if not candidate.is_finite() or not _invertible(candidate.determinant()) or not _valid_2d_scale(scale):
			return _placement_error()
	# Node2D stores local components directly, including an authored negative X
	# scale that would be normalized to a different representation in a matrix.
	if fields.has("rotation_degrees"):
		fields = fields.duplicate()
		fields.rotation = fields.rotation_degrees
		fields.erase("rotation_degrees")
	return {"properties": fields}


static func _place_world_2d(original: Transform2D, parent: Transform2D, fields: Dictionary) -> Dictionary:
	if not _invertible(parent.determinant()) or not parent.is_finite():
		return _parent_transform_error()
	var inverse := parent.affine_inverse()
	if not inverse.is_finite():
		return _parent_transform_error()

	var target := parent * original
	target.origin = fields.get("position", target.origin)
	if not fields.has("rotation_degrees") and not fields.has("scale"):
		var position := inverse * target.origin
		if not position.is_finite() or not (parent * position).is_equal_approx(target.origin):
			return _placement_error()
		return {"properties": {"position": position}}
	if not _invertible(target.determinant()):
		return _placement_error()
	var rotation: float = fields.get("rotation_degrees", target.get_rotation())
	var scale: Vector2 = fields.get("scale", target.get_scale())
	target = Transform2D(rotation, scale, target.get_skew(), target.origin)
	if not target.get_scale().is_equal_approx(scale) or not is_zero_approx(angle_difference(rotation, target.get_rotation())):
		return _placement_error()
	var local := inverse * target

	# Node2D saves TRS and skew independently; its scale setter clamps tiny axes.
	var local_scale := local.get_scale()
	if not local.is_finite() or not _invertible(local.determinant()) or not _valid_2d_scale(local_scale):
		return _placement_error()
	var saved := Transform2D(local.get_rotation(), local_scale, local.get_skew(), local.origin)
	if not (parent * saved).is_equal_approx(target):
		return _placement_error()
	return {"properties": {"transform": local}}


static func _valid_2d_scale(scale: Vector2) -> bool:
	return not is_zero_approx(scale.x) and not is_zero_approx(scale.y)


static func _place_3d(original: Transform3D, parent: Transform3D, fields: Dictionary, rotation_order: EulerOrder, scale_disabled: bool) -> Dictionary:
	if not _invertible(parent.basis.determinant()) or not parent.is_finite():
		return _parent_transform_error()
	var inverse := parent.affine_inverse()
	if not inverse.is_finite():
		return _parent_transform_error()

	var local := original
	var target := parent * original
	target.origin = fields.get("position", target.origin)
	if fields.has("rotation_degrees") or fields.has("scale"):
		if not _invertible(target.basis.determinant()):
			return _placement_error()
		var rotation := Basis(target.basis.get_rotation_quaternion())
		var expected_rotation := rotation
		if fields.has("rotation_degrees"):
			expected_rotation = Basis.from_euler(fields.rotation_degrees, rotation_order)
		var current_scale := target.basis.get_scale()
		var expected_scale: Vector3 = fields.get("scale", target.basis.orthonormalized().get_scale() if scale_disabled else current_scale)
		if fields.has("scale") and not scale_disabled:
			target.basis = target.basis.scaled_local(expected_scale / current_scale)
		if fields.has("rotation_degrees"):
			target.basis = expected_rotation * rotation.transposed() * target.basis
		if not target.basis.is_finite() or not _invertible(target.basis.determinant()):
			return _placement_error()
		var visible_basis := target.basis.orthonormalized() if scale_disabled else target.basis
		if not visible_basis.get_scale().is_equal_approx(expected_scale) or not Basis(visible_basis.get_rotation_quaternion()).is_equal_approx(expected_rotation):
			return _placement_error()
		local = inverse * target
	elif fields.has("position"):
		local.origin = inverse * target.origin

	if not local.is_finite() or not (parent * local).is_equal_approx(target):
		return _placement_error()
	return {"properties": {"transform": local}}


static func _invertible(determinant: float) -> bool:
	return is_finite(determinant) and determinant != 0.0


static func _parent_transform_error() -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "The effective parent transform is singular or non-finite; use local space or fix the parent transform")


static func _placement_error() -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "The requested placement cannot be represented by the scene root's saved transform; check rotation and scale for incompatible, singular or out-of-range values")
