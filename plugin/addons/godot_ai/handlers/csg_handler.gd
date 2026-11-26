@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## CSG authoring — create CSG shapes (box, sphere, cylinder, torus, prism)
## and set their boolean operation (union / intersection / subtraction) so
## agents can carve geometry (holes, caves, tunnels) directly in the editor.
##
## All ops target nodes in the currently edited scene by scene-relative
## path. Scene edits use EditorUndoRedoManager. A mesh bake writes a standalone
## resource using the root's evaluated CSG geometry in local coordinates.
## The editor stages the native resource and the backend publishes it.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Bounds the frame handoff and staging before publishing the resource.
const _BAKE_DEFERRED_TIMEOUT_MS := 30000
const _STAGE_PREFIX := ".godot-ai-csg-"

const SHAPES := {
	"box": "CSGBox3D",
	"sphere": "CSGSphere3D",
	"cylinder": "CSGCylinder3D",
	"torus": "CSGTorus3D",
	"polygon": "CSGPolygon3D",
}

const OPERATIONS := {
	"union": CSGShape3D.OPERATION_UNION,
	"intersection": CSGShape3D.OPERATION_INTERSECTION,
	"subtraction": CSGShape3D.OPERATION_SUBTRACTION,
}

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection
var _frame_signal: Variant


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null, frame_signal: Variant = null) -> void:
	_undo_redo = undo_redo
	_connection = connection
	_frame_signal = frame_signal


## Create a CSG shape under a Node3D parent.
## params: {parent_path, name="", shape="box", operation="union"}
## Returns: {path, name, shape, operation, undoable}
func create(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var shape: String = params.get("shape", "box")
	var operation: String = params.get("operation", "union")
	var scene_file: String = params.get("scene_file", "")

	var shape_class: String = SHAPES.get(shape, "")
	if shape_class.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown shape: %s. Valid shapes: %s" % [shape, ", ".join(SHAPES.keys())])
	if not OPERATIONS.has(operation):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown operation: %s. Valid operations: %s" % [operation, ", ".join(OPERATIONS.keys())])

	var scene_check := McpScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
				McpScenePath.format_parent_error(parent_path, scene_root))
	if not parent is Node3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"CSG parent must be a Node3D (got %s)" % parent.get_class())

	var write_error := McpNodeValidator.writable_error(parent, scene_root)
	if not write_error.is_empty():
		return write_error

	var node: CSGShape3D = ClassDB.instantiate(shape_class)
	if node == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % shape_class)
	var node_name: String = params.get("name", "")
	if node_name.is_empty():
		node_name = shape_class
	node.name = node_name
	node.operation = OPERATIONS[operation]

	_undo_redo.create_action("MCP: Create %s" % node.name)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {"data": {
		"path": McpScenePath.from_node(node, scene_root),
		"name": node.name,
		"shape": shape,
		"operation": operation,
		"undoable": true,
	}}


## Set the boolean operation of a CSG shape.
## params: {path, operation}
## Returns: {operation, undoable}
func set_operation(params: Dictionary) -> Dictionary:
	var operation: String = params.get("operation", "")
	if not OPERATIONS.has(operation):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown operation: %s. Valid operations: %s" % [operation, ", ".join(OPERATIONS.keys())])
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", ""), true)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is CSGShape3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node is not a CSGShape3D: %s" % params.get("path", ""))
	var shape: CSGShape3D = node
	var prev: int = shape.operation
	var next: int = OPERATIONS[operation]
	## Target the node in both callbacks so the action lands in the scene
	## undo history (first-target routing); `set` exists on every Object.
	_undo_redo.create_action("MCP: CSG set_operation")
	_undo_redo.add_do_method(shape, "set", "operation", next)
	_undo_redo.add_undo_method(shape, "set", "operation", prev)
	_undo_redo.commit_action()
	return {"data": {"operation": operation, "undoable": true}}


## Stage the live, evaluated CSG root as an ArrayMesh for atomic publication.
func bake_mesh(params: Dictionary) -> Dictionary:
	for key in ["path", "resource_path", "scene_file", "stage_path"]:
		if not (params.get(key, "") is String):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a string" % key)
	var apply_override = params.get("apply_material_override", false)
	if not (apply_override is bool):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "apply_material_override must be a boolean")
	var resolved := McpNodeValidator.resolve_or_error(params.get("path", ""), "path", params.get("scene_file", ""))
	if resolved.has("error"):
		return resolved
	var scene_root: Node = resolved.scene_root
	var node: Node = resolved.node
	var path := McpScenePath.from_node(node, scene_root)
	if path.is_empty() or not node.is_inside_tree() or node.is_queued_for_deletion():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "No live node in the edited scene at %s" % resolved.path)
	if not (node is CSGShape3D):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Node is not a CSGShape3D: %s" % path)
	if not node.is_root_shape():
		return _nested_bake_error(node, scene_root)

	var destination: String = params.get("resource_path", "")
	if destination.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: resource_path")
	var path_error: Variant = McpPathValidator.path_error(destination, "resource_path", true)
	if path_error != null:
		return path_error
	destination = destination.replace("\\", "/").simplify_path()
	if destination.get_extension().to_lower() not in ["res", "tres"]:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "resource_path must end in .res or .tres: %s" % destination)
	var destination_error := _bake_destination_error(destination)
	if not destination_error.is_empty():
		return destination_error
	var readiness_error := _bake_readiness_error()
	if not readiness_error.is_empty():
		return readiness_error
	var request_id: String = params.get("_request_id", "")
	if request_id.is_empty() or not is_instance_valid(_connection) or not _connection.is_inside_tree() or _connection.dispatcher == null:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"csg_bake_mesh is deferred; call csg_manage(op='bake_mesh') directly")
	var stage: String = params.get("stage_path", "")
	var stage_error := _bake_stage_error(stage, destination)
	if not stage_error.is_empty():
		return stage_error

	var job := {
		"request_id": request_id,
		"started_ms": Time.get_ticks_msec(),
		"scene_id": scene_root.get_instance_id(),
		"scene_file": scene_root.scene_file_path,
		"node_id": node.get_instance_id(),
		"path": path,
		"resource_path": destination,
		"stage_path": stage,
		"apply_material_override": apply_override,
	}
	var resume_signal: Signal = _frame_signal if _frame_signal is Signal else _connection.get_tree().process_frame
	_drive_bake(job, _connection, resume_signal)
	return {"_deferred": true, "_deferred_timeout_ms": _BAKE_DEFERRED_TIMEOUT_MS}


static func _nested_bake_error(shape: CSGShape3D, scene_root: Node) -> Dictionary:
	var bake_root := shape
	while not bake_root.is_root_shape() and bake_root.get_parent() is CSGShape3D:
		bake_root = bake_root.get_parent()
	var root_path := McpScenePath.from_node(bake_root, scene_root)
	var failure := ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
		"Bake the containing CSG root at %s to include %s" % [root_path, McpScenePath.from_node(shape, scene_root)])
	failure.error["data"] = {"root_path": root_path}
	return failure


static func _bake_readiness_error() -> Dictionary:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_UNAVAILABLE, "EditorFileSystem is unavailable", false)
	if filesystem.is_scanning() or filesystem.is_importing():
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "Wait for the editor import or scan before baking CSG", true)
	if EditorInterface.is_playing_scene():
		return ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_PLAYING, "Stop the running scene before baking CSG", false)
	return {}


static func _bake_destination_error(destination: String) -> Dictionary:
	if FileAccess.file_exists(destination) or DirAccess.dir_exists_absolute(destination):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Choose a new resource_path; %s already exists" % destination)
	return {}


static func _bake_stage_error(stage: String, destination: String) -> Dictionary:
	var path_error: Variant = McpPathValidator.path_error(stage, "stage_path", true)
	if path_error != null:
		return path_error
	var directory := stage.get_base_dir()
	# The backend creates this private directory in the nearest existing
	# ancestor. It can create missing destination directories after validation.
	var parent := directory.get_base_dir()
	var destination_parent := destination.get_base_dir()
	if (
		stage != stage.simplify_path() or not directory.get_file().begins_with(_STAGE_PREFIX)
		or stage.get_file() != "mesh." + destination.get_extension()
		or (parent != "res://" and destination_parent != parent and not destination_parent.begins_with(parent + "/"))
		or not DirAccess.dir_exists_absolute(directory) or DirAccess.dir_exists_absolute(stage)
		or FileAccess.file_exists(stage)
	):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Invalid private CSG stage for %s" % destination)
	return {}


static func _bake_request_pending(connection, request_id: String) -> bool:
	return (
		is_instance_valid(connection) and connection.is_inside_tree()
		and connection.dispatcher != null and connection.dispatcher.has_pending_deferred_response(request_id)
	)


static func _drive_bake(job: Dictionary, connection, resume_signal: Signal) -> void:
	var work := ScriptWork.begin("csg_bake_mesh")
	## Godot updates the CSG mesh at the frame boundary. This also lets the
	## dispatcher register the request before we check its pending entry.
	await resume_signal
	if _bake_request_pending(connection, job.request_id):
		var result := _bake_after_frame(job, connection)
		if _bake_request_pending(connection, job.request_id):
			connection.send_deferred_response(job.request_id, result)
	ScriptWork.finish(work)


static func _live_bake_shape(job: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or scene_root.is_queued_for_deletion() or scene_root.get_instance_id() != job.scene_id or scene_root.scene_file_path != job.scene_file:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The edited scene changed while baking %s" % job.path)
	var shape := McpScenePath.resolve(job.path, scene_root) as CSGShape3D
	if shape == null or shape.get_instance_id() != job.node_id or not shape.is_inside_tree() or shape.is_queued_for_deletion():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "The original CSG shape is no longer at %s" % job.path)
	if not shape.is_root_shape():
		return _nested_bake_error(shape, scene_root)
	var readiness_error := _bake_readiness_error()
	if not readiness_error.is_empty():
		return readiness_error
	return {"shape": shape}


static func _bake_after_frame(job: Dictionary, connection: McpConnection) -> Dictionary:
	if Time.get_ticks_msec() - int(job.started_ms) >= _BAKE_DEFERRED_TIMEOUT_MS:
		return ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "Timed out waiting for the CSG update at %s" % job.path)
	var live := _live_bake_shape(job)
	if live.has("error"):
		return live
	var destination: String = job.resource_path
	var destination_error := _bake_destination_error(destination)
	if not destination_error.is_empty():
		return destination_error
	var shape: CSGShape3D = live.shape
	var evaluated := shape.bake_static_mesh()
	if evaluated == null or evaluated.get_surface_count() == 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "The CSG root at %s produced no mesh surfaces" % job.path)

	## Godot returns the root's cached mesh. Copy the mesh and embedded
	## resources before editing or saving, keeping external dependencies.
	var output := evaluated.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL) as ArrayMesh
	if output == null or output.get_surface_count() != evaluated.get_surface_count():
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not copy the CSG mesh at %s" % job.path)
	var source_override := shape.material_override if job.apply_material_override else null
	if source_override != null:
		var override_material: Material = source_override
		if source_override.resource_path.is_empty() or source_override.is_built_in():
			override_material = source_override.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL) as Material
			if override_material == null:
				return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not copy the material override at %s" % job.path)
		for surface in output.get_surface_count():
			output.surface_set_material(surface, override_material)

	var writable := _authorize_bake_commit(job, connection, evaluated, source_override)
	if writable.has("error"):
		return writable
	var stage: String = job.stage_path
	var stage_error := _bake_stage_error(stage, destination)
	if not stage_error.is_empty():
		return stage_error
	var save_error := McpResourceIO.guarded_save(output, stage, connection)
	if save_error != OK:
		var failure := ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to stage the CSG mesh for %s: %s" % [destination, error_string(save_error)])
		failure.error["data"] = {"disk_committed": false, "resource_path": destination}
		return failure
	var digest := FileAccess.get_sha256(stage)
	if digest.is_empty():
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not verify the staged CSG mesh for %s" % destination)
	writable = _authorize_bake_commit(job, connection, evaluated, source_override)
	if writable.has("error"):
		return writable
	return {"data": {
		"path": job.path,
		"resource_path": destination,
		"stage_path": stage,
		"stage_sha256": digest,
		"surface_count": output.get_surface_count(),
		"material_override_applied": source_override != null,
	}}


## Verify and register the final file after the backend publishes it.
func finalize_bake(params: Dictionary) -> Dictionary:
	var destination: String = params.get("resource_path", "")
	var path_error: Variant = McpPathValidator.path_error(destination, "resource_path", true)
	if path_error != null:
		return path_error
	var digest: String = params.get("stage_sha256", "")
	var expected_surface_count: int = params.get("surface_count", 0)
	var reloaded: ArrayMesh
	if not digest.is_empty() and FileAccess.get_sha256(destination) == digest:
		reloaded = ResourceLoader.load(destination, "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
	if reloaded == null or expected_surface_count <= 0 or reloaded.get_surface_count() != expected_surface_count:
		var failure := ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Saved %s but could not verify the ArrayMesh on disk" % destination)
		failure.error["data"] = {
			"disk_committed": true,
			"resource_path": destination,
			"cleanup": {"rm": [destination]},
		}
		return failure
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem != null:
		filesystem.update_file(destination)
	return {"data": {
		"path": params.get("path", ""),
		"resource_path": destination,
		"surface_count": reloaded.get_surface_count(),
		"material_override_applied": params.get("material_override_applied", false),
		"overwritten": false,
		"undoable": false,
		"reason": "File creation is persistent; delete the file manually to revert",
		"cleanup": {"rm": [destination]},
	}}


static func _authorize_bake_commit(job: Dictionary, connection, evaluated: ArrayMesh, source_override: Material) -> Dictionary:
	if not _bake_request_pending(connection, job.request_id) or Time.get_ticks_msec() - int(job.started_ms) >= _BAKE_DEFERRED_TIMEOUT_MS:
		return ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "CSG bake expired before publishing %s" % job.resource_path)
	var live := _live_bake_shape(job)
	if live.has("error"):
		return live
	var shape: CSGShape3D = live.shape
	if shape.bake_static_mesh() != evaluated or (job.apply_material_override and shape.material_override != source_override):
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The CSG mesh or material override changed while baking %s" % job.path)
	return _bake_destination_error(job.resource_path)
