@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const Fixture := preload("res://tests/fixtures/packed_bytes_node.gd")
const SAVED_PATH := "res://tests/_packed_bytes_roundtrip.tscn"
const RESOURCE_PATH := "res://tests/_packed_bytes_roundtrip.tres"

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _root: Node
var _node: Node
var _path: String


func suite_name() -> String:
	return "packed_bytes"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.undo_redo
	_handler = NodeHandler.new(_undo_redo)
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		skip_suite("No scene open")


func setup() -> void:
	_node = Fixture.new()
	_node.name = "_PackedBytes"
	_root.add_child(_node)
	_node.owner = _root
	_path = McpScenePath.from_node(_node, _root)


func teardown() -> void:
	_root.remove_child(_node)
	_node.queue_free()
	for path in [SAVED_PATH, RESOURCE_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _write(value: Variant, property: String = "bytes") -> Dictionary:
	return _handler.set_property({"path": _path, "property": property, "value": value})


func test_byte_write_readback_undo_and_empty() -> void:
	var result := _write(JSON.parse_string("[0, 128, 255]"))
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(_node.bytes, PackedByteArray([0, 128, 255]))
	assert_eq(result.data.value, [0, 128, 255])
	assert_eq(result.data.old_value, [7, 8])
	assert_true(result.data.undoable)
	assert_true(editor_undo(_undo_redo))
	assert_eq(_node.bytes, PackedByteArray([7, 8]))
	assert_true(editor_redo(_undo_redo))
	assert_eq(_node.bytes, PackedByteArray([0, 128, 255]))
	assert_eq(_write([]).data.value, [])
	assert_eq(_node.bytes, PackedByteArray())


func test_invalid_bytes_leave_value_and_undo_unchanged() -> void:
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	for value in [[1, -1], [1, 256], [1, 1.5], [1, true], [1, "2"], [1, null], [1, INF], [1, NAN], "AAE=", {"bytes": [1]}, null]:
		var result := _write(value)
		assert_has_key(result, "error", "invalid byte input must fail: %s" % str(value))
		assert_eq(_node.bytes, PackedByteArray([7, 8]))
		assert_eq(history.get_version(), version)


func test_byte_limit_accepts_boundary_and_refuses_oversize() -> void:
	var bytes: Array = []
	bytes.resize(65536)
	bytes.fill(255)
	var result := _write(bytes)
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(_node.bytes.size(), 65536)
	assert_eq(_node.bytes[0], 255)
	assert_eq(_node.bytes[65535], 255)
	bytes.append(0)
	var refused := _write(bytes)
	assert_is_error(refused, McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(refused.error.message, "65536")
	assert_eq(_node.bytes.size(), 65536)
	assert_true(editor_undo(_undo_redo))
	assert_eq(_node.bytes, PackedByteArray([7, 8]), "oversized write must not create an undo entry")


func test_typed_containers_stage_all_byte_elements_before_mutation() -> void:
	var result := _write([[0, 255], []], "arrays")
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(_node.arrays[0], PackedByteArray([0, 255]))
	assert_eq(_node.arrays[1], PackedByteArray())
	assert_has_key(_write([[3], [4, 256]], "arrays"), "error")
	assert_eq(_node.arrays[0], PackedByteArray([0, 255]))
	assert_eq(_node.arrays[1], PackedByteArray())
	assert_has_key(_write({"first": [0], "last": [255]}, "mapping"), "data")
	assert_eq(_node.mapping.first, PackedByteArray([0]))
	assert_eq(_node.mapping.last, PackedByteArray([255]))
	assert_has_key(_write({"first": [5], "bad": [false]}, "mapping"), "error")
	assert_eq(_node.mapping.first, PackedByteArray([0]))
	assert_eq(_node.mapping.last, PackedByteArray([255]))
	assert_false(_node.mapping.has("bad"))


func test_byte_values_survive_scene_save_and_reload() -> void:
	var result := _write([0, 128, 255])
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	var packed := PackedScene.new()
	assert_eq(packed.pack(_node), OK)
	assert_eq(ResourceSaver.save(packed, SAVED_PATH), OK)
	var loaded: PackedScene = ResourceLoader.load(SAVED_PATH, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var restored := loaded.instantiate()
	assert_eq(restored.bytes, PackedByteArray([0, 128, 255]))
	restored.free()


func test_resource_byte_creation_and_invalid_inline_assignment() -> void:
	var resources := ResourceHandler.new(_undo_redo)
	var made := resources.create_resource({"type": "AudioStreamWAV", "resource_path": RESOURCE_PATH, "properties": {"data": [0, 128, 255]}})
	assert_has_key(made, "data")
	if not made.has("data"):
		return
	var loaded: AudioStreamWAV = ResourceLoader.load(RESOURCE_PATH, "AudioStreamWAV", ResourceLoader.CACHE_MODE_IGNORE)
	assert_eq(loaded.data, PackedByteArray([0, 128, 255]))
	var saved := FileAccess.get_file_as_bytes(RESOURCE_PATH)
	var invalid := resources.create_resource({"type": "AudioStreamWAV", "resource_path": RESOURCE_PATH, "overwrite": true, "properties": {"mix_rate": 22050, "data": [0, 256]}})
	assert_is_error(invalid, McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_eq(FileAccess.get_file_as_bytes(RESOURCE_PATH), saved, "invalid bytes must not overwrite the saved resource")
	var player := AudioStreamPlayer.new()
	_node.add_child(player)
	player.owner = _root
	var player_path := McpScenePath.from_node(player, _root)
	var assigned := _handler.set_property({"path": player_path, "property": "stream", "value": {"__class__": "AudioStreamWAV", "data": [0, 255]}})
	assert_has_key(assigned, "data")
	if not assigned.has("data"):
		return
	var original := player.stream
	assert_eq(original.data, PackedByteArray([0, 255]))
	var rejected := _handler.set_property({"path": player_path, "property": "stream", "value": {"__class__": "AudioStreamWAV", "data": [0, 256]}})
	assert_is_error(rejected, McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_eq(player.stream, original)
	assert_eq(player.stream.data, PackedByteArray([0, 255]))


func test_tilemap_native_byte_data_roundtrip() -> void:
	var layer := TileMapLayer.new()
	_node.add_child(layer)
	layer.owner = _root
	layer.set_cell(Vector2i(3, -2), 7, Vector2i(1, 2), 4)
	var bytes: PackedByteArray = layer.tile_map_data
	assert_gt(bytes.size(), 0)
	layer.clear()
	var result := _handler.set_property({"path": McpScenePath.from_node(layer, _root), "property": "tile_map_data", "value": Array(bytes)})
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(layer.get_cell_source_id(Vector2i(3, -2)), 7)
	assert_eq(layer.get_cell_atlas_coords(Vector2i(3, -2)), Vector2i(1, 2))
	assert_eq(layer.get_cell_alternative_tile(Vector2i(3, -2)), 4)
	assert_true(editor_undo(_undo_redo))
	assert_eq(layer.get_used_cells().size(), 0)
