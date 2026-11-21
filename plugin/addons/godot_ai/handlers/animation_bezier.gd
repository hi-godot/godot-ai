@tool
extends RefCounted

## Stage native Bézier keys and retain the exact new track for scene undo.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

var _animation: Animation
var _staged: Animation
var _path: NodePath
var _inserted := false


func _init(animation: Animation, staged: Animation) -> void:
	_animation = animation
	_staged = staged
	_path = staged.track_get_path(0)


static func target_error(player: AnimationPlayer, path: String, scene_root: Node) -> Dictionary:
	var parts := path.split(":")
	if parts.size() < 2 or "" in parts or path.begins_with("/"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"track_path must be relative to the AnimationPlayer root and end in a property, such as Door:rotation_degrees:y")
	var root := player.get_node_or_null(player.root_node) if not player.root_node.is_empty() else null
	if root == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"AnimationPlayer root_node '%s' does not resolve" % player.root_node)
	if root != scene_root and not scene_root.is_ancestor_of(root):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "AnimationPlayer root_node must be inside the edited scene")
	var node := root.get_node_or_null(NodePath(parts[0]))
	if node == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"Node '%s' in track_path '%s' does not resolve from the AnimationPlayer root" % [parts[0], path])
	if node != scene_root and not scene_root.is_ancestor_of(node):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"track_path '%s' must target a node inside the edited scene" % path)

	var target: Object = node
	var property_path := NodePath(":" + parts[1])
	if parts.size() > 2:
		# Resolve resource prefixes the same way as AnimationMixer.
		var resolved := root.get_node_and_resource(NodePath(path))
		target = resolved[1] if resolved[1] != null else node
		property_path = resolved[2]
	if property_path.is_empty():
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Float property or component at track_path '%s' was not found" % path)
	if _property_is_read_only(target, property_path.get_subname(0)):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"track_path '%s' targets a read-only property" % path)
	var value: Variant = target.get_indexed(property_path)
	if value == null:
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Float property or component at track_path '%s' was not found" % path)
	if not value is float:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"track_path '%s' must resolve to a float property or component (got %s)" % [path, type_string(typeof(value))])
	return {}


static func _property_is_read_only(target: Object, property_name: StringName) -> bool:
	for property in target.get_property_list():
		if property.name == property_name:
			if int(property.usage) & PROPERTY_USAGE_READ_ONLY:
				return true
			break
	# A registered getter with no setter means this native property cannot
	# be animated. Script/dynamic properties do not have ClassDB accessors.
	var native_class := target.get_class()
	return (
		not ClassDB.class_get_property_getter(native_class, property_name).is_empty()
		and ClassDB.class_get_property_setter(native_class, property_name).is_empty()
	)


static func stage(path: NodePath, keyframes: Variant) -> Dictionary:
	if not keyframes is Array or keyframes.is_empty():
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "keyframes must be a non-empty array")
	var keys: Array[Dictionary] = []
	for i in keyframes.size():
		var location := "keyframes[%d]" % i
		var key: Variant = keyframes[i]
		if not key is Dictionary:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be an object" % location)
		for field in key:
			if field not in ["time", "value", "in_handle", "out_handle"]:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s has unknown field '%s'" % [location, field])
		if not key.has("time") or not key.has("value"):
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "%s requires time and value" % location)
		if not _is_number(key.time) or float(key.time) < 0.0:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.time must be a finite nonnegative number" % location)
		if not _is_number(key.value):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.value must be a finite number" % location)
		# On disk Godot stores both fields as real_t, the same precision as Vector2.
		var point := Vector2(float(key.time), float(key.value))
		if not _fits_real(point.x, float(key.time)):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.time is outside Godot's stored numeric range" % location)
		if not _fits_real(point.y, float(key.value)):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s.value is outside Godot's stored numeric range" % location)
		var incoming: Variant = _handle(key.get("in_handle", [0, 0]), location + ".in_handle", true)
		if incoming is Dictionary:
			return incoming
		var outgoing: Variant = _handle(key.get("out_handle", [0, 0]), location + ".out_handle", false)
		if outgoing is Dictionary:
			return outgoing
		keys.append({"time": point.x, "value": point.y, "in_handle": incoming, "out_handle": outgoing, "location": location})

	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.time < b.time)
	var staged := Animation.new()
	var index := staged.add_track(Animation.TYPE_BEZIER)
	staged.track_set_path(index, path)
	for i in keys.size():
		var key := keys[i]
		# Godot adds relative handles to the corresponding key in real_t.
		# Only handles that control an actual segment need this check.
		if i > 0 and not is_finite(Vector2(0.0, key.value + key.in_handle.y).y):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"%s.in_handle plus the key value exceeds Godot's stored numeric range" % key.location)
		if i < keys.size() - 1 and not is_finite(Vector2(0.0, key.value + key.out_handle.y).y):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"%s.out_handle plus the key value exceeds Godot's stored numeric range" % key.location)
		staged.bezier_track_insert_key(index, key.time, key.value, key.in_handle, key.out_handle)
		if staged.track_get_key_count(index) != i + 1:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"%s.time conflicts with another key at Godot's stored precision" % key.location)
	return {"animation": staged}


static func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _fits_real(stored: float, original: float) -> bool:
	return is_finite(stored) and (stored != 0.0 or original == 0.0)


static func _handle(value: Variant, location: String, incoming: bool) -> Variant:
	if not value is Array or value.size() != 2 or not _is_number(value[0]) or not _is_number(value[1]):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s must be [seconds, value_offset] with finite numbers" % location)
	var time := float(value[0])
	if (incoming and time > 0.0) or (not incoming and time < 0.0):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"%s time offset must be %s" % [location, "nonpositive" if incoming else "nonnegative"])
	var handle := Vector2(time, float(value[1]))
	if not _fits_real(handle.x, time) or not _fits_real(handle.y, float(value[1])):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s is outside Godot's stored numeric range" % location)
	return handle


func has_identical_track() -> bool:
	return _find_track() != -1


func apply() -> void:
	if has_identical_track():
		push_warning("Bézier track '%s' already exists; skipped duplicate redo" % _path)
		return
	_staged.copy_track(0, _animation)
	_inserted = true


func revert() -> void:
	if not _inserted:
		return
	var index := _find_track()
	if index >= 0:
		_animation.remove_track(index)
	else:
		push_warning("Bézier track '%s' changed or became ambiguous; left the tracks intact" % _path)
	_inserted = false


## Godot tracks have no stable ID. Check full native key data so another
## track with the same path, or a track moved to our old index, is safe.
func _find_track() -> int:
	var found := -1
	for i in _animation.get_track_count():
		if _matches_track(i):
			if found >= 0:
				return -2
			found = i
	return found


func _matches_track(index: int) -> bool:
	var count := _staged.track_get_key_count(0)
	if (
		_animation.track_get_type(index) != Animation.TYPE_BEZIER
		or _animation.track_get_path(index) != _path
		or _animation.track_get_key_count(index) != count
	):
		return false
	for key in count:
		if (
			_animation.track_get_key_time(index, key) != _staged.track_get_key_time(0, key)
			or _animation.track_get_key_value(index, key) != _staged.track_get_key_value(0, key)
		):
			return false
	return true
