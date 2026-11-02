@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_ITEMS := 4096


static func _error(location: String, message: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s: %s" % [location, message])


static func _keys(value: Variant, allowed: Array, location: String) -> Variant:
	if not value is Dictionary:
		return _error(location, "expected an object")
	for key in value:
		if key not in allowed:
			return _error(location, "unknown field '%s'" % key)
	return null


static func _number(value: Variant, minimum: float, location: String) -> Variant:
	if not (value is int or value is float) or not is_finite(float(value)) or float(value) < minimum:
		return _error(location, "expected a finite number >= %s" % minimum)
	return null


static func _point(value: Variant, minimum: int, location: String) -> Variant:
	var error: Variant = _keys(value, ["x", "y"], location)
	if error != null:
		return error
	for axis in ["x", "y"]:
		var number: Variant = value.get(axis)
		error = _number(number, minimum, location + "." + axis)
		if error != null:
			return error
		if float(number) != floor(float(number)) or float(number) > 1048576:
			return _error(location + "." + axis, "expected an integer <= 1048576")
	return Vector2i(int(value.x), int(value.y))


static func _texture(value: Variant, location: String) -> Dictionary:
	if not value is String or value.is_empty():
		return _error(location, "expected a texture resource path")
	var error: Variant = McpPathValidator.loadable_error(value, location)
	if error != null:
		return error
	var texture := ResourceLoader.load(value)
	if not texture is Texture2D:
		return _error(location, "resource must load as Texture2D")
	if texture.get_script() != null or ClassDB.class_get_api_type(texture.get_class()) not in [ClassDB.API_CORE, ClassDB.API_EDITOR]:
		return _error(location, "texture must be an engine built-in resource without a script")
	return {"texture": texture}


static func output_error(path: String, overwrite: bool) -> Variant:
	var error: Variant = McpPathValidator.path_error(path, "resource_path", true)
	if error != null:
		return error
	if path.contains("::") or path.get_extension() not in ["tres", "res"] or FileAccess.file_exists(path + ".import"):
		return _error("resource_path", "expected a non-imported .tres or .res file beneath res://")
	if FileAccess.file_exists(path) and not overwrite:
		return _error("resource_path", "already exists; pass overwrite=true to replace the entire resource")
	return null


static func sprite_frames(animations: Variant) -> Dictionary:
	if not animations is Array or animations.is_empty() or animations.size() > MAX_ITEMS:
		return _error("animations", "provide 1–4096 animations")
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	var total := 0
	for i in animations.size():
		var location := "animations[%s]" % i
		var animation: Variant = animations[i]
		var error: Variant = _keys(animation, ["name", "fps", "loop_mode", "frames"], location)
		if error != null:
			return error
		var name: Variant = animation.get("name")
		if not name is String or name.is_empty() or frames.has_animation(name):
			return _error(location + ".name", "expected a unique, nonempty name")
		var fps: Variant = animation.get("fps", 5.0)
		error = _number(fps, 0.001, location + ".fps")
		if error != null:
			return error
		var modes := {"none": SpriteFrames.LOOP_NONE, "linear": SpriteFrames.LOOP_LINEAR, "pingpong": SpriteFrames.LOOP_PINGPONG}
		var mode: Variant = animation.get("loop_mode", "linear")
		if not mode is String or not modes.has(mode):
			return _error(location + ".loop_mode", "expected none, linear, or pingpong")
		var entries: Variant = animation.get("frames")
		if not entries is Array or entries.is_empty() or entries.size() + total > MAX_ITEMS:
			return _error(location + ".frames", "provide nonempty frames, at most 4096 total")
		frames.add_animation(name)
		frames.set_animation_speed(name, float(fps))
		frames.set_animation_loop_mode(name, modes[mode])
		for j in entries.size():
			var frame_location := location + ".frames[%s]" % j
			var entry: Variant = entries[j]
			error = _keys(entry, ["texture_path", "region", "duration"], frame_location)
			if error != null:
				return error
			var loaded := _texture(entry.get("texture_path"), frame_location + ".texture_path")
			if loaded.has("error"):
				return loaded
			var texture: Texture2D = loaded.texture
			if entry.has("region"):
				var region: Variant = entry.region
				error = _keys(region, ["x", "y", "width", "height"], frame_location + ".region")
				if error != null:
					return error
				for field in ["x", "y", "width", "height"]:
					error = _number(region.get(field), 0.001 if field in ["width", "height"] else 0.0, frame_location + ".region." + field)
					if error != null:
						return error
				var rectangle := Rect2(float(region.x), float(region.y), float(region.width), float(region.height))
				if not Rect2(Vector2.ZERO, texture.get_size()).encloses(rectangle):
					return _error(frame_location + ".region", "region must fit inside the texture")
				var atlas := AtlasTexture.new()
				atlas.atlas = texture
				atlas.region = rectangle
				texture = atlas
			var duration: Variant = entry.get("duration", 1.0)
			error = _number(duration, 0.001, frame_location + ".duration")
			if error != null:
				return error
			frames.add_frame(name, texture, float(duration))
			var stored_duration := frames.get_frame_duration(name, frames.get_frame_count(name) - 1)
			if not is_finite(stored_duration) or not is_equal_approx(stored_duration, float(duration)):
				return _error(frame_location + ".duration", "engine cannot preserve this frame duration")
			total += 1
	return {"resource": frames, "animation_count": animations.size(), "frame_count": total}


static func tileset_atlas(params: Dictionary) -> Dictionary:
	var loaded := _texture(params.get("texture_path"), "texture_path")
	if loaded.has("error"):
		return loaded
	var tile_size: Variant = _point(params.get("tile_size"), 1, "tile_size")
	if tile_size is Dictionary:
		return tile_size
	var margins: Variant = _point(params.get("margins", {"x": 0, "y": 0}), 0, "margins")
	if margins is Dictionary:
		return margins
	var separation: Variant = _point(params.get("separation", {"x": 0, "y": 0}), 0, "separation")
	if separation is Dictionary:
		return separation
	var source_id: Variant = params.get("source_id", 0)
	var source_id_error: Variant = _number(source_id, 0, "source_id")
	if source_id_error != null:
		return source_id_error
	if float(source_id) != floor(float(source_id)) or source_id > 2147483647:
		return _error("source_id", "expected a nonnegative 32-bit integer")
	var tiles: Variant = params.get("tiles")
	if not tiles is Array or tiles.is_empty() or tiles.size() > MAX_ITEMS:
		return _error("tiles", "provide 1–4096 tiles")
	var source := TileSetAtlasSource.new()
	source.texture = loaded.texture
	source.texture_region_size = tile_size
	source.margins = margins
	source.separation = separation
	for i in tiles.size():
		var location := "tiles[%s]" % i
		var tile: Variant = tiles[i]
		var error: Variant = _keys(tile, ["coords", "size"], location)
		if error != null:
			return error
		var coords: Variant = _point(tile.get("coords"), 0, location + ".coords")
		if coords is Dictionary:
			return coords
		var size: Variant = _point(tile.get("size", {"x": 1, "y": 1}), 1, location + ".size")
		if size is Dictionary:
			return size
		if not source.has_room_for_tile(coords, size, 1, Vector2i.ZERO, 1):
			return _error(location, "tile overlaps another tile or lies outside the atlas")
		source.create_tile(coords, size)
		if not source.has_tile(coords):
			return _error(location, "engine rejected tile creation")
	var tileset := TileSet.new()
	tileset.tile_size = tile_size
	if tileset.add_source(source, int(source_id)) != source_id:
		return _error("source_id", "engine rejected atlas source creation")
	return {"resource": tileset, "source_id": source_id, "tile_count": tiles.size()}
