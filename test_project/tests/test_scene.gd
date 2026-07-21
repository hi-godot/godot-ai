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


const _UID_SCENE_FIXTURE_PATH := "res://tests/_mcp_test_uid_scene.tscn"


func suite_teardown() -> void:
	# Guarantees cleanup even if test_create_scene_embeds_and_preserves_uid
	# fails or aborts partway through, rather than relying on the assertion
	# flow to reach its own cleanup line.
	if FileAccess.file_exists(_UID_SCENE_FIXTURE_PATH):
		var remove_err := DirAccess.remove_absolute(ProjectSettings.globalize_path(_UID_SCENE_FIXTURE_PATH))
		if remove_err != OK:
			push_warning("MCP test cleanup: failed to remove %s: %s" % [_UID_SCENE_FIXTURE_PATH, error_string(remove_err)])


# ----- get_scene_tree -----

func test_scene_tree_returns_data() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	assert_has_key(result, "data")
	assert_has_key(result.data, "nodes")
	assert_has_key(result.data, "total_count")


func test_scene_tree_no_limit_returns_all() -> void:
	var result := _handler.get_scene_tree({"depth": 10})
	## No limit -> full tree, has_more false, nodes count equals total_count.
	assert_eq(result.data.nodes.size(), result.data.total_count)
	assert_false(result.data.has_more, "Unlimited read has nothing more")
	assert_eq(result.data.offset, 0)


func test_scene_tree_limit_windows_nodes_and_reports_total() -> void:
	var full := _handler.get_scene_tree({"depth": 10})
	var total: int = full.data.total_count
	assert_gt(total, 2, "test scene needs >2 nodes to exercise paging")
	var page := _handler.get_scene_tree({"depth": 10, "limit": 2})
	assert_eq(page.data.nodes.size(), 2, "limit caps the returned window")
	## total_count reflects the whole tree, not the returned window.
	assert_eq(page.data.total_count, total)
	assert_eq(page.data.limit, 2)
	assert_true(page.data.has_more, "More nodes remain past a 2-node window")


func test_scene_tree_offset_skips_leading_nodes() -> void:
	var full := _handler.get_scene_tree({"depth": 10})
	## DFS order is stable, so offset 1 drops the root and starts at its first
	## walked descendant.
	var offset_page := _handler.get_scene_tree({"depth": 10, "offset": 1, "limit": 1})
	assert_eq(offset_page.data.nodes.size(), 1)
	assert_eq(offset_page.data.offset, 1)
	assert_eq(offset_page.data.nodes[0].name, full.data.nodes[1].name)


func test_scene_tree_offset_past_end_returns_empty_window() -> void:
	var full := _handler.get_scene_tree({"depth": 10})
	var beyond := _handler.get_scene_tree({"depth": 10, "offset": full.data.total_count + 5, "limit": 10})
	assert_eq(beyond.data.nodes.size(), 0, "offset past the end yields no nodes")
	assert_eq(beyond.data.total_count, full.data.total_count, "total_count still reflects the full tree")
	assert_false(beyond.data.has_more)


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


func test_scene_tree_full_read_builds_clean_scene_paths() -> void:
	## Full reads (limit <= 0) build paths by threading the prefix down the DFS.
	## Pin the exact format against the known fixture, including a nested node.
	var result := _handler.get_scene_tree({"depth": 10})
	var path_by_name := {}
	for node: Dictionary in result.data.nodes:
		path_by_name[node.name] = node.path
	assert_eq(path_by_name["Main"], "/Main", "root path")
	assert_eq(path_by_name["Camera3D"], "/Main/Camera3D", "direct child path")
	assert_eq(path_by_name["Ground"], "/Main/World/Ground", "nested descendant path")


func test_scene_tree_full_and_paginated_paths_agree() -> void:
	## The full read threads the prefix down the DFS; a paginated read (limit > 0)
	## builds paths via McpScenePath.from_node. The two strategies must produce
	## byte-identical node dicts — this is what makes the perf branch safe.
	var full := _handler.get_scene_tree({"depth": 10})
	var total: int = full.data.total_count
	var paged := _handler.get_scene_tree({"depth": 10, "limit": total})
	assert_eq(paged.data.nodes.size(), full.data.nodes.size(), "same node count")
	for i in full.data.nodes.size():
		assert_eq(full.data.nodes[i].path, paged.data.nodes[i].path,
			"path mismatch at index %d (full vs paginated)" % i)
		assert_eq(full.data.nodes[i].name, paged.data.nodes[i].name)
		assert_eq(full.data.nodes[i].type, paged.data.nodes[i].type)


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


func test_create_scene_rejects_traversal() -> void:
	## create_scene now routes through McpPathValidator — a traversal payload
	## that escapes the project root must be rejected (audit GH-1).
	var result := _handler.create_scene({"path": "res://../evil.tscn"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_scene_rejects_project_godot_overwrite() -> void:
	## Write blocklist (audit GH-3): refuse clobbering the project manifest.
	var result := _handler.create_scene({"path": "res://project.godot"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_create_scene_embeds_and_preserves_uid() -> void:
	## #737 regression. Calls SceneHandler._pack_and_save_with_uid() directly
	## — the real save+uid sequence create_scene runs — rather than
	## create_scene() itself: per this section's header comment, a full
	## create switches the editor's active scene and isn't safe inside the
	## shared test runner. This exercises production code (not a duplicated
	## reimplementation), just without create_scene's
	## EditorInterface.open_scene_from_path side effect. create_scene's own
	## end-to-end wiring was additionally verified live against a running
	## editor (scene_manage(op="create"), then a same-path recreate) during
	## development of this fix. Cleanup is guaranteed by suite_teardown()
	## even if an assertion below fails.
	var out_path := _UID_SCENE_FIXTURE_PATH
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))

	var root := Node3D.new()
	root.name = "UidProbeRoot"
	assert_eq(_handler._pack_and_save_with_uid(root, out_path), OK)
	var original_uid := ResourceLoader.get_resource_uid(out_path)
	assert_true(original_uid != ResourceUID.INVALID_ID, "freshly created scene must carry a uid")

	# Recreate at the same path — mirrors create_scene being pointed at an
	# existing scene path — and confirm the original uid survives.
	var root2 := Node3D.new()
	root2.name = "UidProbeRootV2"
	assert_eq(_handler._pack_and_save_with_uid(root2, out_path), OK)
	assert_eq(ResourceLoader.get_resource_uid(out_path), original_uid,
		"overwriting a scene at the same path must preserve its original uid")


# ----- open_scene (validation only — opening scenes triggers UI that blocks test runner) -----

func test_open_scene_missing_path() -> void:
	var result := _handler.open_scene({})
	assert_is_error(result, ErrorCodes.MISSING_REQUIRED_PARAM)


func test_open_scene_nonexistent() -> void:
	var result := _handler.open_scene({"path": "res://does_not_exist.tscn"})
	assert_is_error(result)


func test_open_scene_already_current_reports_switched() -> void:
	## #633: opening the scene that is already edited must not go through the
	## async switch path — it replies immediately with switched=true. This is
	## also the only open_scene success path testable synchronously (opening a
	## different scene triggers UI that blocks the test runner).
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or scene_root.scene_file_path.is_empty():
		skip("No saved scene open")
		return
	var current := scene_root.scene_file_path
	var result := _handler.open_scene({"path": current})
	assert_has_key(result, "data")
	assert_eq(result.data.switched, true, "already-current open is switched")
	assert_eq(result.data.settle, "already_current")
	assert_eq(result.data.previous_scene_path, current)


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
