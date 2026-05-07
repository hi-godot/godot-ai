@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const SceneHandler := preload("res://addons/godot_ai/handlers/scene_handler.gd")

## Tests for SceneHandler — scene tree reading and node search.
## Runs against the test_project main.tscn scene:
##   Main (Node3D)
##     Camera3D
##     DirectionalLight3D
##     World (Node3D)
##       Ground (MeshInstance3D)
##     TriggerZone (Area3D)

var _handler: SceneHandler

class SaveSpy:
	extends RefCounted

	var save_called := false
	var save_as_called := false
	var save_as_path := ""

	func save_scene() -> int:
		save_called = true
		return OK

	func save_scene_as(path: String) -> void:
		save_as_called = true
		save_as_path = path


func suite_name() -> String:
	return "scene"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = SceneHandler.new()


# ----- get_scene_tree -----

func test_scene_tree_returns_data() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	assert_has_key(result, "data")
	assert_has_key(result.data, "nodes")
	assert_has_key(result.data, "total_count")


func test_scene_tree_root_is_main() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	var nodes: Array = result.data.nodes
	assert_gt(nodes.size(), 0, "Should have at least one node")
	assert_eq(nodes[0].name, "Main", "Root node should be Main")
	assert_eq(nodes[0].type, "Node3D", "Root should be Node3D")


func test_scene_tree_contains_expected_nodes() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	var names: Array[String] = []
	for node: Dictionary in result.data.nodes:
		names.append(node.name)
	assert_contains(names, "Camera3D")
	assert_contains(names, "DirectionalLight3D")
	assert_contains(names, "World")
	assert_contains(names, "Ground")
	assert_contains(names, "TriggerZone")


func test_scene_tree_depth_zero_returns_only_root() -> void:
	var result := _handler.get_scene_tree({"depth": 0})
	assert_eq(result.data.nodes.size(), 1, "Depth 0 should return only root")
	assert_eq(result.data.nodes[0].name, "Main")


func test_scene_tree_depth_one_excludes_grandchildren() -> void:
	var result := _handler.get_scene_tree({"depth": 1})
	var names: Array[String] = []
	for node: Dictionary in result.data.nodes:
		names.append(node.name)
	## Ground is a child of World (depth 2), should be excluded
	assert_true(not names.has("Ground"), "Depth 1 should not include Ground (depth 2)")
	assert_contains(names, "World", "Depth 1 should include World (depth 1)")


func test_scene_tree_node_has_path() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	var camera_node: Dictionary
	for node: Dictionary in result.data.nodes:
		if node.name == "Camera3D":
			camera_node = node
			break
	assert_eq(camera_node.path, "/Main/Camera3D")


# ----- get_open_scenes -----

func test_open_scenes_returns_current() -> void:
	var result := _handler.get_open_scenes({})
	assert_has_key(result, "data")
	assert_has_key(result.data, "scenes")
	assert_has_key(result.data, "current_scene")
	assert_gt(result.data.scenes.size(), 0, "Should have at least one open scene")


func test_open_scenes_current_is_main() -> void:
	var result := _handler.get_open_scenes({})
	assert_contains(result.data.current_scene, "main.tscn")


# ----- find_nodes -----

func test_find_by_type_mesh_instance() -> void:
	var result := _handler.find_nodes({"type": "MeshInstance3D"})
	assert_has_key(result, "data")
	assert_gt(result.data.count, 0, "Should find at least 1 MeshInstance3D")
	var names: Array = []
	for node in result.data.nodes:
		names.append(node.name)
	assert_true(names.has("Ground"), "Should include Ground MeshInstance3D")


func test_find_by_name_substring() -> void:
	var result := _handler.find_nodes({"name": "camera"})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 1, "Case-insensitive 'camera' should match Camera3D")
	assert_eq(result.data.nodes[0].name, "Camera3D")


func test_find_by_type_node3d() -> void:
	var result := _handler.find_nodes({"type": "Node3D"})
	var names: Array[String] = []
	for node: Dictionary in result.data.nodes:
		names.append(node.name)
	assert_contains(names, "Main")
	assert_contains(names, "World")


func test_find_no_filters_returns_error() -> void:
	var result := _handler.find_nodes({})
	assert_is_error(result)


func test_find_nonexistent_type_returns_empty() -> void:
	var result := _handler.find_nodes({"type": "AudioStreamPlayer3D"})
	assert_has_key(result, "data")
	assert_eq(result.data.count, 0)


# ----- create_scene (validation only — full create switches scenes, not safe in test runner) -----

func test_create_scene_missing_path() -> void:
	var result := _handler.create_scene({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_create_scene_invalid_root_type() -> void:
	var result := _handler.create_scene({"path": "res://test.tscn", "root_type": "NotAType"})
	assert_is_error(result)


func test_create_scene_non_node_root_type() -> void:
	var result := _handler.create_scene({"path": "res://test.tscn", "root_type": "Resource"})
	assert_is_error(result)


func test_create_scene_invalid_path_prefix() -> void:
	var result := _handler.create_scene({"path": "/tmp/scene.tscn"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


# ----- open_scene (validation only — opening scenes triggers UI that blocks test runner) -----

func test_open_scene_missing_path() -> void:
	var result := _handler.open_scene({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_open_scene_nonexistent() -> void:
	var result := _handler.open_scene({"path": "res://does_not_exist.tscn"})
	assert_is_error(result)


# ----- save_scene / save_scene_as (validation only — save triggers modal dialog) -----

func test_save_scene_never_saved_returns_actionable_validation_error() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var original_path := scene_root.scene_file_path
	var spy := SaveSpy.new()
	_handler._save_scene_callable = spy.save_scene
	scene_root.scene_file_path = ""

	var result := _handler.save_scene({})

	scene_root.scene_file_path = original_path
	_handler._save_scene_callable = Callable()

	assert_is_error(result)
	assert_false(spy.save_called, "scene_save must not call EditorInterface.save_scene() without a scene path")
	# Recovery hint must point at the published MCP tool surface
	# (scene_manage(op='save_as')), not a non-existent `scene_save_as`
	# top-level tool. Hint must also acknowledge both supported scene
	# extensions (.tscn and .scn) since save_scene_as accepts either.
	assert_contains(result.error.message, "scene_manage(op='save_as')")
	assert_contains(result.error.message, "res://")
	assert_contains(result.error.message, ".tscn")
	assert_contains(result.error.message, ".scn")


func test_save_scene_succeeds_for_saved_scene() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return
	if scene_root.scene_file_path.is_empty():
		skip("Current scene has no path")
		return

	var spy := SaveSpy.new()
	_handler._save_scene_callable = spy.save_scene

	var result := _handler.save_scene({})

	_handler._save_scene_callable = Callable()

	assert_has_key(result, "data")
	assert_true(spy.save_called, "scene_save should save when the scene already has a path")
	assert_eq(result.data.path, scene_root.scene_file_path)


func test_save_scene_as_supports_never_saved_scene() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene open")
		return

	var original_path := scene_root.scene_file_path
	var spy := SaveSpy.new()
	var path := "res://tmp/mcp_scene_save_as_from_unsaved.tscn"
	_handler._save_scene_as_callable = spy.save_scene_as
	scene_root.scene_file_path = ""

	var result := _handler.save_scene_as({"path": path})

	scene_root.scene_file_path = original_path
	_handler._save_scene_as_callable = Callable()

	assert_has_key(result, "data")
	assert_true(spy.save_as_called, "scene_save_as should remain available for scenes without a path")
	assert_eq(spy.save_as_path, path)
	assert_eq(result.data.path, path)


func test_save_scene_as_missing_path() -> void:
	var result := _handler.save_scene_as({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_save_scene_as_invalid_path_prefix() -> void:
	var result := _handler.save_scene_as({"path": "/tmp/bad.tscn"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
