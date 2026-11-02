@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const Fixture := preload("res://tests/mcp_tool_node_fixture.gd")
const SAVE_PATH := "res://tests/_custom_node_array_roundtrip.tscn"

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _root: Node
var _holder: Node3D
var _good: Node
var _derived: Node
var _path: String


func suite_name() -> String:
	return "script_node_arrays"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.undo_redo
	_handler = NodeHandler.new(_undo_redo)
	_root = EditorInterface.get_edited_scene_root()


func setup() -> void:
	_holder = Node3D.new()
	_holder.name = "_CustomNodeArray"
	var holder_script := GDScript.new()
	holder_script.source_code = "@tool\nextends Node3D\n@export var targets: Array[McpToolNodeFixture] = []\n"
	assert_eq(holder_script.reload(), OK)
	_holder.set_script(holder_script)
	_root.add_child(_holder)
	_holder.owner = _root
	_path = McpScenePath.from_node(_holder, _root)
	_good = Fixture.new()
	_good.name = "Good"
	_holder.add_child(_good)
	_good.owner = _holder
	var derived_script := GDScript.new()
	derived_script.source_code = "@tool\nextends McpToolNodeFixture\n"
	assert_eq(derived_script.reload(), OK)
	_derived = derived_script.new()
	_derived.name = "Derived"
	_holder.add_child(_derived)
	_derived.owner = _holder
	var wrong_script := GDScript.new()
	wrong_script.source_code = "@tool\nextends Node\n"
	assert_eq(wrong_script.reload(), OK)
	var wrong: Node = wrong_script.new()
	wrong.name = "Wrong"
	_holder.add_child(wrong)
	wrong.owner = _holder


func teardown() -> void:
	_root.remove_child(_holder)
	_holder.queue_free()
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)


func _set_targets(value: Array) -> Dictionary:
	return _handler.set_property({"path": _path, "property": "targets", "value": value})


func _assert_targets(value: Array, first: Node, second: Node) -> void:
	assert_eq(value.size(), 4)
	assert_eq(value.get_typed_script(), Fixture)
	if value.size() != 4:
		return
	assert_true(value[0] == first, "first stored node identity")
	assert_true(value[1] == second, "subclass stored node identity")
	assert_true(value[2] == null, "null input remains null")
	assert_true(value[3] == null, "empty string becomes null")


func test_custom_class_and_subclass_paths_preserve_type_and_readback() -> void:
	var result := _set_targets([_path + "/Good", "Derived", null, ""])
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	_assert_targets(_holder.get("targets"), _good, _derived)
	assert_eq(result.data.old_value, [])
	assert_eq(result.data.value, [_path + "/Good", _path + "/Derived", null, null])
	var readback := _handler.get_node_properties({"path": _path, "fields": ["targets"]})
	assert_eq(readback.data.properties.size(), 1)
	assert_eq(readback.data.properties[0].value, result.data.value)


func test_invalid_custom_node_element_refuses_whole_write_and_undo() -> void:
	assert_has_key(_set_targets(["Good", "Derived", null, ""]), "data")
	var history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_root))
	var version := history.get_version()
	for row in [
		["Wrong", McpErrorCodes.WRONG_TYPE],
		["Missing", McpErrorCodes.NODE_NOT_FOUND],
		["../..", McpErrorCodes.INVALID_PARAMS],
	]:
		var rejected := _set_targets(["Derived", row[0]])
		assert_is_error(rejected, row[1])
		assert_contains(rejected.error.message, "element 1")
		_assert_targets(_holder.get("targets"), _good, _derived)
		assert_eq(history.get_version(), version, "invalid element must not commit an undo action")


func test_custom_node_array_undo_redo_and_empty_clear() -> void:
	assert_has_key(_set_targets(["Good", "Derived", null, ""]), "data")
	assert_true(editor_undo(_undo_redo))
	assert_eq((_holder.get("targets") as Array).size(), 0)
	assert_eq((_holder.get("targets") as Array).get_typed_script(), Fixture)
	assert_true(editor_redo(_undo_redo))
	_assert_targets(_holder.get("targets"), _good, _derived)
	var cleared := _set_targets([])
	assert_eq(cleared.data.value, [])
	assert_eq((_holder.get("targets") as Array).size(), 0)
	assert_eq((_holder.get("targets") as Array).get_typed_script(), Fixture)
	assert_true(editor_undo(_undo_redo))
	_assert_targets(_holder.get("targets"), _good, _derived)


func test_custom_node_array_references_survive_disk_reload() -> void:
	assert_has_key(_set_targets(["Good", "Derived", null, ""]), "data")
	var packed := PackedScene.new()
	assert_eq(packed.pack(_holder), OK)
	assert_eq(ResourceSaver.save(packed, SAVE_PATH), OK)
	var loaded: PackedScene = ResourceLoader.load(SAVE_PATH, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var restored := loaded.instantiate()
	_assert_targets(restored.get("targets"), restored.get_node("Good"), restored.get_node("Derived"))
	assert_eq(restored.get_node("Derived").get_script().get_base_script(), Fixture)
	restored.free()


func test_repeated_nested_array_aliases_serialize_independently() -> void:
	var nested := [_good]
	assert_eq(NodeHandler._serialize_slot([nested, nested], _root), [[_path + "/Good"], [_path + "/Good"]])
