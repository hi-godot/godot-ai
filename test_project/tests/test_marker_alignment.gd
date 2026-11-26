@tool
extends McpTestSuite

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const InstanceScene := preload("res://tests/fixtures/marker_alignment.tscn")
const ROUNDTRIP_PATH := "user://_mcp_test_marker_alignment.tscn"
const POSE_TOLERANCE := 0.0001

var _handler: NodeHandler
var _undo_redo: EditorUndoRedoManager
var _scene_history: UndoRedo
var _global_history: UndoRedo
var _scene_root: Node
var _rig: Node3D
var _mover_parent: Node3D
var _mover: Node3D
var _socket: Node3D
var _source: Marker3D
var _target: Marker3D
var _editable_instance: Node3D


func suite_name() -> String:
	return "marker_alignment"


func suite_setup(ctx: Dictionary) -> void:
	_scene_root = EditorInterface.get_edited_scene_root()
	if _scene_root == null:
		fail_setup("Marker alignment requires an edited scene")
		return
	_undo_redo = ctx.undo_redo
	_handler = NodeHandler.new(_undo_redo)
	_scene_history = _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_scene_root))
	_global_history = _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func setup() -> void:
	_rig = _add(_scene_root, Node3D.new(), "_McpTestMarkerAlignment")
	_mover_parent = _add(_rig, Node3D.new(), "TiltedParent")
	_mover_parent.transform = Transform3D(Basis.from_euler(Vector3(0.38, -0.61, 0.52)).scaled(Vector3.ONE * 1.7), Vector3(-3, 1, 5))
	_mover = _add(_mover_parent, Node3D.new(), "Mover")
	_mover.transform = Transform3D(Basis.from_euler(Vector3(-0.2, 0.5, -0.25)), Vector3(2, -1, 1))
	_socket = _add(_mover, Node3D.new(), "Socket")
	_socket.position = Vector3(-1.5, 2, -0.4)
	_source = _add(_socket, Marker3D.new(), "Source")
	_source.transform = Transform3D(Basis.from_euler(Vector3(0.31, -0.48, 0.23)).scaled_local(Vector3(0.6, 1.8, 1.1)), Vector3(0.5, 1.2, -2.2))
	_target = _add(_rig, Marker3D.new(), "Target")
	_target.transform = Transform3D(Basis.from_euler(Vector3(-0.61, 1.07, -0.46)).scaled_local(Vector3(2.1, 0.7, 1.5)), Vector3(6, 2, -4))


func teardown() -> void:
	if is_instance_valid(_editable_instance):
		_scene_root.set_editable_instance(_editable_instance, false)
	_editable_instance = null
	_rig.free()
	if FileAccess.file_exists(ROUNDTRIP_PATH):
		DirAccess.remove_absolute(ROUNDTRIP_PATH)


func test_match_defaults_to_a_single_undoable_rigid_move() -> void:
	var before_local := _mover.transform
	var before_global := _mover.global_transform
	var before_source := _source.global_transform
	var source_local := _source.transform
	var socket_local := _socket.transform
	var target_world := _target.global_transform
	var version := _scene_history.get_version()
	var global_version := _global_history.get_version()
	var params := _params(_mover, _source, _target)
	params.path = str(_scene_root.get_path_to(_mover))
	params.scene_file = _scene_root.scene_file_path
	var data := _handler.align_markers_3d(params).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	assert_true(data.get("undoable", false))
	assert_eq(data.get("orientation"), "match")
	assert_eq(data.get("path"), _path(_mover))
	assert_eq(data.get("source_marker_path"), _path(_source))
	assert_eq(data.get("target_marker_path"), _path(_target))
	_assert_pose(_source, _target, 1.0)
	_assert_axis_lengths(_source.global_basis, before_source.basis, "source marker")
	_assert_axis_lengths(_mover.global_basis, before_global.basis, "mover")
	assert_eq(_source.transform, source_local, "source marker local transform is fixed")
	assert_eq(_socket.transform, socket_local, "intermediate local transform is fixed")
	assert_eq(_target.global_transform, target_world, "target marker world transform is fixed")
	assert_eq(_scene_history.get_version(), version + 1, "one alignment must commit exactly one scene action")
	assert_eq(_global_history.get_version(), global_version, "alignment must not edit global history")
	var after_local := _mover.transform
	var unchanged := _handler.align_markers_3d(params).get("data", {}) as Dictionary
	assert_eq(unchanged.get("changed"), false)
	assert_eq(unchanged.get("undoable"), false)
	assert_eq(_mover.transform, after_local, "repeated alignment must leave stored transform untouched")
	assert_eq(_scene_history.get_version(), version + 1, "repeated alignment must not commit another action")
	assert_eq(_global_history.get_version(), global_version, "repeated alignment must not edit global history")
	assert_true(editor_undo(_undo_redo), "align undo should succeed")
	assert_eq(_scene_history.get_version(), version)
	assert_eq(_mover.transform, before_local, "one undo must restore the exact local transform")
	assert_true(_source.global_transform.is_equal_approx(before_source), "one undo must restore the source pose")
	assert_eq(_target.global_transform, target_world)
	assert_true(editor_redo(_undo_redo), "align redo should succeed")
	assert_eq(_mover.transform, after_local)
	_assert_pose(_source, _target, 1.0)
	assert_eq(_target.global_transform, target_world)
	assert_true(editor_undo(_undo_redo), "align cleanup undo should succeed")


func test_face_to_face_under_rotated_nonuniform_parent_preserves_world_shape() -> void:
	_mover_parent.scale = Vector3(3.0, 1.4, 0.7)
	_mover.rotation = Vector3.ZERO
	_mover.scale = Vector3(0.8, 1.5, 2.4)
	_source.rotation = Vector3.ZERO
	var before_world := _mover.global_transform
	var source_before := _source.global_transform
	var target_world := _target.global_transform
	var params := _params(_mover, _source, _target)
	params.orientation = "face_to_face"
	var data := _handler.align_markers_3d(params).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	assert_eq(data.get("orientation"), "face_to_face")
	_assert_pose(_source, _target, -1.0)
	_assert_axis_lengths(_mover.global_basis, before_world.basis, "mover")
	_assert_axis_lengths(_source.global_basis, source_before.basis, "source marker")
	assert_eq(_target.global_transform, target_world)
	assert_gt(absf(_mover.basis.x.normalized().dot(_mover.basis.y.normalized())), 0.01, "this pose requires a sheared local basis")
	assert_true(editor_undo(_undo_redo), "face-to-face undo should succeed")


func test_marker_orientation_is_independent_of_positive_axis_lengths() -> void:
	_target.basis = _target.basis.orthonormalized().scaled_local(Vector3(0.000001, 1.0, 10.0))
	var target_world := _target.global_transform
	var data := _handler.align_markers_3d(_params(_mover, _source, _target)).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	_assert_pose(_source, _target, 1.0)
	assert_eq(_target.global_transform, target_world)
	assert_true(editor_undo(_undo_redo), "anisotropic target align undo should succeed")


func test_top_level_mover_uses_its_own_transform_space() -> void:
	_mover.top_level = true
	_mover.transform = Transform3D(Basis.from_euler(Vector3(0.2, -0.8, 0.4)), Vector3(-2, 5, 1))
	var before := _mover.transform
	var target_world := _target.global_transform
	var data := _handler.align_markers_3d(_params(_mover, _source, _target)).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	_assert_pose(_source, _target, 1.0)
	assert_true(_mover.top_level)
	assert_eq(_target.global_transform, target_world)
	assert_true(editor_undo(_undo_redo), "top-level align undo should succeed")
	assert_eq(_mover.transform, before)
	assert_true(_mover.top_level)


func test_rejects_source_that_does_not_inherit_mover_transform() -> void:
	_socket.top_level = true
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.INVALID_PARAMS)
	_socket.top_level = false
	var plain := _add(_mover, Node.new(), "PlainNode")
	var detached_source := _add(plain, Marker3D.new(), "BrokenChain") as Marker3D
	_assert_refusal(_params(_mover, detached_source, _target), McpErrorCodes.INVALID_PARAMS)


func test_rejects_invalid_nodes_and_scene_pin_without_side_effects() -> void:
	var invalid := _params(_mover, _source, _target)
	invalid.path = _path(_add(_rig, Node.new(), "Not3D"))
	_assert_refusal(invalid, McpErrorCodes.WRONG_TYPE)
	invalid = _params(_mover, _source, _target)
	invalid.source_marker_path = _path(_socket)
	_assert_refusal(invalid, McpErrorCodes.WRONG_TYPE)
	invalid.erase("source_marker_path")
	_assert_refusal(invalid, McpErrorCodes.MISSING_REQUIRED_PARAM)
	invalid = _params(_mover, _source, _target)
	invalid.target_marker_path = _path(_rig)
	_assert_refusal(invalid, McpErrorCodes.WRONG_TYPE)
	invalid.target_marker_path = _path(_rig) + "/Missing"
	_assert_refusal(invalid, McpErrorCodes.NODE_NOT_FOUND)
	invalid = _params(_mover, _source, _target)
	invalid.scene_file = "res://tests/_mcp_unrelated_marker_scene.tscn"
	_assert_refusal(invalid, McpErrorCodes.EDITED_SCENE_MISMATCH)
	_assert_refusal(_params(_mover, _target, _source), McpErrorCodes.INVALID_PARAMS)
	var nested_target := _add(_mover, Marker3D.new(), "NestedTarget") as Marker3D
	nested_target.top_level = true
	var nested_before := nested_target.global_transform
	_assert_refusal(_params(_mover, _source, nested_target), McpErrorCodes.INVALID_PARAMS)
	assert_eq(nested_target.global_transform, nested_before)
	var outside := Marker3D.new()
	EditorInterface.get_base_control().add_child(outside)
	var outside_before := outside.global_transform
	invalid = _params(_mover, _source, _target)
	invalid.target_marker_path = str(outside.get_path())
	_assert_refusal(invalid, McpErrorCodes.NODE_NOT_FOUND)
	assert_eq(outside.global_transform, outside_before)
	outside.free()


func test_rejects_target_in_another_world() -> void:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	_add(_rig, viewport, "OtherWorld")
	var target := _add(viewport, Marker3D.new(), "OtherTarget") as Marker3D
	target.position = Vector3(-4, 5, 6)
	var before := target.global_transform
	assert_ne(target.get_world_3d(), _mover.get_world_3d(), "fixture must have different 3D worlds")
	_assert_refusal(_params(_mover, _source, target), McpErrorCodes.INVALID_PARAMS)
	assert_eq(target.global_transform, before)


func test_rejects_mover_or_parent_without_persistent_ownership() -> void:
	_mover.owner = null
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.INVALID_PARAMS)
	_mover.owner = _scene_root
	_mover_parent.owner = null
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.INVALID_PARAMS)


func test_rejects_reflected_sheared_and_singular_marker_frames() -> void:
	var target_before := _target.transform
	_target.basis = Basis.from_scale(Vector3(-1, 1, 1))
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.VALUE_OUT_OF_RANGE)
	_target.transform = target_before
	_source.basis = Basis(Vector3.RIGHT, Vector3(0.35, 1, 0), Vector3.BACK)
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.VALUE_OUT_OF_RANGE)
	_source.basis = Basis.from_scale(Vector3(1, 0, 1))
	_assert_refusal(_params(_mover, _source, _target), McpErrorCodes.VALUE_OUT_OF_RANGE)


func test_locked_markers_are_readable_and_editable_mover_override_survives_save() -> void:
	var instance := _add(_rig, InstanceScene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), "Linked") as Node3D
	var locked := _add(_rig, InstanceScene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), "LockedTarget") as Node3D
	locked.position = Vector3(-4, 1, 2)
	var mover := instance.get_node("Mover") as Node3D
	var source := mover.get_node("Source") as Marker3D
	var target := locked.get_node("Target") as Marker3D
	var params := _params(mover, source, target)
	var before := mover.transform
	var source_before := source.global_transform
	var target_world := target.global_transform
	var version := _scene_history.get_version()
	var global_version := _global_history.get_version()
	var rejected := _handler.align_markers_3d(params)
	assert_is_error(rejected, McpErrorCodes.INVALID_PARAMS)
	assert_contains(str(rejected.get("error", {}).get("message", "")), "Editable Children")
	assert_eq(mover.transform, before)
	assert_eq(source.global_transform, source_before)
	assert_eq(target.global_transform, target_world)
	assert_eq(_scene_history.get_version(), version)
	assert_eq(_global_history.get_version(), global_version)
	_scene_root.set_editable_instance(instance, true)
	_editable_instance = instance
	var data := _handler.align_markers_3d(params).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	_assert_pose(source, target, 1.0)
	assert_eq(mover.owner, instance)
	assert_eq(source.owner, instance)
	assert_eq(target.owner, locked)
	assert_eq(target.global_transform, target_world)
	assert_false(_scene_root.is_editable_instance(locked))
	assert_eq(_scene_history.get_version(), version + 1)
	var packed := PackedScene.new()
	assert_eq(packed.pack(_scene_root), OK)
	assert_eq(ResourceSaver.save(packed, ROUNDTRIP_PATH), OK)
	var saved := ResourceLoader.load(ROUNDTRIP_PATH, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	assert_ne(saved, null, "the containing scene must be readable after saving")
	if saved == null:
		return
	var restored := saved.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var restored_instance := restored.get_node_or_null(_scene_root.get_path_to(instance))
	assert_ne(restored_instance, null, "the reopened scene must retain the linked instance")
	if restored_instance != null:
		assert_true(restored.is_editable_instance(restored_instance))
		assert_eq(restored_instance.scene_file_path, instance.scene_file_path)
		var restored_mover := restored_instance.get_node("Mover") as Node3D
		assert_true(restored_mover.transform.is_equal_approx(mover.transform), "the edit must survive reload as an instance override")
	restored.free()
	assert_true(editor_undo(_undo_redo), "editable override undo should succeed")
	assert_eq(mover.transform, before)


func test_locked_instance_root_can_move_using_its_read_only_source_marker() -> void:
	var instance := _add(_rig, InstanceScene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE), "LockedMover") as Node3D
	var source := instance.get_node("Mover/Source") as Marker3D
	_target.owner = null
	var target_world := _target.global_transform
	var before := instance.transform
	assert_false(_scene_root.is_editable_instance(instance))
	var data := _handler.align_markers_3d(_params(instance, source, _target)).get("data", {}) as Dictionary
	assert_true(data.get("changed", false))
	_assert_pose(source, _target, 1.0)
	assert_eq(source.owner, instance)
	assert_eq(_target.owner, null)
	assert_eq(_target.global_transform, target_world)
	assert_false(_scene_root.is_editable_instance(instance))
	assert_true(editor_undo(_undo_redo), "locked instance root align undo should succeed")
	assert_eq(instance.transform, before)


func _add(parent: Node, node: Node, node_name: String) -> Node:
	node.name = node_name
	parent.add_child(node)
	node.owner = _scene_root
	return node


func _path(node: Node) -> String:
	return McpScenePath.from_node(node, _scene_root)


func _params(mover: Node3D, source: Marker3D, target: Marker3D) -> Dictionary:
	return {"path": _path(mover), "source_marker_path": _path(source), "target_marker_path": _path(target)}


func _assert_pose(source: Marker3D, target: Marker3D, facing_sign: float) -> void:
	assert_true(source.global_position.distance_to(target.global_position) <= POSE_TOLERANCE, "marker origins must coincide")
	assert_true((-source.global_basis.z).normalized().is_equal_approx((-target.global_basis.z).normalized() * facing_sign), "Godot forward (-Z) must have the requested orientation")
	assert_true(source.global_basis.y.normalized().is_equal_approx(target.global_basis.y.normalized()), "markers must have agreeing up axes")
	assert_true(source.global_basis.x.normalized().is_equal_approx(target.global_basis.x.normalized() * facing_sign), "right axes must complete the desired orientation")


func _assert_axis_lengths(actual: Basis, before: Basis, label: String) -> void:
	var actual_lengths := Vector3(actual.x.length(), actual.y.length(), actual.z.length())
	var before_lengths := Vector3(before.x.length(), before.y.length(), before.z.length())
	assert_true(actual_lengths.is_equal_approx(before_lengths), "%s world axis lengths must be preserved" % label)


func _assert_refusal(params: Dictionary, error_code: String) -> void:
	var mover_before := _mover.transform
	var source_before := _source.global_transform
	var target_before := _target.global_transform
	var scene_version := _scene_history.get_version()
	var global_version := _global_history.get_version()
	var result := _handler.align_markers_3d(params)
	assert_is_error(result, error_code, "Expected %s for %s, got %s" % [error_code, params, result])
	assert_eq(_mover.transform, mover_before, "refusal leaves the mover untouched")
	assert_eq(_source.global_transform, source_before, "refusal leaves the source untouched")
	assert_eq(_target.global_transform, target_before, "refusal leaves the target untouched")
	assert_eq(_scene_history.get_version(), scene_version, "refusal leaves scene history untouched")
	assert_eq(_global_history.get_version(), global_version, "refusal leaves global history untouched")
