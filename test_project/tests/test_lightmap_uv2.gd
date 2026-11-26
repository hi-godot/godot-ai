@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const InstanceFixture := preload("res://tests/fixtures/instance_editing.tscn")
const HANDLER_PATH := "res://addons/godot_ai/handlers/lightmap_uv2_handler.gd"
const COMMAND := "check_lightmap_uv2"
const REQUEST_ID := "lightmap-uv2-test"


class TestEditor extends RefCounted:
	signal frame
	signal scene_changed(root: Node)
	var edited_root: Node

	func get_edited_root() -> Node:
		return edited_root


class CapturingConnection extends McpConnection:
	var replies: Array[Dictionary] = []

	func _ready() -> void:
		set_process(false)

	func send_deferred_response(request_id: String, payload: Dictionary) -> void:
		if dispatcher.complete_deferred_response(request_id):
			replies.append({"request_id": request_id, "payload": payload})


var _undo: EditorUndoRedoManager
var _scene_root: Node
var _fixture: Node3D
var _editor: TestEditor
var _connection: CapturingConnection
var _dispatcher: McpDispatcher


func suite_name() -> String:
	return "lightmap_uv2"


func suite_setup(ctx: Dictionary) -> void:
	_undo = ctx.undo_redo
	_scene_root = EditorInterface.get_edited_scene_root()
	if _scene_root == null:
		fail_setup("An edited scene is required for the lightmap UV2 fixture")


func setup() -> void:
	_fixture = Node3D.new()
	_fixture.name = "_McpTestLightmapUv2"
	_scene_root.add_child(_fixture)
	_fixture.owner = _scene_root
	track(_fixture)
	_editor = TestEditor.new()
	_editor.edited_root = _scene_root
	_dispatcher = McpDispatcher.new(McpLogBuffer.new())
	_dispatcher.mcp_logging = false
	_connection = CapturingConnection.new()
	track(_connection)
	_connection.dispatcher = _dispatcher
	_scene_root.get_tree().root.add_child(_connection)
	_dispatcher.register_lazy_handler(COMMAND, HANDLER_PATH, [
		_connection, _editor.scene_changed, _editor.frame, _editor.get_edited_root, 0,
	])
	_dispatcher.register_lazy(COMMAND, COMMAND, &"check_lightmap_uv2")


func teardown() -> void:
	_dispatcher.clear_deferred_responses()
	_editor.frame.emit()
	_dispatcher.release_after_teardown()
	_connection.dispatcher = null


func _path(node: Node) -> String:
	return McpScenePath.from_node(node, _scene_root)


func _add_mesh(name: String, mesh: Mesh, parent: Node = null, internal_mode: Node.InternalMode = Node.INTERNAL_MODE_DISABLED) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	if parent == null:
		parent = _fixture
	parent.add_child(instance, false, internal_mode)
	instance.owner = _scene_root
	return instance


func _add_triangle(mesh: ArrayMesh, surface_name: String, normals: bool, uv2: bool) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	if normals:
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	if uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_name(mesh.get_surface_count() - 1, surface_name)


func _queue_scan(params: Dictionary = {}) -> Array[Dictionary]:
	_connection.replies.clear()
	var arguments := {"path": _path(_fixture)}
	arguments.merge(params, true)
	_dispatcher.enqueue({"request_id": REQUEST_ID, "command": COMMAND, "params": arguments})
	return _dispatcher.tick(100.0)


func _start_scan(params: Dictionary = {}) -> void:
	assert_eq(_queue_scan(params), [], "the handler must defer before gathering mesh metadata")
	assert_eq(_dispatcher.pending_deferred_count(), 1)
	assert_eq(_connection.replies, [])


func _finish_scan() -> Dictionary:
	for frame in range(128):
		if not _connection.replies.is_empty():
			break
		_editor.frame.emit()
	assert_eq(_connection.replies.size(), 1, "the deferred scan must respond exactly once")
	assert_eq(_dispatcher.pending_deferred_count(), 0)
	if _connection.replies.is_empty():
		return {}
	assert_eq(_connection.replies[0].request_id, REQUEST_ID)
	return _connection.replies[0].payload


func _scan(params: Dictionary = {}) -> Dictionary:
	_start_scan(params)
	var response := _finish_scan()
	assert_has_key(response, "data")
	return response.get("data", {})


func _assert_scan_error(params: Dictionary, code: String) -> void:
	var immediate := _queue_scan(params)
	assert_eq(immediate.size(), 1, "invalid params should be rejected before scanning")
	assert_eq(_dispatcher.pending_deferred_count(), 0)
	if not immediate.is_empty():
		assert_is_error(immediate[0], code)


func _finding(data: Dictionary, index: int) -> Dictionary:
	var rows: Array = data.get("findings", [])
	return rows[index] if index < rows.size() else {}


func _assert_surface(row: Dictionary, node: MeshInstance3D, index: int, surface_name: String, issues: Array) -> void:
	assert_eq(row.get("kind"), "surface")
	assert_eq(row.get("path"), _path(node))
	assert_eq(row.get("mesh_path"), node.mesh.resource_path)
	assert_eq(row.get("surface_index"), index)
	assert_eq(row.get("surface_name", ""), surface_name)
	assert_eq(row.get("issues"), issues)


func test_reports_each_surface_at_each_shared_mesh_placement_without_edits() -> void:
	var mesh := ArrayMesh.new()
	_add_triangle(mesh, "Neither", false, false)
	_add_triangle(mesh, "MissingUV2", true, false)
	_add_triangle(mesh, "MissingNormals", false, true)
	_add_triangle(mesh, "Complete", true, true)
	var second := _add_mesh("Second", mesh)
	var first := _add_mesh("First", mesh)
	var surface_formats: Array[int] = []
	for index in range(mesh.get_surface_count()):
		surface_formats.append(mesh.surface_get_format(index))
	var history := _undo.get_history_undo_redo(_undo.get_object_history_id(_scene_root))
	var history_version := history.get_version()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var ready := _scan()
	assert_eq(ready.get("scope"), "bake_candidates")
	assert_eq(ready.get("path"), _path(_fixture))
	assert_eq(ready.get("status"), "missing_channels")
	assert_true(ready.get("complete", false))
	assert_eq(ready.get("mesh_instances_checked"), 2)
	assert_eq(ready.get("triangle_surfaces_checked"), 8)
	assert_eq(ready.get("unsupported_mesh_instances"), 0)
	assert_eq(ready.get("missing_surface_count"), 6)
	assert_eq(ready.get("total_count"), 6)
	for index in range(2):
		var node := second if index == 0 else first
		_assert_surface(_finding(ready, index * 3), node, 0, "Neither", ["missing_uv2", "missing_normals"])
		_assert_surface(_finding(ready, index * 3 + 1), node, 1, "MissingUV2", ["missing_uv2"])
		_assert_surface(_finding(ready, index * 3 + 2), node, 2, "MissingNormals", ["missing_normals"])
	assert_eq(first.mesh, mesh)
	assert_eq(second.mesh, mesh)
	assert_eq(first.owner, _scene_root)
	assert_eq(second.owner, _scene_root)
	assert_eq(mesh.get_surface_count(), 4)
	for index in range(surface_formats.size()):
		assert_eq(mesh.surface_get_format(index), surface_formats[index])
	assert_eq(history.get_version(), history_version)
	assert_eq(EditorInterface.get_selection().get_selected_nodes(), selected)


func test_native_primitive_with_generated_uv2_is_clear() -> void:
	var default_box := BoxMesh.new()
	var with_uv2 := BoxMesh.new()
	with_uv2.add_uv2 = true
	var incomplete := _add_mesh("Box", default_box)
	var complete := _add_mesh("BoxWithUV2", with_uv2)
	var both := _scan()
	assert_eq(both.get("mesh_instances_checked"), 2)
	assert_eq(both.get("triangle_surfaces_checked"), 2)
	assert_eq(both.get("total_count"), 1)
	_assert_surface(_finding(both, 0), incomplete, 0, "", ["missing_uv2"])
	var good := _scan({"path": str(_scene_root.get_path_to(complete))})
	assert_eq(good.get("path"), _path(complete))
	assert_eq(good.get("status"), "clear")
	assert_true(good.get("complete", false))
	assert_eq(good.get("triangle_surfaces_checked"), 1)
	assert_eq(good.get("findings"), [])
	assert_false(default_box.add_uv2)
	assert_true(with_uv2.add_uv2)


func test_all_scope_includes_hidden_ancestry_and_nonstatic_gi_modes() -> void:
	var mesh := BoxMesh.new()
	var visible_static := _add_mesh("Static", mesh)
	var ancestor := Node3D.new()
	ancestor.name = "Hidden"
	ancestor.hide()
	_fixture.add_child(ancestor)
	ancestor.owner = _scene_root
	var hidden_static := _add_mesh("HiddenStatic", mesh, ancestor)
	var dynamic := _add_mesh("Dynamic", mesh)
	dynamic.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	var disabled := _add_mesh("Disabled", mesh)
	disabled.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var bake := _scan()
	assert_eq(bake.get("mesh_instances_checked"), 1)
	assert_eq(bake.get("missing_surface_count"), 1)
	assert_eq(_finding(bake, 0).get("path"), _path(visible_static))
	assert_false(_finding(bake, 0).has("visible_in_tree"))
	assert_false(_finding(bake, 0).has("gi_mode"))
	assert_true(hidden_static.visible, "Only its ancestor's visibility is disabled")
	var hidden := _scan({"path": _path(hidden_static)})
	assert_eq(hidden.get("status"), "no_eligible_geometry")
	assert_eq(hidden.get("mesh_instances_checked"), 0)
	var all := _scan({"scope": "all"})
	assert_eq(all.get("scope"), "all")
	assert_eq(all.get("mesh_instances_checked"), 4)
	assert_eq(all.get("total_count"), 4)
	var nodes := [visible_static, hidden_static, dynamic, disabled]
	var modes := ["static", "static", "dynamic", "disabled"]
	for index in range(nodes.size()):
		var row := _finding(all, index)
		assert_eq(row.get("path"), _path(nodes[index]))
		assert_eq(row.get("gi_mode"), modes[index])
		assert_eq(row.get("visible_in_tree"), index != 1)


func test_reads_locked_scene_children_and_excludes_ownerless_branches() -> void:
	var instance := InstanceFixture.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	instance.name = "LockedModel"
	_fixture.add_child(instance)
	instance.owner = _scene_root
	var mesh := instance.get_node("Mesh") as MeshInstance3D
	assert_eq(mesh.owner, instance)
	assert_false(_scene_root.is_editable_instance(instance))
	var scene_path := InstanceFixture.resource_path
	var source_hash := FileAccess.get_sha256(scene_path)
	assert_false(source_hash.is_empty())
	var ownerless := Node3D.new()
	ownerless.name = "Ownerless"
	_fixture.add_child(ownerless)
	var owned_below_ownerless := _add_mesh("OwnedBelowOwnerless", BoxMesh.new(), ownerless)
	assert_eq(owned_below_ownerless.owner, _scene_root)
	var loose := _add_mesh("OwnerlessMesh", BoxMesh.new())
	loose.owner = null
	var internal := _add_mesh("OwnedInternal", BoxMesh.new(), _fixture, Node.INTERNAL_MODE_BACK)
	assert_false(_fixture.get_children().has(internal))
	assert_eq(internal.owner, _scene_root)
	var data := _scan({"scope": "all"})
	assert_eq(data.get("mesh_instances_checked"), 2)
	assert_eq(data.get("findings", []).size(), 2)
	_assert_surface(_finding(data, 0), mesh, 0, "", ["missing_uv2"])
	_assert_surface(_finding(data, 1), internal, 0, "", ["missing_uv2"])
	_assert_scan_error({"path": _path(owned_below_ownerless)}, ErrorCodes.NODE_NOT_FOUND)
	assert_eq(mesh.owner, instance)
	assert_false(_scene_root.is_editable_instance(instance))
	assert_eq(FileAccess.get_sha256(scene_path), source_hash)


func test_reports_unsupported_and_scripted_native_meshes_as_incomplete() -> void:
	var native_resources: Array[Mesh] = [ImmediateMesh.new(), ArrayMesh.new(), BoxMesh.new()]
	var placements: Array[MeshInstance3D] = []
	for index in range(native_resources.size()):
		var mesh := native_resources[index]
		if index > 0:
			var script := GDScript.new()
			script.source_code = "@tool\nextends %s\n" % mesh.get_class()
			assert_eq(script.reload(), OK)
			mesh.set_script(script)
		placements.append(_add_mesh("Unsupported%d" % index, mesh))
	var report := _scan({"scope": "all"})
	assert_eq(report.get("status"), "incomplete")
	assert_false(report.get("complete", true))
	assert_eq(report.get("mesh_instances_checked"), 0)
	assert_eq(report.get("triangle_surfaces_checked"), 0)
	assert_eq(report.get("unsupported_mesh_instances"), 3)
	assert_eq(report.get("missing_surface_count"), 0)
	assert_eq(report.get("total_count"), 3)
	for index in range(placements.size()):
		var row := _finding(report, index)
		assert_eq(row.get("kind"), "unsupported_mesh")
		assert_eq(row.get("path"), _path(placements[index]))
		assert_eq(row.get("mesh_type"), native_resources[index].get_class())
		assert_eq(row.get("mesh_path"), native_resources[index].resource_path)
		assert_eq(row.get("gi_mode"), "static")
		assert_eq(row.get("visible_in_tree"), true)
	_add_mesh("MissingUV2", BoxMesh.new())
	var mixed := _scan()
	assert_eq(mixed.get("status"), "missing_channels")
	assert_false(mixed.get("complete", true))
	assert_eq(mixed.get("mesh_instances_checked"), 1)
	assert_eq(mixed.get("unsupported_mesh_instances"), 3)
	assert_eq(mixed.get("missing_surface_count"), 1)
	assert_eq(mixed.get("total_count"), 4)


func test_skips_nontriangle_surfaces_and_null_meshes() -> void:
	var mesh := ArrayMesh.new()
	var points := []
	points.resize(Mesh.ARRAY_MAX)
	points[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT])
	for primitive in [Mesh.PRIMITIVE_LINES, Mesh.PRIMITIVE_LINE_STRIP, Mesh.PRIMITIVE_POINTS]:
		mesh.add_surface_from_arrays(primitive, points)
	_add_mesh("LinesAndPoints", mesh)
	_add_mesh("NativePointMesh", PointMesh.new())
	_add_mesh("Unassigned", null)
	var data := _scan()
	assert_eq(data.get("status"), "no_eligible_geometry")
	assert_true(data.get("complete", false))
	assert_eq(data.get("mesh_instances_checked"), 1)
	assert_eq(data.get("triangle_surfaces_checked"), 0)
	assert_eq(data.get("unsupported_mesh_instances"), 0)
	assert_eq(data.get("total_count"), 0)
	assert_eq(data.get("findings"), [])


func test_paginated_findings_keep_full_counts_and_scene_order() -> void:
	var mesh := ArrayMesh.new()
	_add_triangle(mesh, "First", true, false)
	_add_triangle(mesh, "Second", false, true)
	_add_mesh("Zebra", mesh)
	_add_mesh("Aardvark", mesh)
	var baseline := _scan()
	var rows: Array = baseline.get("findings", [])
	assert_eq(rows.size(), 4)
	assert_eq(baseline.get("offset"), 0)
	assert_eq(baseline.get("limit"), 100)
	assert_false(baseline.get("has_more", true))
	var page := _scan({"offset": 1.0, "limit": 2.0})
	assert_eq(page.get("offset"), 1)
	assert_eq(page.get("limit"), 2)
	assert_true(page.get("has_more", false))
	assert_eq(page.get("findings"), rows.slice(1, 3))
	var past_end := _scan({"offset": 9, "limit": 200})
	assert_eq(past_end.get("offset"), 9)
	assert_eq(past_end.get("limit"), 200)
	assert_false(past_end.get("has_more", true))
	assert_eq(past_end.get("findings"), [])
	for result in [page, past_end]:
		assert_eq(result.get("status"), "missing_channels")
		assert_eq(result.get("total_count"), 4)
		assert_eq(result.get("mesh_instances_checked"), 2)
		assert_eq(result.get("triangle_surfaces_checked"), 4)
		assert_eq(result.get("missing_surface_count"), 4)


func test_validates_parameters_and_existing_scene_guard() -> void:
	for params in [{"scope": 5}, {"path": []}, {"scene_file": false}, {"offset": true}, {"limit": "2"}, {"limit": 1.5}]:
		_assert_scan_error(params, ErrorCodes.WRONG_TYPE)
	for params in [{"scope": "everything"}, {"offset": -1}, {"limit": 0}, {"limit": 201}]:
		_assert_scan_error(params, ErrorCodes.VALUE_OUT_OF_RANGE)
	_assert_scan_error({"path": _path(_fixture) + "/Missing"}, ErrorCodes.NODE_NOT_FOUND)
	_assert_scan_error({"scene_file": "res://_not_the_active_lightmap_scene.tscn"}, ErrorCodes.EDITED_SCENE_MISMATCH)
	var data := _scan({"scene_file": _scene_root.scene_file_path})
	assert_eq(data.get("status"), "no_eligible_geometry")


func test_replacing_edited_scene_after_a_slice_rejects_the_scan() -> void:
	_add_mesh("First", BoxMesh.new())
	_add_mesh("Second", BoxMesh.new())
	_start_scan()
	_editor.frame.emit()
	assert_eq(_connection.replies, [], "the constrained frame leaves work pending")
	var replacement := Node3D.new()
	track(replacement)
	_editor.edited_root = replacement
	assert_is_error(_finish_scan(), ErrorCodes.EDITED_SCENE_MISMATCH)
	_editor.edited_root = _scene_root


func test_replacing_scan_root_at_same_path_rejects_the_scan() -> void:
	var selected := _add_mesh("Selected", BoxMesh.new())
	_add_mesh("Descendant", BoxMesh.new(), selected)
	_start_scan({"path": _path(selected)})
	_editor.frame.emit()
	assert_eq(_connection.replies, [])
	_fixture.remove_child(selected)
	track(selected)
	_add_mesh("Selected", BoxMesh.new())
	assert_is_error(_finish_scan(), ErrorCodes.NODE_NOT_FOUND)


func test_switching_away_and_back_before_the_next_slice_rejects_the_scan() -> void:
	_add_mesh("First", BoxMesh.new())
	_add_mesh("Second", BoxMesh.new())
	_start_scan()
	_editor.frame.emit()
	assert_eq(_connection.replies, [])
	_editor.scene_changed.emit(null)
	_editor.scene_changed.emit(_scene_root)
	assert_is_error(_finish_scan(), ErrorCodes.EDITED_SCENE_MISMATCH)


func test_lost_request_releases_the_scan_without_sending_a_reply() -> void:
	_add_mesh("First", BoxMesh.new())
	_add_mesh("Second", BoxMesh.new())
	var work_before := ScriptWork.active_count(COMMAND)
	_start_scan()
	_editor.frame.emit()
	assert_eq(_connection.replies, [])
	_dispatcher.clear_deferred_responses()
	_editor.frame.emit()
	assert_eq(_connection.replies, [])
	assert_eq(ScriptWork.active_count(COMMAND), work_before)
	var retry := _scan()
	assert_eq(retry.get("missing_surface_count"), 2)


func _step_frames(count: int) -> void:
	for i in count:
		_editor.frame.emit()
	assert_eq(_connection.replies, [], "mutation must happen during the scan")


func _step_to_publication() -> void:
	var job = _dispatcher._lazy_handler_cache[COMMAND]._jobs.front()
	for frame in 40:
		if job.stack.is_empty():
			break
		_editor.frame.emit()
	assert_true(job.stack.is_empty())
	assert_eq(_connection.replies, [], "mutation must happen before publication")


func _assert_retry() -> void:
	var response := _finish_scan()
	assert_is_error(response, ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_true(response.get("error", {}).get("data", {}).get("retryable", false))
	assert_false(response.has("data"), "no partial report")


func test_reparenting_a_queued_mesh_out_of_scope_refuses_partial_report() -> void:
	var wall := _add_mesh("Wall", BoxMesh.new())
	var other := Node3D.new()
	_scene_root.add_child(other)
	track(other)
	_start_scan()
	_step_frames(2)
	wall.reparent(other)
	_assert_retry()


func test_deleting_placement_after_first_finding_refuses_partial_counts() -> void:
	var wall := _add_mesh("Wall", BoxMesh.new())
	_start_scan()
	_step_frames(4)
	wall.free()
	_assert_retry()


func test_deleting_placement_before_publication_refuses_stale_report() -> void:
	var wall := _add_mesh("Wall", BoxMesh.new())
	_start_scan()
	_step_to_publication()
	wall.free()
	_assert_retry()


func test_reordering_siblings_during_scan_rejects_shifted_child_index() -> void:
	_add_mesh("First", PointMesh.new())
	var wall := _add_mesh("Wall", BoxMesh.new())
	_start_scan()
	_step_frames(4)
	_fixture.move_child(wall, 0)
	_assert_retry()
	assert_eq(_scan().get("missing_surface_count"), 1)


func test_renaming_visited_ancestor_refuses_stale_finding_path() -> void:
	var group := Node3D.new()
	group.name = "Room"
	_fixture.add_child(group)
	group.owner = _scene_root
	var wall := _add_mesh("Wall", BoxMesh.new(), group)
	_start_scan()
	_step_frames(6)
	group.name = "Hall"
	_assert_retry()
	assert_eq(_finding(_scan(), 0).get("path"), _path(wall))


func test_replacing_placement_mesh_before_publication_refuses_stale_channels() -> void:
	var clean := BoxMesh.new()
	clean.add_uv2 = true
	var wall := _add_mesh("Wall", clean)
	_start_scan()
	_step_to_publication()
	wall.mesh = BoxMesh.new()
	_assert_retry()
	assert_eq(_scan().get("missing_surface_count"), 1)


func test_clearing_placement_mesh_mid_read_refuses_partial_report() -> void:
	var old := ArrayMesh.new()
	_add_triangle(old, "Complete", true, true)
	_add_triangle(old, "Trim", true, false)
	var wall := _add_mesh("Wall", old)
	_start_scan()
	_step_frames(4)
	wall.mesh = null
	_assert_retry()
	assert_eq(_scan().get("mesh_instances_checked"), 0)


func test_filling_empty_mesh_slot_before_publication_refuses_stale_counts() -> void:
	var wall := _add_mesh("Wall", null)
	_start_scan()
	_step_to_publication()
	wall.mesh = BoxMesh.new()
	_assert_retry()
	assert_eq(_scan().get("triangle_surfaces_checked"), 1)


func test_unchanged_placement_mesh_ignores_property_list_notification() -> void:
	var wall := _add_mesh("Wall", BoxMesh.new())
	var connections_before := wall.property_list_changed.get_connections().size()
	_start_scan()
	_step_to_publication()
	wall.notify_property_list_changed()
	var response := _finish_scan()
	assert_eq(response.get("data", {}).get("missing_surface_count"), 1)
	assert_eq(wall.property_list_changed.get_connections().size(), connections_before)


func test_bake_scan_ignores_mesh_replacement_on_an_excluded_placement() -> void:
	var wall := _add_mesh("Wall", BoxMesh.new())
	wall.hide()
	_start_scan()
	_step_to_publication()
	wall.mesh = BoxMesh.new()
	var response := _finish_scan()
	assert_eq(response.get("data", {}).get("status"), "no_eligible_geometry")


func test_changing_a_shared_primitive_rejects_cached_channels() -> void:
	var mesh := BoxMesh.new()
	mesh.add_uv2 = true
	_add_mesh("First", mesh)
	_add_mesh("Second", mesh)
	_start_scan()
	_step_frames(5)
	mesh.add_uv2 = false
	_assert_retry()
	assert_eq(_scan().get("missing_surface_count"), 2)


func test_removing_an_array_surface_mid_read_rejects_mixed_formats() -> void:
	var mesh := ArrayMesh.new()
	_add_triangle(mesh, "Complete", true, true)
	_add_triangle(mesh, "Trim", true, false)
	_add_mesh("Wall", mesh)
	_start_scan()
	_step_frames(4)
	mesh.surface_remove(0)
	_assert_retry()
	var fresh := _scan()
	assert_eq(_finding(fresh, 0).get("surface_name"), "Trim")
	assert_eq(_finding(fresh, 0).get("surface_index"), 0)


func test_silent_mesh_clear_before_publication_refuses_stale_report() -> void:
	var first := ArrayMesh.new()
	_add_triangle(first, "First", true, false)
	_add_mesh("First", first)
	_add_mesh("Other", BoxMesh.new())
	_start_scan()
	_step_to_publication()
	first.clear_surfaces()
	_assert_retry()


func test_teardown_releases_a_partially_scanned_array_mesh_without_reply() -> void:
	var mesh := ArrayMesh.new()
	for index in range(24):
		_add_triangle(mesh, "Surface%d" % index, false, false)
	_add_mesh("Mesh", mesh)
	var work_before := ScriptWork.active_count(COMMAND)
	_start_scan()
	for frame in range(6):
		_editor.frame.emit()
	assert_eq(_connection.replies, [])
	assert_eq(ScriptWork.active_count(COMMAND), work_before + 1)
	_dispatcher.release_after_teardown()
	_connection.dispatcher = null
	_editor.frame.emit()
	assert_eq(_connection.replies, [])
	assert_eq(ScriptWork.active_count(COMMAND), work_before)
	assert_eq(mesh.get_surface_count(), 24)
