@tool
extends McpTestSuite

const Builders := preload("res://addons/godot_ai/utils/resource_builders.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const TileSetHandler := preload("res://addons/godot_ai/handlers/tileset_handler.gd")
const TEXTURE := "res://tests/_builder_texture.tres"
const FRAMES := "res://tests/_builder_frames.tres"
const TILES := "res://tests/_builder_tiles.tres"

func suite_name() -> String:
	return "resource_builders"

func suite_setup(_context: Dictionary) -> void:
	var texture := GradientTexture2D.new()
	texture.width = 32
	texture.height = 32
	texture.gradient = Gradient.new()
	ResourceSaver.save(texture, TEXTURE)
	McpResourceIO.ensure_uid(TEXTURE, ResourceUID.INVALID_ID)

func suite_teardown() -> void:
	for path in [TEXTURE, FRAMES, TILES]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _animations() -> Array:
	return [{"name": "walk", "fps": 8.0, "loop_mode": "pingpong", "frames": [
		{"texture_path": TEXTURE, "region": {"x": 0, "y": 0, "width": 16, "height": 16}, "duration": 2.0},
		{"texture_path": TEXTURE},
	]}]

func _tiles() -> Dictionary:
	return {"texture_path": TEXTURE, "tile_size": {"x": 8, "y": 8}, "source_id": 3,
		"tiles": [{"coords": {"x": 0, "y": 0}, "size": {"x": 2, "y": 1}}, {"coords": {"x": 2, "y": 0}}]}

func test_sprite_frames_native_nested_atlas_and_duration() -> void:
	var built := Builders.sprite_frames(_animations())
	assert_has_key(built, "resource", str(built))
	if not built.has("resource"):
		return
	var frames: SpriteFrames = built.resource
	assert_eq(frames.get_animation_names(), PackedStringArray(["walk"]))
	assert_eq(frames.get_animation_speed("walk"), 8.0)
	assert_eq(frames.get_animation_loop_mode("walk"), SpriteFrames.LOOP_PINGPONG)
	assert_eq(frames.get_frame_count("walk"), 2)
	assert_eq(frames.get_frame_duration("walk", 0), 2.0)
	var atlas := frames.get_frame_texture("walk", 0) as AtlasTexture
	assert_true(atlas != null)
	assert_eq(atlas.region, Rect2(0, 0, 16, 16))
	assert_true(atlas.atlas == load(TEXTURE))
	assert_true(frames.get_frame_texture("walk", 1) == load(TEXTURE))

func test_sprite_frames_saved_readback_uid_and_cached_overwrite() -> void:
	var handler := ResourceHandler.new(null)
	var params := {"resource_path": FRAMES, "animations": _animations(), "overwrite": true}
	assert_has_key(handler.create_sprite_frames(params), "data")
	var held := load(FRAMES) as SpriteFrames
	var uid := ResourceLoader.get_resource_uid(FRAMES)
	params.animations[0].fps = 12.0
	params.animations[0].frames.resize(1)
	assert_has_key(handler.create_sprite_frames(params), "data")
	assert_true(load(FRAMES) == held)
	assert_true(load(ResourceUID.id_to_text(uid)) == held)
	assert_eq(held.get_animation_speed("walk"), 12.0)
	assert_eq(held.get_frame_count("walk"), 1)
	var disk := ResourceLoader.load(FRAMES, "", ResourceLoader.CACHE_MODE_IGNORE) as SpriteFrames
	var atlas := disk.get_frame_texture("walk", 0) as AtlasTexture
	assert_true(atlas != null)
	assert_true(atlas.atlas != null)
	assert_eq(atlas.region, Rect2(0, 0, 16, 16))

func test_sprite_frames_late_invalid_frame_leaves_file_unchanged() -> void:
	var handler := ResourceHandler.new(null)
	var params := {"resource_path": FRAMES, "animations": _animations(), "overwrite": true}
	assert_has_key(handler.create_sprite_frames(params), "data")
	var held := load(FRAMES) as SpriteFrames
	var bytes := FileAccess.get_file_as_bytes(FRAMES)
	params.animations[0].frames[1] = {"texture_path": TEXTURE, "region": {"x": 30, "y": 0, "width": 16, "height": 16}}
	var result := handler.create_sprite_frames(params)
	assert_is_error(result)
	assert_true(result.error.message.contains("animations[0].frames[1].region"))
	assert_eq(FileAccess.get_file_as_bytes(FRAMES), bytes)
	assert_eq(held.get_frame_count("walk"), 2)

func test_sprite_frames_rejects_ambiguous_fields_and_invalid_values() -> void:
	for field in ["__class__", "texture", "duraton"]:
		var animations := _animations()
		animations[0].frames[0][field] = "ignored?"
		assert_is_error(Builders.sprite_frames(animations))
	for value in [0, -1, "fast", true, INF, NAN]:
		var animations := _animations()
		animations[0].fps = value
		assert_is_error(Builders.sprite_frames(animations))
	var duplicates := _animations()
	duplicates.append(duplicates[0].duplicate(true))
	assert_is_error(Builders.sprite_frames(duplicates))

func test_tileset_native_source_and_multicell_tiles() -> void:
	var built := Builders.tileset_atlas(_tiles())
	assert_has_key(built, "resource", str(built))
	if not built.has("resource"):
		return
	var tileset: TileSet = built.resource
	assert_eq(tileset.tile_size, Vector2i(8, 8))
	assert_eq(tileset.get_source_count(), 1)
	assert_true(tileset.has_source(3))
	var source := tileset.get_source(3) as TileSetAtlasSource
	assert_true(source.texture == load(TEXTURE))
	assert_eq(source.get_tiles_count(), 2)
	assert_eq(source.get_tile_size_in_atlas(Vector2i.ZERO), Vector2i(2, 1))
	assert_true(source.has_tile(Vector2i(2, 0)))

func test_tileset_saved_readback_and_cache_overwrite() -> void:
	var handler := TileSetHandler.new()
	var params := _tiles()
	params.merge({"resource_path": TILES, "overwrite": true})
	assert_has_key(handler.create_atlas(params), "data")
	var held := load(TILES) as TileSet
	var uid := ResourceLoader.get_resource_uid(TILES)
	params.tiles.resize(1)
	assert_has_key(handler.create_atlas(params), "data")
	assert_true(load(TILES) == held)
	assert_true(load(ResourceUID.id_to_text(uid)) == held)
	assert_eq((held.get_source(3) as TileSetAtlasSource).get_tiles_count(), 1)
	var disk := ResourceLoader.load(TILES, "", ResourceLoader.CACHE_MODE_IGNORE) as TileSet
	assert_eq((disk.get_source(3) as TileSetAtlasSource).get_tiles_count(), 1)
	assert_true((disk.get_source(3) as TileSetAtlasSource).texture != null)

func test_tileset_overlap_and_late_invalid_coordinate_leave_file_unchanged() -> void:
	var handler := TileSetHandler.new()
	var params := _tiles()
	params.merge({"resource_path": TILES, "overwrite": true})
	assert_has_key(handler.create_atlas(params), "data")
	var bytes := FileAccess.get_file_as_bytes(TILES)
	for coords in [{"x": 1, "y": 0}, {"x": 99, "y": 0}, {"x": 1.5, "y": 0}]:
		params.tiles[1].coords = coords
		assert_is_error(handler.create_atlas(params))
		assert_eq(FileAccess.get_file_as_bytes(TILES), bytes)

func test_tileset_refuses_unknown_tile_fields() -> void:
	var params := _tiles()
	params.tiles[0]["terrain"] = 1
	assert_is_error(Builders.tileset_atlas(params))

func test_output_path_and_overwrite_validation() -> void:
	assert_is_error(Builders.output_error("res://../escape.tres", false))
	assert_is_error(Builders.output_error("res://tests/wrong.png", false))
	assert_is_error(Builders.output_error(TEXTURE, false))

func test_sprite_frame_duration_must_survive_native_storage() -> void:
	for duration in [1e100, 0.001]:
		var animations := _animations()
		animations[0].frames[0].duration = duration
		assert_is_error(Builders.sprite_frames(animations))
