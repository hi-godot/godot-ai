@tool
extends McpTestSuite

const BatchHandler := preload("res://addons/godot_ai/handlers/batch_handler.gd")
const CsgHandler := preload("res://addons/godot_ai/handlers/csg_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const Source := preload("res://tests/fixtures/csg_bake_source.tscn")
const EXTERNAL_SURFACE := "res://tests/fixtures/csg_bake_surface.tres"
const COMMAND := "csg_bake_mesh"
const REQUEST_ID := "csg-bake-test"

signal bake_frame


class _CapturingConnection extends McpConnection:
	var responses: Array[Dictionary] = []

	func _ready() -> void:
		set_process(false)

	func _send_json(data: Dictionary, _allow_pre_auth := false) -> bool:
		responses.append(data)
		return true


var _undo_redo: EditorUndoRedoManager
var _scene_root: Node
var _fixture_parent: Node3D
var _dispatcher: McpDispatcher
var _connection: _CapturingConnection
var _handler: CsgHandler
var _directory: String
var _outputs: Array[String] = []


func suite_name() -> String:
	return "csg_bake"


func suite_setup(ctx: Dictionary) -> void:
	_scene_root = EditorInterface.get_edited_scene_root()
	if not _scene_root is Node3D:
		skip_suite("A 3D edited scene is required")
		return
	_undo_redo = ctx.get("undo_redo")


func setup() -> void:
	_directory = "res://_mcp_test_csg_bake_%d" % Time.get_ticks_usec()
	_fixture_parent = track(Node3D.new())
	_fixture_parent.name = "_McpTestCsgBake"
	_scene_root.add_child(_fixture_parent, true)
	_dispatcher = McpDispatcher.new(McpLogBuffer.new())
	_dispatcher.mcp_logging = false
	_connection = track(_CapturingConnection.new())
	_connection.dispatcher = _dispatcher
	EditorInterface.get_base_control().add_child(_connection)
	_handler = CsgHandler.new(_undo_redo, _connection, bake_frame)
	_dispatcher.register(COMMAND, _handler.bake_mesh)


func teardown() -> void:
	## Flush any request left pending by a failed assertion as a cancelled job.
	_dispatcher.clear_deferred_responses()
	bake_frame.emit()
	_dispatcher.release_after_teardown()
	_connection.dispatcher = null
	_handler = null
	for path in _outputs:
		for file in [path, path + ".uid"]:
			if FileAccess.file_exists(file):
				assert_eq(DirAccess.remove_absolute(file), OK)
	_outputs.clear()
	if DirAccess.dir_exists_absolute(_directory):
		assert_eq(DirAccess.remove_absolute(_directory), OK)


func _output(name: String) -> String:
	var path := _directory.path_join(name)
	_outputs.append(path)
	return path


func _add_source(node: Node3D, source_name: String) -> Node3D:
	track(node)
	node.name = source_name
	_fixture_parent.add_child(node)
	node.owner = _scene_root
	return node


func _scene_path(node: Node) -> String:
	return McpScenePath.from_node(node, _scene_root)


func _enqueue(params: Dictionary) -> Array[Dictionary]:
	_dispatcher.enqueue({"command": COMMAND, "request_id": REQUEST_ID, "params": params})
	return _dispatcher.tick(100.0)


func _begin(params: Dictionary) -> void:
	assert_eq(_enqueue(params), [], "Bake should wait for the next editor frame")
	assert_true(_dispatcher.has_pending_deferred_response(REQUEST_ID))
	assert_false(FileAccess.file_exists(params.resource_path), "No output before the frame wait")


func _finish(shape: CSGShape3D = null) -> Dictionary:
	## The runner is synchronous. Run the engine's queued CSG refresh before
	## emitting the manual signal that represents the next editor frame.
	if shape != null:
		shape.call("_update_shape")
	bake_frame.emit()
	assert_false(_dispatcher.has_pending_deferred_response(REQUEST_ID))
	assert_eq(_connection.responses.size(), 1)
	var response: Dictionary = _connection.responses.front() if not _connection.responses.is_empty() else {}
	assert_eq(response.get("request_id"), REQUEST_ID)
	assert_has_key(response, "readiness")
	return response


func _can_refresh_fixture(shape: CSGShape3D) -> bool:
	if shape.has_method("_update_shape"):
		return true
	skip("This custom engine build omits the synchronous CSG update binding")
	return false


func _baked_mesh(
	response: Dictionary, node: CSGShape3D, output: String, override_applied: bool
) -> ArrayMesh:
	assert_eq(response.get("status"), "ok", str(response))
	var data: Dictionary = response.get("data", {})
	assert_eq(data.get("path"), _scene_path(node))
	assert_eq(data.get("resource_path"), output)
	assert_eq(data.get("undoable"), false)
	assert_false(str(data.get("reason", "")).is_empty())
	assert_eq(data.get("material_override_applied"), override_applied)
	assert_true(FileAccess.file_exists(output))
	if not FileAccess.file_exists(output):
		return null
	var mesh := ResourceLoader.load(output, "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	assert_true(mesh != null, "The saved resource must reload as an ArrayMesh")
	if mesh != null:
		assert_eq(data.get("surface_count"), mesh.get_surface_count())
		assert_gt(mesh.get_surface_count(), 0)
		assert_gt(mesh.get_faces().size(), 0)
	return mesh


func _write_existing_file(path: String) -> void:
	assert_eq(DirAccess.make_dir_recursive_absolute(path.get_base_dir()), OK)
	var existing := StandardMaterial3D.new()
	existing.albedo_color = Color.DARK_ORANGE
	assert_eq(ResourceSaver.save(existing, path), OK)


func test_bakes_native_boolean_geometry_in_root_local_space_without_scene_changes() -> void:
	var parent := _add_source(Node3D.new(), "_McpTestCsgBakeParent")
	parent.position = Vector3(30, 12, 5)
	parent.rotation.y = 0.7
	parent.scale = Vector3(2, 3, 1)
	var shape := Source.instantiate() as CSGCombiner3D
	parent.add_child(shape)
	shape.owner = _scene_root
	if not _can_refresh_fixture(shape):
		return
	shape.position = Vector3(4, 5, 6)
	shape.rotation.z = 0.4
	shape.scale = Vector3(1.5, 2.0, 3.0)
	var inline := (shape.get_node("Base") as CSGBox3D).material
	var external := (shape.get_node("Extension") as CSGBox3D).material
	var root_override := shape.material_override
	var inline_path := inline.resource_path
	var override_path := root_override.resource_path
	assert_contains(inline_path, Source.resource_path + "::")
	assert_contains(override_path, Source.resource_path + "::")
	assert_eq(external.resource_path, EXTERNAL_SURFACE)
	var scene_history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(_scene_root))
	var global_history := _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	var scene_version := scene_history.get_version()
	var global_version := global_history.get_version()
	var open_scenes := EditorInterface.get_open_scenes()
	var selection := EditorInterface.get_selection().get_selected_nodes()
	var children := _scene_root.get_children()
	var operands := shape.get_children()
	var original_transform := shape.transform
	var scene_file := _scene_root.scene_file_path
	var scene_sha := FileAccess.get_sha256(scene_file) if FileAccess.file_exists(scene_file) else ""

	var output := _output("solid.tres")
	_begin({"path": _scene_path(shape), "resource_path": output, "scene_file": scene_file})
	var mesh := _baked_mesh(_finish(shape), shape, output, false)
	if mesh == null:
		assert_true(false, "The native bake must save a mesh")
		return

	assert_true(mesh.get_aabb().is_equal_approx(AABB(Vector3(-2, -2, -2), Vector3(5, 4, 4))))
	var native := shape.bake_static_mesh()
	assert_eq(mesh.get_surface_count(), native.get_surface_count())
	assert_eq(mesh.get_faces(), native.get_faces(), "The union and the bore must match native CSG")
	var found_inline := false
	var found_external := false
	for i in mini(mesh.get_surface_count(), native.get_surface_count()):
		assert_eq(mesh.surface_get_arrays(i), native.surface_get_arrays(i))
		var baked_material := mesh.surface_get_material(i)
		var native_material := native.surface_get_material(i)
		if native_material == inline:
			found_inline = true
			assert_true(baked_material is StandardMaterial3D)
			if baked_material is StandardMaterial3D:
				assert_eq(baked_material.albedo_color, (inline as StandardMaterial3D).albedo_color)
				assert_contains(baked_material.resource_path, output + "::")
		elif native_material == external:
			found_external = true
			assert_eq(baked_material, external, "External materials should stay shared references")
		else:
			assert_eq(baked_material, native_material)
	assert_true(found_inline and found_external, "Both live material surfaces should survive")
	assert_eq(inline.resource_path, inline_path)
	assert_eq(root_override.resource_path, override_path)
	assert_eq(external.resource_path, EXTERNAL_SURFACE)
	assert_eq(shape.material_override, root_override)
	assert_eq((shape.get_node("Base") as CSGBox3D).material, inline)
	assert_eq((shape.get_node("Extension") as CSGBox3D).material, external)
	assert_eq(shape.get_children(), operands)
	assert_eq(shape.owner, _scene_root)
	assert_eq(shape.transform, original_transform)
	assert_eq(EditorInterface.get_edited_scene_root(), _scene_root)
	assert_eq(EditorInterface.get_open_scenes(), open_scenes)
	assert_eq(EditorInterface.get_selection().get_selected_nodes(), selection)
	assert_eq(_scene_root.get_children(), children)
	assert_eq(scene_history.get_version(), scene_version)
	assert_eq(global_history.get_version(), global_version)
	if not scene_sha.is_empty():
		assert_eq(FileAccess.get_sha256(scene_file), scene_sha)


func test_applies_root_override_to_every_surface_of_binary_mesh() -> void:
	var shape := _add_source(Source.instantiate() as Node3D, "_McpTestCsgBakeOverride") as CSGCombiner3D
	if not _can_refresh_fixture(shape):
		return
	var original := shape.material_override as StandardMaterial3D
	var original_path := original.resource_path
	var output := _output("overridden.res")
	_begin({"path": _scene_path(shape), "resource_path": output, "apply_material_override": true})
	var mesh := _baked_mesh(_finish(shape), shape, output, true)
	if mesh == null:
		assert_true(false, "The binary bake must save a mesh")
		return

	var native := shape.bake_static_mesh()
	assert_gt(mesh.get_surface_count(), 1, "The fixture must exercise several surfaces")
	assert_eq(mesh.get_surface_count(), native.get_surface_count())
	assert_eq(mesh.get_faces(), native.get_faces())
	for i in mesh.get_surface_count():
		assert_ne(native.surface_get_material(i), original, "The override belongs only on the saved mesh")
		var material := mesh.surface_get_material(i) as StandardMaterial3D
		assert_true(material != null)
		if material != null:
			assert_eq(material.albedo_color, original.albedo_color)
			assert_contains(material.resource_path, output + "::")
	assert_eq(shape.material_override, original)
	assert_eq(original.resource_path, original_path)


func test_override_opt_in_falls_back_to_native_material_when_no_override_exists() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeNoOverride") as CSGBox3D
	if not _can_refresh_fixture(shape):
		return
	var surface := load(EXTERNAL_SURFACE) as Material
	shape.material = surface
	var output := _output("native.res")
	_begin({"path": _scene_path(shape), "resource_path": output, "apply_material_override": true})
	var mesh := _baked_mesh(_finish(shape), shape, output, false)
	if mesh != null:
		assert_eq(mesh.surface_get_material(0), surface)


func test_reads_latest_geometry_and_override_after_dispatch() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeLatest") as CSGBox3D
	if not _can_refresh_fixture(shape):
		return
	shape.size = Vector3(2, 2, 2)
	shape.call("_update_shape")
	var before := shape.bake_static_mesh()
	assert_true(before != null, "The initial CSG mesh is needed to verify that the bake refreshes it")
	if before == null:
		return
	assert_true(before.get_aabb().is_equal_approx(AABB(-Vector3.ONE, Vector3(2, 2, 2))))
	var output := _output("latest.tres")
	_begin({"path": _scene_path(shape), "resource_path": output, "apply_material_override": true})
	shape.size = Vector3(6, 4, 2)
	var override := load(EXTERNAL_SURFACE) as Material
	shape.material_override = override
	var mesh := _baked_mesh(_finish(shape), shape, output, true)
	if mesh != null:
		assert_true(mesh.get_aabb().is_equal_approx(AABB(Vector3(-3, -2, -1), Vector3(6, 4, 2))))
		assert_eq(mesh.surface_get_material(0), override)


func test_rejects_missing_wrong_nested_and_empty_sources() -> void:
	var shape := _add_source(Source.instantiate() as Node3D, "_McpTestCsgBakeNested") as CSGCombiner3D
	var plain := _add_source(Node3D.new(), "_McpTestCsgBakeWrongType")
	var output := _output("refused.res")
	assert_is_error(_handler.bake_mesh({"resource_path": output}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_handler.bake_mesh({"path": "_McpTestCsgBakeMissing", "resource_path": output}),
		ErrorCodes.NODE_NOT_FOUND)
	assert_is_error(_handler.bake_mesh({"path": _scene_path(plain), "resource_path": output}),
		ErrorCodes.WRONG_TYPE)
	var nested := _handler.bake_mesh({"path": _scene_path(shape.get_node("Base")), "resource_path": output})
	assert_is_error(nested, ErrorCodes.INVALID_PARAMS)
	assert_eq(nested.get("error", {}).get("data", {}).get("root_path"), _scene_path(shape))
	var empty := _add_source(CSGCombiner3D.new(), "_McpTestCsgBakeEmpty") as CSGCombiner3D
	_begin({"path": _scene_path(empty), "resource_path": output})
	assert_is_error(_finish(), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_false(FileAccess.file_exists(output))


func test_rejects_invalid_output_paths_and_wrong_scene_file() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakePath")
	var path := _scene_path(shape)
	assert_is_error(_handler.bake_mesh({"path": path}), ErrorCodes.MISSING_REQUIRED_PARAM)
	for output in ["user://_mcp_test_csg_bake.res", _output("wrong.glb"),
			"res://../_mcp_test_csg_bake.res", "res://.godot/_mcp_test_csg_bake.res"]:
		assert_is_error(_handler.bake_mesh({"path": path, "resource_path": output}),
			ErrorCodes.VALUE_OUT_OF_RANGE, output)
	var valid_output := _output("wrong_scene.tres")
	assert_is_error(_handler.bake_mesh({
		"path": path, "resource_path": valid_output, "scene_file": _directory.path_join("other.tscn"),
	}), ErrorCodes.EDITED_SCENE_MISMATCH)
	assert_false(DirAccess.dir_exists_absolute(_directory), "Refusal should leave the filesystem unchanged")


func test_rejects_existing_output_without_changing_bytes() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeExisting")
	var output := _output("existing.tres")
	_write_existing_file(output)
	var before := FileAccess.get_sha256(output)
	assert_false(before.is_empty())
	var responses := _enqueue({"path": _scene_path(shape), "resource_path": output})
	assert_eq(responses.size(), 1, "A pre-existing path should be refused immediately")
	if not responses.is_empty():
		assert_is_error(responses.front(), ErrorCodes.INVALID_PARAMS)
	assert_eq(FileAccess.get_sha256(output), before)


func test_refuses_output_created_while_waiting_without_changing_bytes() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeClaimed")
	var output := _output("claimed.res")
	_begin({"path": _scene_path(shape), "resource_path": output})
	_write_existing_file(output)
	var before := FileAccess.get_sha256(output)
	assert_false(before.is_empty())
	assert_is_error(_finish(), ErrorCodes.INVALID_PARAMS)
	assert_eq(FileAccess.get_sha256(output), before)


func test_staged_commit_authorization_preserves_destination_and_cleans_stage() -> void:
	var output := _output("taken_during_staging.res")
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	var content := "Written by another process"
	var authorize := func() -> Dictionary:
		var directory := DirAccess.open(_directory)
		assert_true(directory != null)
		if directory != null:
			directory.include_hidden = true
			assert_eq(directory.get_files().size(), 1, "The mesh must already be staged")
		var file := FileAccess.open(output, FileAccess.WRITE)
		assert_true(file != null)
		if file != null:
			file.store_string(content)
			file.close()
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Destination claimed before publish")
	var result := McpResourceIO.save_to_disk(mesh, output, false, "CSG mesh", {}, null, false, true, authorize)
	assert_is_error(result, ErrorCodes.INVALID_PARAMS)
	assert_eq(result.get("error", {}).get("data", {}).get("disk_committed"), false)
	assert_eq(FileAccess.get_file_as_string(output), content)
	var directory := DirAccess.open(_directory)
	assert_true(directory != null)
	if directory != null:
		directory.include_hidden = true
		assert_eq(directory.get_files(), PackedStringArray([output.get_file()]))


func test_rejects_same_path_replacement_during_deferred_bake() -> void:
	var original := _add_source(CSGBox3D.new(), "_McpTestCsgBakeReplaced")
	var path := _scene_path(original)
	var output := _output("stale.res")
	_begin({"path": path, "resource_path": output})
	_fixture_parent.remove_child(original)
	var replacement := _add_source(CSGSphere3D.new(), "_McpTestCsgBakeReplaced")
	assert_eq(_scene_path(replacement), path)
	assert_is_error(_finish(), ErrorCodes.NODE_NOT_FOUND)
	assert_false(FileAccess.file_exists(output))


func test_cleared_deferred_request_never_creates_output() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeCancelled")
	var output := _output("cancelled.res")
	var active_before := ScriptWork.active_count(COMMAND)
	_begin({"path": _scene_path(shape), "resource_path": output})
	assert_eq(ScriptWork.active_count(COMMAND), active_before + 1)
	_dispatcher.clear_deferred_responses()
	bake_frame.emit()
	assert_eq(_connection.responses, [])
	assert_eq(ScriptWork.active_count(COMMAND), active_before)
	assert_false(DirAccess.dir_exists_absolute(_directory))


func test_batch_rejects_deferred_bake_before_earlier_commands_run() -> void:
	var shape := _add_source(CSGBox3D.new(), "_McpTestCsgBakeBatch")
	var output := _output("batch.res")
	var earlier_calls: Array = []
	_dispatcher.register("_csg_bake_test_earlier", func(_params: Dictionary) -> Dictionary:
		earlier_calls.append(true)
		return {"data": {"undoable": false}})
	var batch := BatchHandler.new(_dispatcher, _undo_redo)
	var result := batch.batch_execute({"undo": false, "commands": [
		{"command": "_csg_bake_test_earlier"},
		{"command": COMMAND, "params": {"path": _scene_path(shape), "resource_path": output}},
	]})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.get("error", {}).get("message", ""), "csg_bake_mesh")
	assert_eq(earlier_calls, [])
	assert_eq(_dispatcher.pending_deferred_count(), 0)
	assert_false(FileAccess.file_exists(output))
