@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/multimesh_handler.gd")
const BatchHandler := preload("res://addons/godot_ai/handlers/batch_handler.gd")
const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const Fixture := preload("res://tests/fixtures/multimesh_instances.tscn")
const BOUNDS := AABB(Vector3(-5, -6, -7), Vector3(10, 12, 14))
const IDENTITY_ROW := [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
const ORIGIN_ROW := {"transform": {"position": [0, 0, 0]}}

var _undo: EditorUndoRedoManager
var _handler: Handler
var _root: Node
var _history: UndoRedo
var _initial_action: int
var _target: MultiMeshInstance3D
var _fixture: Node
var _files: Array[String] = []


class DeferredConnection:
	extends Node
	signal frame
	var dispatcher := McpDispatcher.new(null)
	var responses: Array[Dictionary] = []

	func send_deferred_response(_request_id: String, result: Dictionary) -> void:
		responses.append(result)


func suite_name() -> String:
	return "multimesh_instances"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.undo_redo
	_handler = Handler.new(_undo)
	if EditorInterface.get_edited_scene_root() == null:
		skip_suite("No scene open")


func setup() -> void:
	_root = EditorInterface.get_edited_scene_root()
	_history = _undo.get_history_undo_redo(_undo.get_object_history_id(_root))
	_initial_action = _history.get_current_action()
	_target = _add_target("_McpTestMultiMesh")


func teardown() -> void:
	while _history.get_current_action() > _initial_action:
		if not _history.undo():
			break
	if is_instance_valid(_fixture):
		_root.set_editable_instance(_fixture, false)
		_fixture = null
	for path in _files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_files.clear()


func test_new_mesh_writes_ordered_transforms_and_all_channels() -> void:
	var source := _add_source(BoxMesh.new())
	var rows := [
		{
			"transform": {"position": [5, -6, 7], "rotation_degrees": [0, 0, 90], "scale": [2, 3, 4]},
			"color": {"r": 0.125, "g": 0.25, "b": 0.5, "a": 0.75},
			"custom_data": [-2, 0.25, 1.5, 7],
		},
		{
			"transform": {
				"basis": {"x": [1, 2, 3], "y": [4, 6, 8], "z": [9, 11, 15]},
				"origin": [-8, 3, 4],
			},
			"color": [0.75, 0.5, 0.25, 0.125],
			"custom_data": [3, -4, 5, -6],
		},
	]
	var data := _success(_set_instances(rows, {"mesh_node_path": _path(source), "scene_file": _root.scene_file_path}), 2)
	assert_true(data.get("use_colors", false))
	assert_true(data.get("use_custom_data", false))
	var installed := _target.multimesh
	assert_true(installed != null)
	if installed == null:
		return
	assert_eq(installed.transform_format, MultiMesh.TRANSFORM_3D)
	assert_true(installed.mesh == source.mesh)
	assert_eq(installed.visible_instance_count, -1)
	## Godot's native 3D buffer interleaves each basis row with one origin
	## component, followed by RGBA color and then four custom-data values.
	_assert_buffer(installed, [
		0, -3, 0, 5, 2, 0, 0, -6, 0, 0, 4, 7, 0.125, 0.25, 0.5, 0.75, -2, 0.25, 1.5, 7,
		1, 4, 9, -8, 2, 6, 11, 3, 3, 8, 15, 4, 0.75, 0.5, 0.25, 0.125, 3, -4, 5, -6,
	])


func test_grow_shrink_and_clear_preserve_settings_and_omitted_channels() -> void:
	var original := _seed([
		[0, 1, 0, 1, 7, 8, 9, 10],
		[1, 0, 0, 0.5, -3, -4, -5, -6],
	])
	original.visible_instance_count = 2
	original.custom_aabb = BOUNDS
	original.physics_interpolation_quality = MultiMesh.INTERP_QUALITY_HIGH
	original.resource_local_to_scene = true
	original.resource_name = "Authored instances"
	original.set_meta("tag", "keep")
	_target.multimesh = original
	var rows := [
		{"transform": {"position": [3, 0, -2]}},
		{"transform": {"position": [-4, 5, 6]}, "color": [0.25, 0.5, 0.75]},
		ORIGIN_ROW,
	]
	_success(_set_instances(rows), 3)
	var grown := _target.multimesh
	_assert_preserved_settings(grown, original)
	assert_eq(grown.visible_instance_count, 2)
	_assert_buffer(grown, [
		1, 0, 0, 3, 0, 1, 0, 0, 0, 0, 1, -2, 0, 1, 0, 1, 7, 8, 9, 10,
		1, 0, 0, -4, 0, 1, 0, 5, 0, 0, 1, 6, 0.25, 0.5, 0.75, 1, -3, -4, -5, -6,
		1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0,
	])
	_success(_set_instances([ORIGIN_ROW]), 1)
	var shrunk := _target.multimesh
	_assert_preserved_settings(shrunk, original)
	assert_eq(shrunk.visible_instance_count, 1)
	_assert_buffer(shrunk, IDENTITY_ROW + [0, 1, 0, 1, 7, 8, 9, 10])
	_success(_set_instances([]), 0)
	var cleared := _target.multimesh
	_assert_preserved_settings(cleared, original)
	assert_eq(cleared.visible_instance_count, 0)
	_assert_buffer(cleared, [])


func test_empty_unassigned_slot_creates_no_resource_or_undo_action() -> void:
	var before := _editor_state()
	var data := _success(_set_instances([]), 0, false)
	assert_false(data.get("use_colors", true))
	assert_false(data.get("use_custom_data", true))
	assert_eq(_target.multimesh, null)
	assert_eq(_editor_state(), before)
	assert_is_error(_set_instances([ORIGIN_ROW]), McpErrorCodes.MISSING_REQUIRED_PARAM)
	assert_eq(_target.multimesh, null)
	assert_eq(_editor_state(), before)


func test_populated_2d_multimesh_is_untouched() -> void:
	var original := MultiMesh.new()
	original.mesh = BoxMesh.new()
	original.instance_count = 1
	original.buffer = PackedFloat32Array([1, 0, 0, 4, 0, 1, 0, 6])
	_target.multimesh = original
	var before := _editor_state()
	assert_is_error(_set_instances([ORIGIN_ROW]), McpErrorCodes.WRONG_TYPE)
	assert_true(_target.multimesh == original)
	assert_eq(original.transform_format, MultiMesh.TRANSFORM_2D)
	assert_eq(original.instance_count, 1)
	_assert_buffer(original, [1, 0, 0, 4, 0, 1, 0, 6])
	assert_eq(_editor_state(), before)


func test_mesh_path_source_and_retained_mesh_identity() -> void:
	var source_path := "res://tests/_multimesh_source_%d.tres" % Time.get_ticks_usec()
	_files.append(source_path)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.75
	assert_eq(ResourceSaver.save(mesh, source_path), OK)
	var file_mesh := load(source_path) as Mesh
	assert_true(file_mesh is CylinderMesh)
	_success(_set_instances([], {"mesh_path": source_path}), 0)
	assert_true(_target.multimesh != null)
	if _target.multimesh == null:
		return
	assert_true(_target.multimesh.mesh == file_mesh)
	_success(_set_instances([ORIGIN_ROW]), 1)
	assert_true(_target.multimesh.mesh == file_mesh)
	_assert_buffer(_target.multimesh, IDENTITY_ROW)


func test_locked_mesh_source_is_readable_and_editable_target_persists() -> void:
	_fixture = track(Fixture.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)) as Node
	_fixture.name = "_McpTestMultiMeshFixture"
	_root.add_child(_fixture)
	_fixture.owner = _root
	var source := _fixture.get_node("Source") as MeshInstance3D
	var target := _fixture.get_node("Target") as MultiMeshInstance3D
	var before := _editor_state()
	var params := {"path": _path(target), "mesh_node_path": _path(source), "instances": [ORIGIN_ROW]}
	var locked := _handler.set_instances(params)
	assert_is_error(locked, McpErrorCodes.INVALID_PARAMS)
	assert_contains(locked.get("error", {}).get("message", ""), "Editable Children")
	assert_eq(target.multimesh, null)
	assert_eq(_editor_state(), before)

	_success(_set_instances([ORIGIN_ROW], {"mesh_node_path": _path(source)}), 1)
	assert_true(_target.multimesh != null and _target.multimesh.mesh == source.mesh,
		"a mesh on a locked instance remains available as a read-only source")
	_root.set_editable_instance(_fixture, true)
	_success(_handler.set_instances(params), 1)
	assert_true(target.multimesh != null and target.multimesh.mesh == source.mesh)
	var packed := PackedScene.new()
	assert_eq(packed.pack(_root), OK)
	var restored := track(packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)) as Node
	assert_true(restored != null)
	if restored == null:
		return
	var restored_target := restored.get_node(str(_fixture.name) + "/Target") as MultiMeshInstance3D
	assert_true(restored_target.multimesh != null and restored_target.multimesh.mesh is CapsuleMesh)
	_assert_buffer(restored_target.multimesh, IDENTITY_ROW)


func test_invalid_late_rows_leave_slot_data_history_and_dirty_state_unchanged() -> void:
	var original := _seed([[0, 1, 0, 1, 7, 8, 9, 10]])
	_target.multimesh = original
	var before := _editor_state()
	var bad_rows := [
		{"transform": {"position": [0, 1e40, 2]}},
		{"transform": {"position": [0, "1", 2]}},
		{"transform": {"position": [0, 1, 2]}, "color": [1.0, 1.0, 1e40]},
		{"transform": {"position": [0, 1, 2]}, "custom_data": [1, 2, 3]},
	]
	for bad_row: Dictionary in bad_rows:
		var result := _set_instances([{"transform": {"position": [8, 9, 10]}}, bad_row])
		assert_is_error(result, McpErrorCodes.WRONG_TYPE, str(bad_row))
		assert_eq(result.get("error", {}).get("data", {}).get("row", -1), 1)
		assert_true(_target.multimesh == original)
		_assert_buffer(original, IDENTITY_ROW + [0, 1, 0, 1, 7, 8, 9, 10])
		assert_eq(_editor_state(), before)


func test_one_undo_and_redo_restore_exact_shared_resources_and_noop_keeps_redo() -> void:
	var original := _seed([])
	original.instance_count = 1
	original.buffer = PackedFloat32Array(IDENTITY_ROW)
	var shared := _add_target("_McpTestSharedMultiMesh")
	_target.multimesh = original
	shared.multimesh = original
	var before := _editor_state()
	var edit := [{"transform": {"position": [3, 5, -2]}}]
	_success(_set_instances(edit), 1)
	var installed := _target.multimesh
	assert_true(installed != original)
	assert_true(shared.multimesh == original)
	_assert_buffer(original, IDENTITY_ROW)
	_assert_buffer(installed, [1, 0, 0, 3, 0, 1, 0, 5, 0, 0, 1, -2])

	var edited := _editor_state()
	assert_eq(_history.get_current_action(), _initial_action + 1)
	_success(_set_instances(edit), 1, false)
	assert_true(_target.multimesh == installed)
	assert_eq(_editor_state(), edited)
	assert_true(_history.undo(), "undo should succeed in the scene history")
	assert_true(_target.multimesh == original)
	assert_true(shared.multimesh == original)
	assert_eq(_history.get_version(), before.scene_version)

	var undone := _editor_state()
	_success(_set_instances([ORIGIN_ROW]), 1, false)
	assert_true(_target.multimesh == original)
	assert_eq(_editor_state(), undone)
	assert_true(_history.redo(), "no-op must preserve the redo action")
	assert_true(_target.multimesh == installed)
	assert_true(shared.multimesh == original)
	_assert_buffer(installed, [1, 0, 0, 3, 0, 1, 0, 5, 0, 0, 1, -2])


func test_sliced_job_refuses_replaced_target_at_same_path() -> void:
	_target.multimesh = _seed([])
	var original_target := _target
	var original := original_target.multimesh
	var job := _begin_job()
	if job.has("error"):
		return
	var name_before := String(_target.name)
	_root.remove_child(original_target)
	var replacement := _add_target(name_before)
	replacement.multimesh = _seed([])
	var replacement_resource := replacement.multimesh
	var before := _editor_state()
	assert_is_error(_finish_job(job), McpErrorCodes.EDITED_SCENE_MISMATCH)
	assert_true(replacement.multimesh == replacement_resource)
	assert_true(original_target.multimesh == original)
	assert_eq(_editor_state(), before)


func test_sliced_job_refuses_stale_scene_root_even_at_same_scene_file() -> void:
	_target.multimesh = _seed([])
	var original := _target.multimesh
	var job := _begin_job()
	if job.has("error"):
		return
	## Exercise the live scene-root guard without switching the test runner's
	## active tab. A second instance of the scene has the same file path.
	var old_scene := track(Node3D.new()) as Node3D
	old_scene.name = _root.name
	old_scene.scene_file_path = _root.scene_file_path
	job.scene_root = old_scene
	var before := _editor_state()
	assert_is_error(_finish_job(job), McpErrorCodes.EDITED_SCENE_MISMATCH)
	assert_true(_target.multimesh == original)
	assert_eq(_editor_state(), before)


func test_staged_job_refuses_in_place_buffer_edit() -> void:
	var original := _seed([[0, 1, 0, 1, 7, 8, 9, 10]])
	_target.multimesh = original
	var job := _begin_job()
	if not _advance_to_commit(job):
		return
	var changed_row := IDENTITY_ROW + [0, 0, 1, 1, -1, -2, -3, -4]
	original.buffer = PackedFloat32Array(changed_row)
	var before := _editor_state()
	assert_is_error(_finish_job(job), McpErrorCodes.EDITED_SCENE_MISMATCH)
	assert_true(_target.multimesh == original)
	_assert_buffer(original, changed_row)
	assert_eq(_editor_state(), before)


func test_staged_job_refuses_changed_mesh_on_same_source_node() -> void:
	var source := _add_source(CapsuleMesh.new())
	var job := _begin_job({"mesh_node_path": _path(source)})
	if not _advance_to_commit(job):
		return
	var replacement := SphereMesh.new()
	source.mesh = replacement
	var before := _editor_state()
	assert_is_error(_finish_job(job), McpErrorCodes.EDITED_SCENE_MISMATCH)
	assert_eq(_target.multimesh, null)
	assert_true(source.mesh == replacement)
	assert_eq(_editor_state(), before)


func test_cancelled_deferred_request_discards_staged_candidate_and_releases_work() -> void:
	var original := _seed([])
	_target.multimesh = original
	var connection := track(DeferredConnection.new()) as DeferredConnection
	_root.add_child(connection)
	var request_id := "multimesh-test-request"
	connection.dispatcher._register_deferred(request_id, "multimesh_set_instances")
	assert_true(connection.dispatcher.has_pending_deferred_response(request_id))
	var job := _begin_job({}, connection, request_id)
	if not _advance_to_commit(job):
		return
	var before := _editor_state()
	var work_before := ScriptWork.active_count("multimesh_set_instances")
	Handler._drive_job(job, connection, connection.frame)
	assert_eq(ScriptWork.active_count("multimesh_set_instances"), work_before + 1)
	connection.dispatcher.clear_deferred_responses()
	connection.frame.emit()
	assert_eq(job.phase, "done")
	assert_eq(job.result, {})
	assert_eq(connection.responses, [])
	assert_eq(ScriptWork.active_count("multimesh_set_instances"), work_before)
	assert_true(_target.multimesh == original)
	assert_eq(_editor_state(), before)


func test_batch_refuses_multimesh_before_any_command_executes() -> void:
	var dispatcher := McpDispatcher.new(null)
	dispatcher.mcp_logging = false
	var node_handler := NodeHandler.new(_undo)
	dispatcher.register("set_property", node_handler.set_property)
	dispatcher.register("multimesh_set_instances", _handler.set_instances)
	var batch := BatchHandler.new(dispatcher, _undo)
	var original := _seed([])
	_target.multimesh = original
	var path := _path(_target)
	var before := _editor_state()
	var result := batch.batch_execute({
		"commands": [
			{"command": "set_property", "params": {"path": path, "property": "visible", "value": false}},
			{"command": "multimesh_set_instances", "params": {"path": path, "instances": [ORIGIN_ROW]}},
		],
	})
	assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.get("error", {}).get("message", ""), "multimesh_set_instances")
	assert_true(_target.visible)
	assert_true(_target.multimesh == original)
	assert_eq(_editor_state(), before)


func _add_target(node_name: String) -> MultiMeshInstance3D:
	var node := track(MultiMeshInstance3D.new()) as MultiMeshInstance3D
	node.name = node_name
	_root.add_child(node)
	node.owner = _root
	return node


func _add_source(mesh: Mesh) -> MeshInstance3D:
	var node := track(MeshInstance3D.new()) as MeshInstance3D
	node.name = "_McpTestMultiMeshSource"
	node.mesh = mesh
	_root.add_child(node)
	node.owner = _root
	return node


func _path(node: Node) -> String:
	return McpScenePath.from_node(node, _root)


func _set_instances(rows: Array, options := {}) -> Dictionary:
	var params := {"path": _path(_target), "instances": rows}
	params.merge(options)
	return _handler.set_instances(params)


func _success(result: Dictionary, count: int, changed := true) -> Dictionary:
	assert_has_key(result, "data", str(result))
	var data: Dictionary = result.get("data", {})
	assert_eq(data.get("instance_count", -1), count)
	assert_eq(data.get("changed"), changed)
	assert_eq(data.get("undoable"), changed)
	return data


func _seed(channel_rows: Array) -> MultiMesh:
	var resource := MultiMesh.new()
	resource.transform_format = MultiMesh.TRANSFORM_3D
	resource.mesh = BoxMesh.new()
	if not channel_rows.is_empty():
		resource.use_colors = true
		resource.use_custom_data = true
		resource.instance_count = channel_rows.size()
		var buffer := PackedFloat32Array()
		for row: Array in channel_rows:
			buffer.append_array(PackedFloat32Array(IDENTITY_ROW + row))
		resource.buffer = buffer
	return resource


func _assert_buffer(resource: MultiMesh, expected: Array) -> void:
	assert_true(resource != null, "expected an assigned MultiMesh")
	if resource == null:
		return
	## The headless renderer retains the native bulk buffer. Its per-instance
	## getters return dummy values, so compare with independently specified data.
	var actual := resource.buffer
	assert_eq(actual.size(), expected.size())
	for index in mini(actual.size(), expected.size()):
		assert_true(is_equal_approx(actual[index], float(expected[index])),
			"buffer[%d] expected %s, got %s" % [index, expected[index], actual[index]])


func _assert_preserved_settings(actual: MultiMesh, original: MultiMesh) -> void:
	assert_true(actual.mesh == original.mesh)
	assert_eq(actual.transform_format, MultiMesh.TRANSFORM_3D)
	assert_true(actual.use_colors)
	assert_true(actual.use_custom_data)
	assert_eq(actual.custom_aabb, BOUNDS)
	assert_eq(actual.physics_interpolation_quality, MultiMesh.INTERP_QUALITY_HIGH)
	assert_true(actual.resource_local_to_scene)
	assert_eq(actual.resource_name, "Authored instances")
	assert_eq(actual.get_meta("tag", ""), "keep")


func _editor_state() -> Dictionary:
	var global_history := _undo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	return {
		"scene_version": _history.get_version(),
		"global_version": global_history.get_version(),
		"unsaved_scenes": EditorInterface.get_unsaved_scenes(),
	}


func _begin_job(options := {}, connection: Node = null, request_id := "") -> Dictionary:
	var params := {
		"path": _path(_target),
		"instances": [ORIGIN_ROW, {"transform": {"position": [2, 4, 6]}}],
	}
	params.merge(options)
	var job := Handler._prepare_job(params, _undo, connection, request_id)
	assert_false(job.has("error"), str(job))
	if not job.has("error"):
		var original := _target.multimesh
		var before := _editor_state()
		assert_false(Handler._step(job, 0), "the first slice should leave work pending")
		assert_true(_target.multimesh == original)
		assert_eq(_editor_state(), before)
	return job


func _advance_to_commit(job: Dictionary) -> bool:
	if job.has("error"):
		return false
	for _attempt in 16:
		if job.phase == "commit":
			return true
		if Handler._step(job, 0):
			break
	assert_true(false, "expected a fully staged candidate before commit")
	return false


func _finish_job(job: Dictionary) -> Dictionary:
	for _attempt in 16:
		if Handler._step(job, 0):
			return job.result
	assert_true(false, "job should settle within the available slices")
	return {}
