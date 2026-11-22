@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const INSTANCE_NAME := "Placed"

class PlacementPathErrors extends Logger:
	var _mutex := Mutex.new()
	var _seen := false

	func _log_error(
		function: String, _file: String, _line: int, code: String, rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array,
	) -> void:
		if function == "get_path_to" and "No path can be resolved" in (code + rationale):
			_mutex.lock()
			_seen = true
			_mutex.unlock()

	func was_reported() -> bool:
		_mutex.lock()
		var seen := _seen
		_mutex.unlock()
		return seen

var _handler: NodeHandler
var _root: Node
var _history: UndoRedo
var _global_history: UndoRedo
var _before_version: int
var _directory := ""
var _files: Array[String] = []
var _source_2d := ""
var _source_3d := ""
var _top_2d := ""
var _top_3d := ""
var _plain := ""
var _path_errors: PlacementPathErrors


func suite_name() -> String:
	return "instance_placement"


func suite_setup(ctx: Dictionary) -> void:
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		skip_suite("Instance placement requires an edited scene")
		return
	var undo: EditorUndoRedoManager = ctx.undo_redo
	_handler = NodeHandler.new(undo)
	_history = undo.get_history_undo_redo(undo.get_object_history_id(_root))
	_global_history = undo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	_directory = "res://tests/_mcp_test_placement_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_absolute(_directory) != OK:
		fail_setup("Could not create temporary scene fixture directory")
		return
	_source_2d = _save_2d("Saved2D", false)
	_source_3d = _save_3d("Saved3D", false)
	_top_2d = _save_2d("Top2D", true)
	_top_3d = _save_3d("Top3D", true)
	_plain = _save_fixture(Node.new(), "Plain")
	if "" in [_source_2d, _source_3d, _top_2d, _top_3d, _plain]:
		fail_setup("Could not pack and write temporary placement fixtures")


func setup() -> void:
	_before_version = _history.get_version()


func teardown() -> void:
	if _path_errors != null:
		OS.remove_logger(_path_errors)
		_path_errors = null
	# Undo only actions from this test, before the runner frees its tracked parent.
	while _history.get_version() > _before_version:
		if not _history.undo():
			break


func suite_teardown() -> void:
	for path in _files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if not _directory.is_empty() and DirAccess.dir_exists_absolute(_directory):
		DirAccess.remove_absolute(_directory)


func _save_2d(name: String, top_level: bool) -> String:
	var source := Node2D.new()
	source.top_level = top_level
	source.transform = _authored_2d()
	return _save_fixture(source, name)


func _save_3d(name: String, top_level: bool) -> String:
	var source := Node3D.new()
	source.top_level = top_level
	source.transform = _authored_3d()
	return _save_fixture(source, name)


func _save_fixture(source: Node, name: String) -> String:
	source.name = name
	var marker := Node.new()
	marker.name = "Marker"
	source.add_child(marker)
	marker.owner = source
	var packed := PackedScene.new()
	var error := packed.pack(source)
	source.free()
	if error != OK:
		return ""
	var path := _directory.path_join(name + ".tscn")
	_files.append(path)
	return path if ResourceSaver.save(packed, path) == OK else ""


func _write_fixture(filename: String, text: String) -> String:
	var path := _directory.path_join(filename)
	_files.append(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "Open the temporary fixture %s" % filename)
	if file == null:
		return ""
	file.store_string(text)
	file.close()
	return path


func _authored_2d() -> Transform2D:
	return Transform2D(deg_to_rad(24.0), Vector2(1.25, 0.625), 0.0, Vector2(7.0, -3.0))


func _authored_3d() -> Transform3D:
	return _pose_3d(Vector3(7, -3, 2), Vector3(19, 24, -12), Vector3(1.25, 0.625, 1.75))


func _pose_3d(position: Vector3, degrees: Vector3, scale: Vector3) -> Transform3D:
	var rotation := Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))
	return Transform3D(Basis.from_euler(rotation).scaled_local(scale), position)


func _attach(parent: Node, node: Node, requested_name: String) -> void:
	track(node)
	node.name = requested_name
	parent.add_child(node, true)
	node.owner = _root


func _parent_2d(scale: Vector2) -> Node2D:
	var parent := Node2D.new()
	parent.transform = Transform2D(deg_to_rad(37.0), scale, 0.0, Vector2(-12.0, 43.0))
	_attach(_root, parent, "_McpTestPlacement2D")
	return parent


func _parent_3d(scale: Vector3) -> Node3D:
	var parent := Node3D.new()
	parent.transform = _pose_3d(Vector3(-12, 43, 5), Vector3(12, 37, -16), scale)
	_attach(_root, parent, "_McpTestPlacement3D")
	return parent


func _params(parent: Node, source: String, overrides: Dictionary) -> Dictionary:
	return {
		"parent_path": McpScenePath.from_node(parent, _root), "scene_path": source, "name": INSTANCE_NAME,
	}.merged(overrides, true)


func _instantiate(parent: Node, source: String, overrides: Dictionary = {}, allow_renamed: bool = false) -> Node:
	var result := _handler.instantiate_scene(_params(parent, source, overrides))
	assert_has_key(result, "data", "instantiate_scene failed: %s" % result)
	if not result.has("data"):
		return null
	var data: Dictionary = result.data
	assert_eq(data.get("scene_path"), source)
	assert_eq(data.get("parent_path"), McpScenePath.from_node(parent, _root))
	assert_eq(data.get("undoable"), true)
	var name := String(data.get("name", ""))
	if not allow_renamed:
		assert_eq(name, String(overrides.get("name", INSTANCE_NAME)))
	var node := parent.get_node_or_null(NodePath(name))
	assert_true(node != null, "The returned sibling name must identify an actual child")
	if node != null:
		assert_eq(data.get("path"), McpScenePath.from_node(node, _root))
		assert_eq(data.get("type"), node.get_class())
	return node


func _assert_link(node: Node, source: String) -> void:
	assert_eq(node.scene_file_path, source, "The PackedScene link is preserved")
	assert_eq(node.owner, _root, "The edited scene owns the new instance root")
	var marker := node.get_node_or_null("Marker")
	assert_true(marker != null, "The source-owned marker is present")
	if marker != null:
		assert_eq(marker.owner, node, "The marker remains owned by the instance")


func _assert_refused(parent: Node, source: String, overrides: Dictionary, code: String = "") -> Dictionary:
	var scene_version := _history.get_version()
	var global_version := _global_history.get_version()
	var siblings := parent.get_children()
	var root_children := _root.get_children()
	var result := _handler.instantiate_scene(_params(parent, source, overrides))
	assert_is_error(result, code, "Invalid placement did not return the expected error: %s" % result)
	assert_eq(parent.get_children(), siblings, "Refused placement changed the target's children")
	assert_eq(_root.get_children(), root_children, "Refused placement changed the edited scene")
	assert_eq(_history.get_version(), scene_version, "Refusal must not register a scene undo action")
	assert_eq(_global_history.get_version(), global_version, "Refusal must not register a global undo action")
	return result


func test_local_2d_placement_preserves_link_and_one_undo_action() -> void:
	var parent := _parent_2d(Vector2(2.5, 0.6))
	_path_errors = PlacementPathErrors.new()
	OS.add_logger(_path_errors)
	var source_hash := FileAccess.get_sha256(_source_2d)
	var global_version := _global_history.get_version()
	var expected := Transform2D(deg_to_rad(-32.0), Vector2(0.8, 1.4), 0.0, Vector2(18.0, -7.0))
	var placed := _instantiate(parent, _source_2d, {
		"scene_file": _root.scene_file_path, "position": {"x": 18, "y": -7},
		"rotation_degrees": -32, "scale": {"x": 0.8, "y": 1.4},
	}) as Node2D
	assert_true(placed != null)
	if placed == null:
		return
	assert_true(placed.transform.is_equal_approx(expected), "Local transform must match the request")
	assert_true(placed.global_transform.is_equal_approx(parent.global_transform * expected))
	_assert_link(placed, _source_2d)
	assert_eq(_global_history.get_version(), global_version)
	if not _assert_one_scene_action():
		return
	assert_true(_history.undo(), "One undo should remove the instance")
	assert_eq(_history.get_version(), _before_version)
	assert_eq(parent.get_child_count(), 0)
	assert_true(_history.redo(), "One redo should restore the instance")
	assert_eq(parent.get_node_or_null(INSTANCE_NAME), placed)
	if is_instance_valid(placed) and placed.is_inside_tree():
		assert_true(placed.transform.is_equal_approx(expected), "Redo restores the placement")
		_assert_link(placed, _source_2d)
	assert_false(_path_errors.was_reported(), "Placement and redo must avoid editor path bookkeeping before attachment")
	assert_eq(FileAccess.get_sha256(_source_2d), source_hash, "Placement never rewrites the source")


func _assert_one_scene_action() -> bool:
	var one_action := _history.get_version() == _before_version + 1
	assert_true(one_action, "Instantiation and placement must share exactly one scene undo action")
	return one_action


func test_world_2d_placement_applies_position_rotation_and_scale() -> void:
	var parent := _parent_2d(Vector2(2.0, 2.0))
	var expected := Transform2D(deg_to_rad(-23.0), Vector2(1.3, 0.7), 0.0, Vector2(30.0, -9.0))
	var placed := _instantiate(parent, _source_2d, {
		"space": "world", "position": {"x": 30, "y": -9},
		"rotation_degrees": -23, "scale": {"x": 1.3, "y": 0.7},
	}) as Node2D
	assert_true(placed != null)
	if placed != null:
		assert_true(placed.global_transform.is_equal_approx(expected))
		assert_true(placed.transform.is_equal_approx(parent.global_transform.affine_inverse() * expected))


func test_local_3d_placement_applies_position_rotation_and_scale() -> void:
	var parent := _parent_3d(Vector3(2.1, 0.8, 1.6))
	var expected := _pose_3d(Vector3(4, -5, 13), Vector3(9, -26, 34), Vector3(0.7, 1.6, 2.1))
	var placed := _instantiate(parent, _source_3d, {
		"space": "local", "position": {"x": 4, "y": -5, "z": 13},
		"rotation_degrees": {"x": 9, "y": -26, "z": 34}, "scale": {"x": 0.7, "y": 1.6, "z": 2.1},
	}) as Node3D
	assert_true(placed != null)
	if placed != null:
		assert_true(placed.transform.is_equal_approx(expected))
		assert_true(placed.global_transform.is_equal_approx(parent.global_transform * expected))


func test_world_3d_placement_applies_position_rotation_and_scale() -> void:
	var parent := _parent_3d(Vector3.ONE * 2.0)
	var expected := _pose_3d(Vector3(32, -7, 11), Vector3(-14, 49, 22), Vector3(0.9, 1.8, 1.1))
	var placed := _instantiate(parent, _source_3d, {
		"space": "world", "position": {"x": 32, "y": -7, "z": 11},
		"rotation_degrees": {"x": -14, "y": 49, "z": 22}, "scale": {"x": 0.9, "y": 1.8, "z": 1.1},
	}) as Node3D
	assert_true(placed != null)
	if placed != null:
		assert_true(placed.global_transform.is_equal_approx(expected))
		assert_true(placed.transform.is_equal_approx(parent.global_transform.affine_inverse() * expected))


func test_position_only_preserves_authored_basis_in_the_selected_space() -> void:
	var parent_2d := _parent_2d(Vector2(2.5, 0.6))
	var expected_2d := parent_2d.global_transform * _authored_2d()
	expected_2d.origin = Vector2(29.0, -13.0)
	var instance_2d := _instantiate(parent_2d, _source_2d, {
		"space": "world", "position": {"x": 29, "y": -13},
	}) as Node2D
	assert_true(instance_2d != null)
	if instance_2d != null:
		assert_true(instance_2d.global_transform.is_equal_approx(expected_2d), "World placement retains the full inherited basis")

	var parent_3d := _parent_3d(Vector3(2.1, 0.8, 1.6))
	var expected_3d := _authored_3d()
	expected_3d.origin = Vector3(29, -13, 26)
	var instance_3d := _instantiate(parent_3d, _source_3d, {"position": {"x": 29, "y": -13, "z": 26}}) as Node3D
	assert_true(instance_3d != null)
	if instance_3d != null:
		assert_true(instance_3d.transform.is_equal_approx(expected_3d), "Local placement retains the full authored basis")


func test_top_level_roots_use_their_independent_world_transform() -> void:
	var expected_2d := _authored_2d()
	expected_2d.origin = Vector2(15, -2)
	var placed_2d := _instantiate(_parent_2d(Vector2(2.5, 0.6)), _top_2d, {
		"space": "world", "position": {"x": 15, "y": -2},
	}) as Node2D
	assert_true(placed_2d != null)
	if placed_2d != null:
		assert_true(placed_2d.top_level)
		assert_true(placed_2d.global_transform.is_equal_approx(expected_2d))

	var expected_3d := _authored_3d()
	expected_3d.origin = Vector3(15, -2, 6)
	var placed_3d := _instantiate(_parent_3d(Vector3(2.1, 0.8, 1.6)), _top_3d, {
		"space": "world", "position": {"x": 15, "y": -2, "z": 6},
	}) as Node3D
	assert_true(placed_3d != null)
	if placed_3d != null:
		assert_true(placed_3d.top_level)
		assert_true(placed_3d.global_transform.is_equal_approx(expected_3d))


func test_plain_root_and_duplicate_name_use_actual_linked_sibling() -> void:
	var parent := _parent_3d(Vector3.ONE * 2.0)
	var existing := Node.new()
	_attach(parent, existing, INSTANCE_NAME)
	var placed := _instantiate(parent, _plain, {}, true)
	assert_true(placed != null)
	if placed == null:
		return
	assert_ne(placed, existing, "The duplicate name must produce a distinct instance")
	assert_ne(String(placed.name), INSTANCE_NAME)
	assert_eq(parent.get_node_or_null(INSTANCE_NAME), existing)
	assert_eq(placed.get_class(), "Node")
	_assert_link(placed, _plain)


func test_saved_placements_reload_as_independent_linked_instances() -> void:
	var parent := _parent_3d(Vector3(2.1, 0.8, 1.6))
	var first := _instantiate(parent, _source_3d, {
		"name": "First", "position": {"x": 8, "y": 12, "z": -3},
	}) as Node3D
	var second := _instantiate(parent, _source_3d, {
		"name": "Second", "position": {"x": -17, "y": 4, "z": 29},
	}) as Node3D
	assert_true(first != null and second != null)
	if first == null or second == null:
		return
	_assert_link(first, _source_3d)
	_assert_link(second, _source_3d)

	# Pack just the test subtree, with its authored children owned by the new
	# packed root. Restore their original owner before the test undoes placement.
	first.owner = parent
	second.owner = parent
	var packed := PackedScene.new()
	var packed_error := packed.pack(parent)
	first.owner = _root
	second.owner = _root
	assert_eq(packed_error, OK, "Pack the placed test subtree")
	if packed_error != OK:
		return
	var path := _directory.path_join("RoundTrip.tscn")
	_files.append(path)
	var saved_error := ResourceSaver.save(packed, path)
	assert_eq(saved_error, OK, "Save the placed test subtree")
	if saved_error != OK:
		return
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	assert_true(saved != null)
	if saved == null:
		return
	assert_eq(saved.get_state().get_node_count(), 3, "Only the host and two scene references should be stored")
	var restored := saved.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	track(restored)
	assert_true(restored != null)
	if restored == null:
		return
	var restored_first := restored.get_node_or_null("First") as Node3D
	var restored_second := restored.get_node_or_null("Second") as Node3D
	assert_true(restored_first != null and restored_second != null)
	if restored_first == null or restored_second == null:
		return
	for node: Node3D in [restored_first, restored_second]:
		assert_eq(node.scene_file_path, _source_3d)
		assert_eq(node.owner, restored)
		var marker := node.get_node_or_null("Marker")
		assert_true(marker != null)
		if marker != null:
			assert_eq(marker.owner, node)
	var first_transform := _authored_3d()
	first_transform.origin = Vector3(8, 12, -3)
	var second_transform := _authored_3d()
	second_transform.origin = Vector3(-17, 4, 29)
	assert_true(restored_first.transform.is_equal_approx(first_transform))
	assert_true(restored_second.transform.is_equal_approx(second_transform))


func test_rejects_invalid_shapes_and_plain_root_placement_without_mutation() -> void:
	var parent := _parent_2d(Vector2(2.5, 0.6))
	var transform_before := parent.transform
	for overrides in [
		{"space": "screen"}, {"space": false}, {"position": [1, 2]}, {"position": null},
		{"position": {"x": 1}}, {"position": {"x": 1, "y": 2, "z": 3}},
		{"position": {"x": NAN, "y": 2}}, {"position": {"x": true, "y": 2}},
		{"rotation_degrees": {"x": 0, "y": 0}}, {"rotation_degrees": "90"},
		{"scale": {"x": 2, "y": INF}},
	]:
		_assert_refused(parent, _source_2d, overrides)
	_assert_refused(parent, _source_3d, {"position": {"x": 1, "y": 2}})
	_assert_refused(parent, _source_3d, {"rotation_degrees": 45})
	_assert_refused(parent, _plain, {"position": {"x": 1, "y": 2}})
	_assert_refused(parent, "res://tests/not_a_real_scene.tscn", {}, ErrorCodes.RESOURCE_NOT_FOUND)
	_assert_refused(parent, _source_2d, {"parent_path": "/Missing/Parent"}, ErrorCodes.NODE_NOT_FOUND)
	assert_eq(parent.transform, transform_before)


func test_scene_file_guard_refuses_a_different_edited_scene() -> void:
	var parent := _parent_3d(Vector3.ONE)
	var active := _root.scene_file_path
	_assert_refused(parent, _source_3d, {"scene_file": _source_2d}, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_eq(EditorInterface.get_edited_scene_root(), _root)
	assert_eq(_root.scene_file_path, active)


func test_world_space_requires_an_invertible_parent() -> void:
	var parent := _parent_3d(Vector3(1, 0, 2))
	assert_eq(parent.global_transform.basis.determinant(), 0.0)
	var position := {"x": 17, "y": -6, "z": 12}
	_assert_refused(parent, _source_3d, {"space": "world", "position": position}, ErrorCodes.VALUE_OUT_OF_RANGE)
	var placed := _instantiate(parent, _source_3d, {"position": position}) as Node3D
	assert_true(placed != null)
	if placed != null:
		assert_eq(placed.position, Vector3(17, -6, 12))
		assert_true(placed.transform.basis.is_equal_approx(_authored_3d().basis))


func test_rejects_a_parent_outside_the_scene_or_without_scene_ownership() -> void:
	var editor_parent := _root.get_parent()
	assert_true(editor_parent != null, "The edited root is attached to the editor tree")
	if editor_parent == null:
		return
	var editor_children := editor_parent.get_children()
	assert_eq(McpScenePath.resolve("..", _root), editor_parent)
	_assert_refused(_root, _source_3d, {"parent_path": ".."}, ErrorCodes.NODE_NOT_FOUND)
	assert_eq(editor_parent.get_children(), editor_children)

	var transient := Node3D.new()
	track(transient)
	transient.name = "_McpTestOwnerlessPlacementParent"
	_root.add_child(transient)
	assert_eq(transient.owner, null)
	_assert_refused(transient, _source_3d, {}, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_eq(transient.owner, null)


func test_refuses_prepared_placement_after_target_identity_changes() -> void:
	var original := _parent_3d(Vector3.ONE)
	var expected := {"root": _root, "parent": original}
	var edited_path := _root.scene_file_path
	var params := _params(original, _plain, {})
	var parent_path: String = params.parent_path
	var packed := ResourceLoader.load(_plain, "PackedScene") as PackedScene
	assert_true(packed != null)
	if packed == null:
		return
	var name_before := String(original.name)
	_root.remove_child(original)
	var replacement := Node3D.new()
	_attach(_root, replacement, name_before)
	assert_eq(McpScenePath.from_node(replacement, _root), parent_path)
	var siblings := _root.get_children()
	var scene_version := _history.get_version()
	var global_version := _global_history.get_version()

	var parent_result := _handler._commit_prepared_instance(packed, _plain, params, {}, expected, edited_path, parent_path)
	assert_is_error(parent_result, ErrorCodes.NODE_NOT_FOUND)
	assert_contains(parent_result.get("error", {}).get("message", ""), "parent changed")
	var stale_root := Node.new()
	track(stale_root)
	stale_root.scene_file_path = edited_path
	stale_root.add_child(original)
	expected.root = stale_root
	var root_result := _handler._commit_prepared_instance(packed, _plain, params, {}, expected, edited_path, parent_path)
	assert_is_error(root_result, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_contains(root_result.get("error", {}).get("message", ""), "edited scene changed")

	assert_eq(_root.get_children(), siblings)
	assert_eq(replacement.get_child_count(), 0)
	assert_eq(_history.get_version(), scene_version)
	assert_eq(_global_history.get_version(), global_version)


func test_refuses_direct_and_transitive_scene_cycles() -> void:
	var active := _root.scene_file_path
	if active.is_empty() or not FileAccess.file_exists(active):
		skip("Cycle refusal requires a saved edited scene")
		return
	var parent := _parent_3d(Vector3.ONE)
	var direct := _assert_refused(parent, active, {}, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(direct.get("error", {}).get("message", ""), "cycle")

	var nested := _write_fixture("CycleDependency.tscn", (
		"[gd_scene format=3]\n\n[ext_resource type=\"PackedScene\" path=%s id=\"1\"]\n\n"
		+ "[node name=\"CycleDependency\" type=\"Node\"]\n\n"
		+ "[node name=\"SavedLevel\" parent=\".\" instance=ExtResource(\"1\")]\n") % var_to_str(active))
	if nested.is_empty():
		return
	var dependency := ResourceLoader.load(nested, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	assert_true(dependency != null and dependency.can_instantiate(), "The dependency fixture is a usable native scene")
	var indirect := _assert_refused(parent, nested, {}, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(indirect.get("error", {}).get("message", ""), "cycle")


func test_refuses_cycles_through_resource_dependencies_and_scene_placeholders() -> void:
	var active := _root.scene_file_path
	if active.is_empty() or not FileAccess.file_exists(active):
		skip("Cycle refusal requires a saved edited scene")
		return
	var parent := _parent_3d(Vector3.ONE)
	var resource_path := _write_fixture("BackReference.tres", (
		"[gd_resource type=\"Resource\" format=3]\n\n"
		+ "[ext_resource type=\"PackedScene\" path=%s id=\"1\"]\n\n"
		+ "[resource]\nmetadata/level = ExtResource(\"1\")\n") % var_to_str(active))
	if resource_path.is_empty():
		return
	var source := _write_fixture("ResourceCycle.tscn", (
		"[gd_scene format=3]\n\n[ext_resource type=\"Resource\" path=%s id=\"1\"]\n\n"
		+ "[node name=\"ResourceCycle\" type=\"Node\"]\nmetadata/link = ExtResource(\"1\")\n") % var_to_str(resource_path))
	if source.is_empty():
		return
	var referenced := ResourceLoader.load(source, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	assert_true(referenced != null and referenced.can_instantiate())
	if referenced == null:
		return
	var state := referenced.get_state()
	assert_eq(state.get_node_property_count(0), 1)
	if state.get_node_property_count(0) == 1:
		var intermediate := state.get_node_property_value(0, 0) as Resource
		assert_true(intermediate != null)
		if intermediate != null:
			assert_eq(intermediate.resource_path, resource_path)
			var dependency := intermediate.get_meta("level", null) as PackedScene
			assert_true(dependency != null)
			if dependency != null:
				assert_eq(dependency.resource_path, active)
	var resource_cycle := _assert_refused(parent, source, {}, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(resource_cycle.get("error", {}).get("message", ""), "cycle")

	var placeholder := _write_fixture("PlaceholderCycle.tscn", (
		"[gd_scene format=3]\n\n[node name=\"PlaceholderCycle\" type=\"Node\"]\n\n"
		+ "[node name=\"DeferredLevel\" parent=\".\" instance_placeholder=%s]\n") % var_to_str(active))
	if placeholder.is_empty():
		return
	var placeholder_scene := ResourceLoader.load(placeholder, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	assert_true(placeholder_scene != null and placeholder_scene.can_instantiate())
	if placeholder_scene == null:
		return
	var placeholder_state := placeholder_scene.get_state()
	assert_eq(placeholder_state.get_node_count(), 2)
	if placeholder_state.get_node_count() == 2:
		assert_true(placeholder_state.is_node_instance_placeholder(1))
		assert_eq(placeholder_state.get_node_instance_placeholder(1), active)
	var placeholder_cycle := _assert_refused(parent, placeholder, {}, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(placeholder_cycle.get("error", {}).get("message", ""), "cycle")
