@tool
extends McpTestSuite

## Tests for TilesetHandler.get_atlas_tiles
##
## Validates: Requirements 1.1–1.11, 7.1–7.4
##
## This suite tests the get_atlas_tiles method and its parameter validation.
## It is written against the public handler contract so regressions in shape,
## ordering, or error codes are caught by CI.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const TilesetHandler := preload("res://addons/godot_ai/handlers/tileset_handler.gd")

var _handler: TilesetHandler
## Temporary .tres paths created during tests; cleaned up in teardown.
var _created_files: Array[String] = []


func suite_name() -> String:
	return "tileset_atlas"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = TilesetHandler.new()


func teardown() -> void:
	for path in _created_files:
		var abs_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			DirAccess.remove_absolute(abs_path)
		var uid_path := abs_path + ".uid"
		if FileAccess.file_exists(uid_path):
			DirAccess.remove_absolute(uid_path)
	_created_files.clear()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Build a minimal in-memory TileSet with one TileSetAtlasSource.
## The source uses a 1×1 white texture with 1×1 tile-region so that
## individual atlas positions can be created cheaply.
func _make_tileset_with_source(tile_coords: Array[Vector2i] = []) -> TileSet:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(1, 1)
	for coord in tile_coords:
		src.create_tile(coord)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(1, 1)
	ts.add_source(src, 0)
	return ts


## Save a resource to a temporary res:// path and register it for cleanup.
## Returns the path on success, or "" on failure.
func _save_temp_resource(res: Resource, rel_path: String) -> String:
	var full_path := "res://tests/_mcp_atlas_tmp/%s" % rel_path
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://tests/_mcp_atlas_tmp")
	)
	var err := ResourceSaver.save(res, full_path)
	if err != OK:
		return ""
	_created_files.append(full_path)
	return full_path


# ---------------------------------------------------------------------------
# Example-based tests — missing / invalid params
# ---------------------------------------------------------------------------

func test_missing_tileset_path_returns_missing_param() -> void:
	## Empty string value for tileset_path → MISSING_REQUIRED_PARAM
	## Validates: Requirement 1.2
	var result := _handler.get_atlas_tiles({"tileset_path": "", "source_id": 0})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_absent_tileset_path_key_returns_missing_param() -> void:
	## params dict with no tileset_path key at all → MISSING_REQUIRED_PARAM
	## Validates: Requirement 1.2
	var result := _handler.get_atlas_tiles({"source_id": 0})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_absent_source_id_key_returns_missing_param() -> void:
	## params dict without source_id key → MISSING_REQUIRED_PARAM
	## Validates: Requirement 1.3
	var result := _handler.get_atlas_tiles({"tileset_path": "res://some.tres"})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


# ---------------------------------------------------------------------------
# Example-based tests — resource resolution errors
# ---------------------------------------------------------------------------

func test_nonexistent_path_returns_resource_not_found() -> void:
	## Path that does not exist on disk → RESOURCE_NOT_FOUND with path in message
	## Validates: Requirement 1.4
	var fake_path := "res://nonexistent_atlas_test.tres"
	var result := _handler.get_atlas_tiles({"tileset_path": fake_path, "source_id": 0})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)
	assert_contains(result.error.message, fake_path)


func test_traversal_path_rejected_before_load() -> void:
	## #689: _resolve_atlas_source skipped the #347 traversal guard every
	## sibling load handler uses — checking only is_empty(). A res://../…
	## payload must be rejected with VALUE_OUT_OF_RANGE, not handed to load().
	var result := _handler.get_atlas_tiles({
		"tileset_path": "res://../etc/passwd.tres",
		"source_id": 0,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_absolute_path_rejected_before_load() -> void:
	## A raw absolute path (which load() honors directly) must be rejected too
	## — it's outside res:// containment even without a literal '..'.
	var result := _handler.get_atlas_tiles({
		"tileset_path": "/etc/passwd",
		"source_id": 0,
	})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_wrong_type_resource_returns_wrong_type() -> void:
	## A resource that is not a TileSet (plain Resource) → WRONG_TYPE
	## Validates: Requirement 1.5
	var plain := Resource.new()
	var path := _save_temp_resource(plain, "wrong_type_resource.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_is_error(result, ErrorCodes.WRONG_TYPE)


# ---------------------------------------------------------------------------
# Example-based tests — source_id range validation
# ---------------------------------------------------------------------------

func test_negative_source_id_returns_value_out_of_range() -> void:
	## source_id = -1 → VALUE_OUT_OF_RANGE
	## Validates: Requirement 1.6
	var ts := _make_tileset_with_source()
	var path := _save_temp_resource(ts, "tileset_neg_source.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": -1})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_out_of_range_source_id_returns_value_out_of_range() -> void:
	## source_id = 999 (beyond source count) → VALUE_OUT_OF_RANGE
	## Validates: Requirement 1.6
	var ts := _make_tileset_with_source()
	var path := _save_temp_resource(ts, "tileset_large_source.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 999})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


# ---------------------------------------------------------------------------
# Example-based tests — happy path
# ---------------------------------------------------------------------------

func test_empty_source_returns_empty_array() -> void:
	## TileSet with a zero-tile AtlasSource → {"tiles": [], "count": 0}
	## Validates: Requirement 1.9
	var ts := _make_tileset_with_source([])  # no tiles added
	var path := _save_temp_resource(ts, "tileset_empty_source.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_has_key(result.data, "tiles")
	assert_has_key(result.data, "count")
	assert_eq(result.data.tiles, [], "Empty source must return empty tiles array")
	assert_eq(result.data.count, 0, "Empty source must return count == 0")


func test_valid_source_returns_correct_shape() -> void:
	## TileSet with a known tile at Vector2i(2,3) → count == 1, element {"col": 2, "row": 3}
	## Validates: Requirements 1.8
	var ts := _make_tileset_with_source([Vector2i(2, 3)])
	var path := _save_temp_resource(ts, "tileset_valid_source.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "Should find exactly one tile")
	assert_eq(result.data.tiles.size(), 1, "tiles array must have one element")
	var tile: Dictionary = result.data.tiles[0]
	assert_has_key(tile, "col")
	assert_has_key(tile, "row")
	assert_eq(tile.col, 2, "col should match atlas x-coordinate")
	assert_eq(tile.row, 3, "row should match atlas y-coordinate")


func test_source_id_uses_raw_tileset_source_id() -> void:
	## Regression: source_id must be treated as raw TileSet source id.
	## Sparse/non-contiguous ids must be addressable by their real id values.
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)

	var src_a := TileSetAtlasSource.new()
	src_a.texture = tex
	src_a.texture_region_size = Vector2i(1, 1)
	src_a.create_tile(Vector2i(1, 1))

	var src_b := TileSetAtlasSource.new()
	src_b.texture = tex
	src_b.texture_region_size = Vector2i(1, 1)
	src_b.create_tile(Vector2i(7, 9))

	var ts := TileSet.new()
	ts.tile_size = Vector2i(1, 1)
	ts.add_source(src_a, 5)
	ts.add_source(src_b, 42)

	var path := _save_temp_resource(ts, "tileset_sparse_source_ids.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return

	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 42})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "raw source id 42 should resolve the second source")
	assert_eq(result.data.tiles.size(), 1)
	assert_eq(result.data.tiles[0].col, 7)
	assert_eq(result.data.tiles[0].row, 9)

	var wrong_id := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 1})
	assert_is_error(wrong_id, ErrorCodes.VALUE_OUT_OF_RANGE)


# ---------------------------------------------------------------------------
# Property 1: Idempotency of atlas query
##
## Validates: Requirements 1.8, 7.1, 7.4, 1.11
##
## Calling get_atlas_tiles twice with the same valid (tileset_path, source_id)
## must return equal response dictionaries — same tiles array (identical col/row
## values at each index in the same order) and same count — and must NOT alter
## any project file between calls.
# ---------------------------------------------------------------------------

func test_property_idempotency_empty_source() -> void:
	## Idempotency on empty source: both calls return {"tiles": [], "count": 0}
	var ts := _make_tileset_with_source([])
	var path := _save_temp_resource(ts, "tileset_idem_empty.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var params := {"tileset_path": path, "source_id": 0}
	var r1 := _handler.get_atlas_tiles(params.duplicate())
	var r2 := _handler.get_atlas_tiles(params.duplicate())
	assert_has_key(r1, "data")
	assert_has_key(r2, "data")
	assert_eq(r1.data.count, r2.data.count, "count must be equal across calls")
	assert_eq(r1.data.tiles.size(), r2.data.tiles.size(), "tiles array size must be equal")


func test_property_idempotency_single_tile() -> void:
	## Idempotency on source with one tile: col/row must match between calls
	var ts := _make_tileset_with_source([Vector2i(5, 7)])
	var path := _save_temp_resource(ts, "tileset_idem_single.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var params := {"tileset_path": path, "source_id": 0}
	var r1 := _handler.get_atlas_tiles(params.duplicate())
	var r2 := _handler.get_atlas_tiles(params.duplicate())
	assert_has_key(r1, "data")
	assert_has_key(r2, "data")
	assert_eq(r1.data.count, r2.data.count, "count must equal across idempotent calls")
	assert_eq(r1.data.tiles.size(), r2.data.tiles.size())
	for i in range(r1.data.tiles.size()):
		var t1: Dictionary = r1.data.tiles[i]
		var t2: Dictionary = r2.data.tiles[i]
		assert_eq(t1.col, t2.col, "col at index %d must match" % i)
		assert_eq(t1.row, t2.row, "row at index %d must match" % i)


func test_property_idempotency_multiple_tiles() -> void:
	## Idempotency on source with multiple tiles: order and values must be stable
	## Validates: Requirement 7.4 — same col/row values at each index in same order
	var coords: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 2), Vector2i(3, 1), Vector2i(2, 4)]
	var ts := _make_tileset_with_source(coords)
	var path := _save_temp_resource(ts, "tileset_idem_multi.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var params := {"tileset_path": path, "source_id": 0}
	var r1 := _handler.get_atlas_tiles(params.duplicate())
	var r2 := _handler.get_atlas_tiles(params.duplicate())
	assert_has_key(r1, "data")
	assert_has_key(r2, "data")
	assert_eq(r1.data.count, r2.data.count)
	assert_eq(r1.data.tiles.size(), r2.data.tiles.size())
	for i in range(r1.data.tiles.size()):
		var t1: Dictionary = r1.data.tiles[i]
		var t2: Dictionary = r2.data.tiles[i]
		assert_eq(t1.col, t2.col, "col[%d] must match between calls" % i)
		assert_eq(t1.row, t2.row, "row[%d] must match between calls" % i)


# ---------------------------------------------------------------------------
# Property 4: Valid-input response shape invariant
##
## Validates: Requirements 1.8, 7.1
##
## For any valid (tileset_path, source_id), the returned dict must have shape
## {"data": {"tiles": Array, "count": int}} where count == tiles.size() and
## every tile element has exactly the keys "col" (int) and "row" (int).
# ---------------------------------------------------------------------------

func test_property_shape_invariant_empty_source() -> void:
	## Shape invariant holds for zero-tile source
	var ts := _make_tileset_with_source([])
	var path := _save_temp_resource(ts, "tileset_shape_empty.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_has_key(result.data, "tiles")
	assert_has_key(result.data, "count")
	assert_true(result.data.tiles is Array, "tiles must be an Array")
	assert_true(result.data.count is int, "count must be an int")
	assert_eq(result.data.count, result.data.tiles.size(),
		"count must equal tiles.size()")


func test_property_shape_invariant_one_tile() -> void:
	## Shape invariant: count == tiles.size(), each tile has col (int) and row (int)
	var ts := _make_tileset_with_source([Vector2i(1, 1)])
	var path := _save_temp_resource(ts, "tileset_shape_one.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_eq(result.data.count, result.data.tiles.size(),
		"count must equal tiles.size()")
	for tile in result.data.tiles:
		assert_true(tile is Dictionary, "each tile must be a Dictionary")
		assert_has_key(tile, "col")
		assert_has_key(tile, "row")
		assert_true(tile.col is int, "col must be int")
		assert_true(tile.row is int, "row must be int")


func test_property_shape_invariant_many_tiles() -> void:
	## Shape invariant with several tiles: count == tiles.size(), all have col+row ints
	var coords: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1),
		Vector2i(2, 2), Vector2i(3, 4), Vector2i(5, 0),
	]
	var ts := _make_tileset_with_source(coords)
	var path := _save_temp_resource(ts, "tileset_shape_many.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_eq(result.data.count, coords.size(),
		"count must equal the number of registered tiles")
	assert_eq(result.data.tiles.size(), coords.size(),
		"tiles.size() must equal the number of registered tiles")
	assert_eq(result.data.count, result.data.tiles.size(),
		"count must equal tiles.size()")
	for tile in result.data.tiles:
		assert_has_key(tile, "col")
		assert_has_key(tile, "row")
		assert_true(tile.col is int, "col must be int")
		assert_true(tile.row is int, "row must be int")


# ---------------------------------------------------------------------------
# Property 5: Missing/invalid input → correct error codes
##
## Validates: Requirements 1.2, 1.3, 1.4, 1.6, 7.2
##
## - empty path → MISSING_REQUIRED_PARAM
## - nonexistent path → RESOURCE_NOT_FOUND with path in message
## - source_id = -1 → VALUE_OUT_OF_RANGE without unhandled exception
# ---------------------------------------------------------------------------

func test_property_error_codes_empty_path_variants() -> void:
	## Both empty string and absent key must return MISSING_REQUIRED_PARAM
	## (no unhandled exception)
	var r1 := _handler.get_atlas_tiles({"tileset_path": "", "source_id": 0})
	assert_is_error(r1, ErrorCodes.MISSING_REQUIRED_PARAM)

	var r2 := _handler.get_atlas_tiles({"source_id": 0})
	assert_is_error(r2, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_property_error_codes_nonexistent_paths() -> void:
	## Several non-existent res:// paths → RESOURCE_NOT_FOUND, path in message
	var nonexistent_paths := [
		"res://does_not_exist.tres",
		"res://some/deep/path/nope.tres",
		"res://atlas_test_nonexistent_xyz123.tres",
	]
	for p in nonexistent_paths:
		var result := _handler.get_atlas_tiles({"tileset_path": p, "source_id": 0})
		assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)
		assert_contains(result.error.message, p,
			"RESOURCE_NOT_FOUND message must contain the path")


func test_property_error_codes_negative_source_id_no_exception() -> void:
	## source_id = -1 → VALUE_OUT_OF_RANGE, no unhandled GDScript exception
	## The test itself completing without crash validates the "no exception" part.
	var ts := _make_tileset_with_source([Vector2i(0, 0)])
	var path := _save_temp_resource(ts, "tileset_prop5_neg.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": -1})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_property_error_codes_multiple_invalid_source_ids_no_exception() -> void:
	## Various out-of-range source_id values all return VALUE_OUT_OF_RANGE cleanly
	## Validates: Requirement 7.2 — no unhandled exception for any invalid input
	var ts := _make_tileset_with_source([Vector2i(0, 0)])
	var path := _save_temp_resource(ts, "tileset_prop5_multi.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return
	var invalid_ids := [-1, -100, 1, 2, 999, 1000]
	for sid in invalid_ids:
		var result := _handler.get_atlas_tiles({"tileset_path": path, "source_id": sid})
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE,
			"source_id=%d must return VALUE_OUT_OF_RANGE" % sid)


# ---------------------------------------------------------------------------
# Atlas image tests
# ---------------------------------------------------------------------------

func test_get_atlas_image_returns_png_payload() -> void:
	var ts := _make_tileset_with_source([Vector2i(0, 0)])
	var path := _save_temp_resource(ts, "tileset_image_payload.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return

	var result := _handler.get_atlas_image({"tileset_path": path, "source_id": 0})
	assert_has_key(result, "data")
	assert_has_key(result.data, "image_base64")
	assert_has_key(result.data, "width")
	assert_has_key(result.data, "height")
	assert_has_key(result.data, "original_width")
	assert_has_key(result.data, "original_height")
	assert_has_key(result.data, "format")
	assert_eq(result.data.width, 64)
	assert_eq(result.data.height, 64)
	assert_eq(result.data.original_width, 64)
	assert_eq(result.data.original_height, 64)
	assert_eq(result.data.format, "png")

	var png_bytes := Marshalls.base64_to_raw(result.data.image_base64)
	assert_true(not png_bytes.is_empty(), "image_base64 must decode to non-empty PNG bytes")


func test_get_atlas_image_respects_max_size() -> void:
	var ts := _make_tileset_with_source([Vector2i(0, 0)])
	var path := _save_temp_resource(ts, "tileset_image_max_size.tres")
	if path.is_empty():
		skip("Could not save temporary resource")
		return

	var result := _handler.get_atlas_image({
		"tileset_path": path,
		"source_id": 0,
		"max_size": 16,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.original_width, 64)
	assert_eq(result.data.original_height, 64)
	assert_true(result.data.width <= 16, "scaled width must be <= max_size")
	assert_true(result.data.height <= 16, "scaled height must be <= max_size")
