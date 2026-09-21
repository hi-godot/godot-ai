@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const NavigationHandler := preload("res://addons/godot_ai/handlers/navigation_handler.gd")

## Tests for NavigationHandler — baking and explicit-map path queries.
##
## The bake is threaded and deferred in production; these tests drive the same
## `_bake_job`/`_bake_step` API the frame-loop driver uses, so no frames are
## awaited (a test body cannot await — the runner calls it synchronously).
##
## NOTE: GDScript tests must not call save_scene, scene_create, scene_open,
## quit_editor, or reload_plugin (see CLAUDE.md Known Issues).

var _handler: NavigationHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "navigation"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = NavigationHandler.new(_undo_redo)


func suite_teardown() -> void:
	## A failed test must not leave a region reserved for later tests.
	NavigationHandler._active_bakes.clear()
	if _undo_redo != null:
		_undo_redo.clear_history()


# ----- helpers -----

func _add_child_node(parent: Node, node: Node, node_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	node.name = node_name
	parent.add_child(node)
	node.set_owner(scene_root)
	return node


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


## Build a NavigationRegion3D/2D with a fresh mesh/polygon under the edited
## scene root. Fixture for the bake/path tests; region creation itself is not
## an op (dsarno's scope recommendation — compose node_create + set_property).
func _make_region(dimension: String, region_name: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	if dimension == "3d":
		var region := NavigationRegion3D.new()
		region.navigation_mesh = NavigationMesh.new()
		return _add_child_node(scene_root, region, region_name)
	var region_2d := NavigationRegion2D.new()
	region_2d.navigation_polygon = NavigationPolygon.new()
	return _add_child_node(scene_root, region_2d, region_name)


func _make_box_mesh(size: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	return mesh


func _make_polygon_2d(size: float) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-size, -size), Vector2(size, -size), Vector2(size, size), Vector2(-size, size),
	])
	return poly


## Prepare + drive one bake job through the same commit path production uses.
##
## A test body runs synchronously (the runner calls it without awaiting), so it
## cannot yield the engine frame that clears `is_baking()` for a threaded 3D
## bake. The helper therefore bakes synchronously into the job's working
## resource, then lets `_bake_step` commit the scene-anchored swap. The threaded
## start phase has its own test below; the full deferred frame loop is covered
## by the live MCP smoke. `connection` may be null (no dispatcher checks).
func _run_bake_job(region: Node, dimension: String, force_sync := false, connection = null) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	var prepared := NavigationHandler._begin_bake(region, dimension)
	assert_false(prepared.is_empty(), "bake setup must produce before/working resources")
	var job := NavigationHandler._bake_job(
		region, dimension, scene_root, prepared.before, prepared.working,
		_undo_redo, connection, "rid-nav-bake", force_sync
	)
	if dimension == "3d":
		region.call("bake_navigation_mesh", false)
	else:
		region.call("bake_navigation_polygon", false)
	job.phase = "baking"
	assert_true(NavigationHandler._bake_step(job), "the commit step must resolve the job")
	assert_eq(str(job.phase), "done", "the bake job must settle")
	return job


# ----- bake -----

func test_bake_second_request_is_refused_while_the_first_is_in_flight() -> void:
	## dsarno's probe: two bake calls before the next frame were both accepted
	## (the region's is_baking() only flips once the first step calls bake_*,
	## which happens after a frame), so both jobs split the same mesh. `bake`
	## reserves the region before the driver starts; a second request must be
	## refused even though no step has run yet.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeAdmission") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var region_path := McpScenePath.from_node(region, scene_root)
	var connection := _AdmissionProbeConnection.new(region.get_instance_id())
	var handler := NavigationHandler.new(_undo_redo, connection)
	var first := handler.bake({"path": region_path, "_request_id": "rid-first"})
	assert_has_key(first, "_deferred")
	assert_true(connection.reserved_when_driver_started,
		"bake must reserve the region before the driver starts")
	## The probe's null tree makes the driver release the reservation.
	assert_true(NavigationHandler._active_bakes.is_empty(),
		"a driver that cannot run must release the reservation")
	## While a request is in flight, the same region must refuse a second one.
	NavigationHandler._active_bakes[region.get_instance_id()] = "rid-inflight"
	var second := handler.bake({"path": region_path, "_request_id": "rid-second"})
	assert_is_error(second, ErrorCodes.INVALID_PARAMS)
	assert_contains(second.error.message, "already baking")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "a refused bake must not touch the mesh")
	NavigationHandler._active_bakes.erase(region.get_instance_id())
	_remove_node(region)


func test_bake_direct_call_is_refused() -> void:
	## The bake is deferred and threaded; a direct (batch/test) caller cannot
	## await it, so the op must refuse rather than silently bake in place.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavDirectRefused") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var result := _handler.bake({"path": McpScenePath.from_node(region, scene_root)})
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "deferred")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "a refused direct call must not bake")
	assert_false(region.is_baking(), "a refused direct call must not start a bake")
	assert_true(NavigationHandler._active_bakes.is_empty(), "a refused call must not reserve the region")
	_remove_node(region)


func test_bake_job_start_phase_starts_a_threaded_bake() -> void:
	## The production start phase must hand the bake to the region's own
	## background thread and report "still baking" to the frame driver.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeThreaded") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, null, "", false
	)
	assert_false(NavigationHandler._bake_step(job), "the start step must not resolve immediately")
	assert_eq(str(job.phase), "baking")
	assert_true(region.is_baking(), "the region must report a background bake in progress")
	assert_true(int(job.parse_ms) >= 0, "the start step must record the source-parse duration")
	## Abandon it: the worker holds its own mesh reference and finishes on a
	## later engine frame, which this test deliberately does not wait for.
	_remove_node(region)


func test_bake_region_freed_mid_job_aborts_cleanly() -> void:
	## dsarno's probe: a freed region raised "Trying to assign invalid
	## previously freed instance" at the typed assignment in `_bake_step`
	## before its validity check (and in `_bake_restore`). Both must read the
	## region untyped, validate, and abort without a script error.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeFreed") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, null, "", false
	)
	region.get_parent().remove_child(region)
	region.free()
	assert_true(NavigationHandler._bake_step(job), "a freed region must end the job")
	assert_is_error(job.result, ErrorCodes.NODE_NOT_FOUND)
	## And the restore path must tolerate the freed region too.
	NavigationHandler._bake_restore(job)
	assert_true(NavigationHandler._active_bakes.is_empty(), "the reservation must be released")


func test_bake_replaced_resource_is_not_clobbered() -> void:
	## dsarno's probe: a direct `_bake_restore` overwrote a newer resource
	## assignment with the old job's resource. Both the restore and the commit
	## must only act while the region still holds this job's working duplicate.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeReplaced") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, null, "", false
	)
	var replacement := NavigationMesh.new()
	region.navigation_mesh = replacement
	NavigationHandler._bake_restore(job)
	assert_eq(region.navigation_mesh, replacement, "restore must not clobber a newer resource")
	job.phase = "baking"
	assert_true(NavigationHandler._bake_step(job), "a replaced resource must end the job")
	assert_is_error(job.result, ErrorCodes.RESOURCE_NOT_FOUND)
	assert_eq(region.navigation_mesh, replacement, "the commit must not clobber the replacement")
	assert_true(NavigationHandler._active_bakes.is_empty(), "the reservation must be released")
	_remove_node(region)


func test_bake_abandoned_after_replacement_keeps_the_new_resource() -> void:
	## The dispatcher abandons the request after the mesh was replaced: the
	## stale job must not overwrite the newer assignment on its way out.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeAbandonReplace") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, _GoneConnection.new(), "rid-abandon-replace", false
	)
	var replacement := NavigationMesh.new()
	region.navigation_mesh = replacement
	NavigationHandler._bake_step(job)
	assert_true(NavigationHandler._bake_step(job), "an abandoned request must end")
	assert_true(job.result.is_empty(), "nothing may be answered for an abandoned request")
	assert_eq(region.navigation_mesh, replacement,
		"an abandoned bake must not clobber a newer resource")
	assert_true(NavigationHandler._active_bakes.is_empty(), "the reservation must be released")
	_remove_node(region)


func test_bake_does_not_step_before_the_dispatcher_registers() -> void:
	## The dispatcher registers the deferred request only after `bake` returns
	## the sentinel. Stepping the job synchronously would run the pending check
	## against an unregistered request and abandon the bake (the op then times
	## out with no response), so `bake` must leave the first step to
	## `_drive_bake_job` after its registration yield.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeOrdering") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var connection := _RecordingConnection.new()
	var handler := NavigationHandler.new(_undo_redo, connection)
	var deferred := handler.bake({
		"path": McpScenePath.from_node(region, scene_root),
		"_request_id": "rid-ordering",
	})
	assert_has_key(deferred, "_deferred")
	assert_eq(int(deferred.get("_deferred_timeout_ms", 0)), 30000)
	assert_eq(
		connection.pending_checks, 0,
		"bake must not run a pending check before the dispatcher registers the request"
	)
	assert_true(NavigationHandler._active_bakes.is_empty(),
		"the null-tree driver must release the reservation")
	_remove_node(region)


func test_bake_3d_produces_polygons_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBake3D") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var job := _run_bake_job(region, "3d")
	assert_has_key(job.result, "data")
	assert_true(job.result.data.polygon_count > 0,
		"baking a 20x20 box floor must produce polygons, got %d" % job.result.data.polygon_count)
	assert_true(job.result.data.vertex_count > 0, "baked polygons must have vertices")
	assert_eq(job.result.data.bake_settle, "settled")
	assert_true(job.result.data.has("parse_ms"), "the result must report the source-parse duration")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "undo must restore the pre-bake mesh")
	assert_true(NavigationHandler._active_bakes.is_empty(), "a committed bake must release the reservation")
	_remove_node(region)


func test_bake_undo_redo_restores_prebake_state() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeCycle") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var job := _run_bake_job(region, "3d")
	assert_has_key(job.result, "data")
	assert_true(job.result.data.polygon_count > 0, "bake must produce polygons")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0, "undo restores the pre-bake mesh")
	var did_redo := editor_redo(_undo_redo)
	assert_true(did_redo, "redo should succeed")
	assert_eq(
		region.navigation_mesh.get_polygon_count(), job.result.data.polygon_count,
		"redo restores the baked mesh"
	)
	## A second undo must still reach the pre-bake state: neither the redo nor
	## the commit may have mutated the resource the undo action restores.
	did_undo = editor_undo(_undo_redo)
	assert_true(did_undo, "the second undo should succeed")
	assert_eq(
		region.navigation_mesh.get_polygon_count(), 0,
		"the second undo must still restore the pre-bake mesh"
	)
	_remove_node(region)


func test_bake_redo_restores_exact_baked_vertices() -> void:
	## Redo must swap in the retained baked resource, not re-bake current
	## geometry: an external source translation between undo and redo would
	## change the vertices of a re-bake.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeExact") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	var floor := _add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var job := _run_bake_job(region, "3d")
	assert_has_key(job.result, "data")
	assert_true(job.result.data.polygon_count > 0, "bake must produce polygons")
	var baked_vertices: PackedVector3Array = region.navigation_mesh.get_vertices()
	assert_true(baked_vertices.size() > 0, "baked mesh must have vertices")
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0)
	## External source change while the pre-bake state is restored.
	floor.position = Vector3(37.0, 5.0, -11.0)
	var did_redo := editor_redo(_undo_redo)
	assert_true(did_redo, "redo should succeed")
	assert_eq(
		region.navigation_mesh.get_polygon_count(), job.result.data.polygon_count,
		"redo must restore the baked polygon count"
	)
	assert_eq(
		region.navigation_mesh.get_vertices(), baked_vertices,
		"redo must restore the exact baked vertices, not re-bake moved geometry"
	)
	_remove_node(region)


func test_bake_action_lands_in_scene_history() -> void:
	## dsarno: the action must be scene-anchored. A RefCounted handler target
	## would select the global history and a scene undo would target a
	## preceding unrelated action instead.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeHistory") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var job := _run_bake_job(region, "3d")
	assert_has_key(job.result, "data")
	assert_true(job.result.data.polygon_count > 0, "bake must produce polygons")

	var scene_id := _undo_redo.get_object_history_id(scene_root)
	assert_eq(
		_undo_redo.get_object_history_id(region), scene_id,
		"the bake action's target must resolve to the edited scene's history"
	)
	var scene_undo_redo := _undo_redo.get_history_undo_redo(scene_id)
	assert_true(scene_undo_redo != null, "the scene history must exist")
	assert_true(scene_undo_redo.undo(), "a scene undo must resolve the bake action")
	assert_eq(
		region.navigation_mesh.get_polygon_count(), 0,
		"the scene undo must target the bake action"
	)
	assert_true(region.is_inside_tree(), "the fixture region must stay in the scene")
	_remove_node(region)


func test_bake_job_abandoned_by_the_dispatcher_leaves_nothing_behind() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	_undo_redo.clear_history()
	var region := _make_region("3d", "NavBakeAbandoned") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	_undo_redo.clear_history()
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var connection := _GoneConnection.new()
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, connection, "rid-abandoned", false
	)
	NavigationHandler._bake_step(job)
	assert_true(NavigationHandler._bake_step(job), "an abandoned request must end")
	assert_true(job.result.is_empty(), "nothing may be answered for an abandoned request")
	assert_eq(region.navigation_mesh, prepared.before, "the pre-bake resource must be restored")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0)
	assert_false(editor_undo(_undo_redo), "an abandoned bake must not leave an undo action")
	assert_true(NavigationHandler._active_bakes.is_empty(), "the reservation must be released")
	_remove_node(region)


func test_bake_job_deadline_restores_prebake_mesh() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavBakeDeadline") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_box_mesh(Vector3(20, 1, 20)), "Floor")
	var prepared := NavigationHandler._begin_bake(region, "3d")
	var job := NavigationHandler._bake_job(
		region, "3d", scene_root, prepared.before, prepared.working,
		_undo_redo, null, "", false
	)
	## Simulate a bake that overruns its budget before it can start.
	job.started_ms = Time.get_ticks_msec() - 1000
	job.deadline_ms = 1
	assert_true(NavigationHandler._bake_step(job), "the deadline check must end the job")
	assert_is_error(job.result, ErrorCodes.DEFERRED_TIMEOUT)
	assert_eq(region.navigation_mesh, prepared.before, "the pre-bake resource must be restored")
	assert_eq(region.navigation_mesh.get_polygon_count(), 0)
	assert_true(NavigationHandler._active_bakes.is_empty(), "the reservation must be released")
	_remove_node(region)


func test_bake_2d_job_reports_and_undoes() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("2d", "NavBake2D") as NavigationRegion2D
	assert_true(region != null, "fixture must exist")
	_add_child_node(region, _make_polygon_2d(10.0), "Floor")
	region.navigation_polygon.cell_size = 1.0
	region.navigation_polygon.agent_radius = 1.0
	_undo_redo.clear_history()
	var job := _run_bake_job(region, "2d")
	assert_has_key(job.result, "data")
	assert_eq(job.result.data.mesh_class, "NavigationPolygon")
	assert_true(job.result.data.polygon_count >= 0, "bake must report a polygon count")
	## 2D bake output can be empty until the navigation server processes a
	## physics frame in the editor; the undo contract holds either way.
	var did_undo := editor_undo(_undo_redo)
	assert_true(did_undo, "undo should succeed")
	assert_eq(region.navigation_polygon.get_polygon_count(), 0, "undo must restore the pre-bake polygon")
	_remove_node(region)


func test_navigation_node_wrong_type_and_dimension() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var plain := Node3D.new()
	_add_child_node(scene_root, plain, "NavNotANode")
	var wrong := _handler.bake({"path": "/" + scene_root.name + "/NavNotANode"})
	assert_is_error(wrong, ErrorCodes.WRONG_TYPE)
	assert_contains(wrong.error.message, "navigation region")
	var bad_dimension := _handler.path_get({
		"from_point": [0.0, 0.0],
		"to_point": [1.0, 1.0],
		"dimension": "4d",
	})
	assert_is_error(bad_dimension, ErrorCodes.VALUE_OUT_OF_RANGE)
	_remove_node(plain)


# ----- path_get -----

## The editor's navigation map only processes geometry on physics frames, so a
## path query right after a bake can legitimately return an empty path here.
## This asserts the read-only response contract; live games get the baked path.
func test_path_get_returns_response_shape() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var result := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
	})
	assert_has_key(result, "data")
	assert_eq(result.data.dimension, "3d")
	assert_true(result.data.point_count >= 0, "point_count must be a count")
	assert_eq(result.data.point_count, result.data.points.size())
	assert_eq(result.data.map_source, "world", "no region_path must fall back to the world map")
	assert_eq(result.data.region_path, "")
	assert_false(result.data.force_sync)
	assert_false(result.data.has("undoable"), "path_get is read-only")
	var region_2d := _make_region("2d", "NavPathMap2D") as NavigationRegion2D
	assert_true(region_2d != null, "fixture must exist")
	## A 3D-rooted scene has no 2D world map, so a 2D query must name the region.
	var two_d := _handler.path_get({
		"dimension": "2d",
		"from_point": [-8.0, -8.0],
		"to_point": [8.0, 8.0],
		"region_path": McpScenePath.from_node(region_2d, scene_root),
	})
	assert_has_key(two_d, "data")
	assert_eq(two_d.data.dimension, "2d")
	assert_eq(two_d.data.map_source, "region")
	assert_eq(two_d.data.point_count, two_d.data.points.size())
	_remove_node(region_2d)


func test_path_get_region_path_selects_the_region_map() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavPathRegion3D") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	var region_path := McpScenePath.from_node(region, scene_root)
	var result := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
		"region_path": region_path,
	})
	assert_has_key(result, "data")
	assert_eq(result.data.map_source, "region")
	assert_eq(result.data.region_path, region_path)
	## A region of the other dimension must be refused, not silently ignored.
	var wrong_dimension := _handler.path_get({
		"dimension": "2d",
		"from_point": [-8.0, -8.0],
		"to_point": [8.0, 8.0],
		"region_path": region_path,
	})
	assert_is_error(wrong_dimension, ErrorCodes.WRONG_TYPE)
	assert_contains(wrong_dimension.error.message, "NavigationRegion2D")
	var missing := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
		"region_path": "/Does/Not/Exist",
	})
	assert_is_error(missing, ErrorCodes.NODE_NOT_FOUND)
	var not_a_region := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
		"region_path": "/" + scene_root.name,
	})
	assert_is_error(not_a_region, ErrorCodes.WRONG_TYPE)
	_remove_node(region)


func test_path_get_force_sync_restores_async_map_policy() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		skip("No scene root")
		return
	var region := _make_region("3d", "NavPathForceSync") as NavigationRegion3D
	assert_true(region != null, "fixture must exist")
	var region_path := McpScenePath.from_node(region, scene_root)
	var map: RID = region.get_navigation_map()
	assert_true(map.is_valid(), "region must have a navigation map")
	## The server applies map policy changes on its next flush.
	NavigationServer3D.map_set_use_async_iterations(map, true)
	NavigationServer3D.map_force_update(map)
	assert_true(NavigationServer3D.map_get_use_async_iterations(map), "test setup must enable async iterations")

	var plain := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
		"region_path": region_path,
	})
	assert_has_key(plain, "data")
	assert_false(plain.data.force_sync)
	NavigationServer3D.map_force_update(map)
	assert_true(
		NavigationServer3D.map_get_use_async_iterations(map),
		"a default query must never touch the shared async-iteration policy"
	)

	var synced := _handler.path_get({
		"from_point": {"x": -8.0, "y": 0.5, "z": -8.0},
		"to_point": {"x": 8.0, "y": 0.5, "z": 8.0},
		"region_path": region_path,
		"force_sync": true,
	})
	assert_has_key(synced, "data")
	assert_true(synced.data.force_sync)
	NavigationServer3D.map_force_update(map)
	assert_true(
		NavigationServer3D.map_get_use_async_iterations(map),
		"force_sync must restore the previous async-iteration policy"
	)
	_remove_node(region)


func test_path_get_rejects_bad_points() -> void:
	var bad_from := _handler.path_get({"from_point": {"x": 1.0}, "to_point": {"x": 2.0, "y": 3.0, "z": 4.0}})
	assert_is_error(bad_from, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_from.error.message, "from_point")
	var bad_to := _handler.path_get({
		"from_point": {"x": 1.0, "y": 2.0, "z": 3.0},
		"to_point": "nowhere",
	})
	assert_is_error(bad_to, ErrorCodes.WRONG_TYPE)
	assert_contains(bad_to.error.message, "to_point")


# ----- fixtures -----

class _GoneDispatcher:
	extends RefCounted

	func has_pending_deferred_response(_request_id: String) -> bool:
		return false


class _GoneConnection:
	extends RefCounted

	var dispatcher = null


	func _init() -> void:
		dispatcher = _GoneDispatcher.new()


class _RecordingDispatcher:
	extends RefCounted

	var owner = null


	func _init(p_owner) -> void:
		owner = p_owner


	func has_pending_deferred_response(_request_id: String) -> bool:
		owner.pending_checks += 1
		return true


class _RecordingConnection:
	extends RefCounted

	var dispatcher = null
	var pending_checks := 0


	func _init() -> void:
		dispatcher = _RecordingDispatcher.new(self)


	func get_tree() -> SceneTree:
		## Null so `_drive_bake_job` returns before registering its ScriptWork
		## entry: a synchronous suite run cannot yield the frame that would
		## release it, and dispatcher quiescence tests would then fail on a
		## leaked "navigation_bake" entry. The ordering contract under test is
		## the synchronous part of `bake`, before the driver yields.
		return null


## Records whether `bake` had already reserved the region when the driver
## started (the driver calls `get_tree` right after the reservation and before
## its first yield), then returns null so the driver releases the reservation
## without registering a ScriptWork entry.
class _AdmissionProbeConnection:
	extends RefCounted

	var dispatcher = null
	var region_id := 0
	var reserved_when_driver_started := false


	func _init(p_region_id: int) -> void:
		region_id = p_region_id


	func has_pending_deferred_response(_request_id: String) -> bool:
		return true


	func get_tree() -> SceneTree:
		reserved_when_driver_started = NavigationHandler._active_bakes.has(region_id)
		return null
