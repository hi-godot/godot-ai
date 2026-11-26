@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const _DEFERRED_TIMEOUT_MS := 30000
const _FRAME_BUDGET_USEC := 4000
const _TRANSFORM_FLOATS := 12
const _CHANNEL_FLOATS := 4
const _ZERO_CUSTOM_DATA := Color(0, 0, 0, 0)
const _ROW_FIELDS := ["transform", "color", "custom_data"]
## Godot's Compatibility renderer truncates these channels to half precision.
## Values at or above this magnitude round to infinity on the GPU.
const _COMPATIBILITY_CHANNEL_LIMIT := 65536.0

var _undo_redo: EditorUndoRedoManager
var _connection


func _init(undo_redo: EditorUndoRedoManager, connection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


func set_instances(params: Dictionary) -> Dictionary:
	var request_id: String = params.get("_request_id", "")
	var job := _prepare_job(params, _undo_redo, _connection, request_id)
	if job.has("error"):
		return job
	if _connection != null and not request_id.is_empty():
		_drive_job(job, _connection)
		return {"_deferred": true, "_deferred_timeout_ms": _DEFERRED_TIMEOUT_MS}
	# In-process callers have no deferred reply channel. Batch commands explicitly
	# decline this operation so WebSocket callers use the frame-budgeted path.
	while not _step(job, -1):
		pass
	return job.result


static func _prepare_job(
	params: Dictionary, undo_redo: EditorUndoRedoManager, connection, request_id: String
) -> Dictionary:
	for key in ["path", "scene_file", "mesh_path", "mesh_node_path"]:
		if params.has(key) and not params[key] is String:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a string" % key)
	var path: String = params.get("path", "")
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")
	if not params.has("instances"):
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: instances")
	if not params.instances is Array:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "instances must be an array")
	var rows: Array = params.instances
	var mesh_path: String = params.get("mesh_path", "")
	var mesh_node_path: String = params.get("mesh_node_path", "")
	if not mesh_path.is_empty() and not mesh_node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Provide either mesh_path or mesh_node_path, or omit both")
	if not mesh_path.is_empty():
		var path_error = McpPathValidator.path_error(mesh_path, "mesh_path")
		if path_error != null:
			return path_error

	var scene := McpNodeValidator.require_scene_or_error(params.get("scene_file", ""))
	if scene.has("error"):
		return scene
	var readiness_error := _readiness_error()
	if not readiness_error.is_empty():
		return readiness_error
	var root: Node = scene.scene_root
	var target := McpScenePath.resolve(path, root)
	var target_path := McpScenePath.from_node(target, root)
	if target_path.is_empty():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, McpScenePath.format_node_error(path, root))
	if not target is MultiMeshInstance3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a MultiMeshInstance3D" % target_path)
	var write_error := _writable_error(target, root)
	if not write_error.is_empty():
		return write_error
	var previous: MultiMesh = target.multimesh
	if previous != null:
		if previous.get_script() != null:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s has a scripted MultiMesh; editing it would discard its script" % target_path)
		if previous.transform_format == MultiMesh.TRANSFORM_2D and previous.instance_count > 0:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s has a populated 2D MultiMesh" % target_path)

	var source: MeshInstance3D = null
	var source_path := ""
	var mesh: Mesh = previous.mesh if previous != null else null
	if not mesh_node_path.is_empty():
		var source_node := McpScenePath.resolve(mesh_node_path, root)
		source_path = McpScenePath.from_node(source_node, root)
		if source_path.is_empty() or source_node.is_queued_for_deletion():
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
				"mesh_node_path: %s" % McpScenePath.format_node_error(mesh_node_path, root))
		if not source_node is MeshInstance3D:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "mesh_node_path must point to a MeshInstance3D")
		source = source_node
		mesh = source.mesh
		if mesh == null:
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "mesh_node_path points to a MeshInstance3D with no Mesh")
	if not rows.is_empty() and mesh == null and mesh_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "A nonempty instances array requires a Mesh. Supply mesh_path or mesh_node_path")

	var settings := _settings(previous)
	return {
		"undo_redo": undo_redo,
		"connection": connection,
		"request_id": request_id,
		"started_ms": Time.get_ticks_msec(),
		"scene_root": root,
		"scene_file": root.scene_file_path,
		"target": target,
		"target_path": target_path,
		"target_context": _target_context(target, root),
		"previous": previous,
		"previous_settings": settings,
		"previous_buffer": _read_buffer(previous),
		"source": source,
		"source_path": source_path,
		"mesh_path": mesh_path,
		"mesh": mesh,
		"rows": rows,
		"half_precision_channels": DisplayServer.get_name() != "headless" and RenderingServer.get_current_rendering_method() == "gl_compatibility",
		"use_colors": settings.get("use_colors", false),
		"use_custom_data": settings.get("use_custom_data", false),
		"phase": "channels",
		"index": 0,
		"result": {},
	}


static func _readiness_error() -> Dictionary:
	var state := McpConnection.get_readiness()
	var error: Dictionary
	match state:
		"importing":
			error = ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_IMPORTING, "The editor is importing resources", true)
		"playing":
			error = ErrorCodes.make_not_ready(ErrorCodes.SUB_EDITOR_PLAYING, "Stop the running project before editing instances", false)
		"no_scene":
			return McpScenePath.require_edited_scene("")
		_:
			return {}
	error.error.data.editor_state = state
	return error


static func _writable_error(target: Node, root: Node) -> Dictionary:
	var error := McpNodeValidator.writable_error(target, root)
	if not error.is_empty():
		return error
	var current := target
	while current != root:
		if current.owner == null:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Cannot edit %s: %s has no scene owner, so changes would be lost on save" % [
					McpScenePath.from_node(target, root), McpScenePath.from_node(current, root)])
		if current.is_queued_for_deletion():
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "%s is being removed" % McpScenePath.from_node(current, root))
		current = current.get_parent()
	return {}


static func _target_context(target: Node, root: Node) -> PackedInt64Array:
	var context := PackedInt64Array()
	var current := target
	while current != root:
		context.append(current.get_instance_id())
		context.append(current.owner.get_instance_id())
		current = current.get_parent()
	return context


static func _settings(multimesh: MultiMesh) -> Dictionary:
	if multimesh == null:
		return {}
	var metadata := {}
	for key in multimesh.get_meta_list():
		metadata[key] = multimesh.get_meta(key)
	return {
		"mesh": multimesh.mesh,
		"format": multimesh.transform_format,
		"instance_count": multimesh.instance_count,
		"visible_count": multimesh.visible_instance_count,
		"use_colors": multimesh.use_colors,
		"use_custom_data": multimesh.use_custom_data,
		"custom_aabb": multimesh.custom_aabb,
		"quality": multimesh.physics_interpolation_quality,
		"name": multimesh.resource_name,
		"local_to_scene": multimesh.resource_local_to_scene,
		"resource_path": multimesh.resource_path,
		"script": multimesh.get_script(),
		"metadata": metadata,
	}


static func _read_buffer(multimesh: MultiMesh) -> PackedFloat32Array:
	# Headless Godot can retain the earlier buffer when instance_count goes to 0.
	return multimesh.buffer if multimesh != null and multimesh.instance_count > 0 else PackedFloat32Array()


static func _stride(use_colors: bool, use_custom_data: bool) -> int:
	return _TRANSFORM_FLOATS + (_CHANNEL_FLOATS if use_colors else 0) + (_CHANNEL_FLOATS if use_custom_data else 0)


static func _step(job: Dictionary, budget_usec: int) -> bool:
	if job.phase == "done":
		return true
	if _abandoned(job):
		return _finish(job, {})
	var error := _execution_error(job)
	if not error.is_empty():
		return _finish(job, error)
	var start := Time.get_ticks_usec()
	var rows: Array = job.rows
	var work := 0
	while job.phase == "channels" and int(job.index) < rows.size() and not (job.use_colors and job.use_custom_data):
		if _frame_spent(start, budget_usec, work):
			return false
		var row: Variant = rows[int(job.index)]
		if row is Dictionary:
			job.use_colors = job.use_colors or row.has("color")
			job.use_custom_data = job.use_custom_data or row.has("custom_data")
		job.index = int(job.index) + 1
		work += 1
	if job.phase == "channels":
		if _frame_spent(start, budget_usec, work):
			return false
		job.stride = _stride(job.use_colors, job.use_custom_data)
		var buffer := PackedFloat32Array()
		var resize_error := buffer.resize(rows.size() * int(job.stride))
		if resize_error != OK:
			return _finish(job, ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Could not allocate instance buffer: %s" % error_string(resize_error)))
		job.buffer = buffer
		job.old_stride = _stride(job.previous_settings.get("use_colors", false), job.previous_settings.get("use_custom_data", false))
		job.old_count = job.previous_settings.get("instance_count", 0)
		if job.previous_buffer.size() != int(job.old_stride) * int(job.old_count):
			# In a headless editor a MultiMesh without an authored buffer can have
			# a nonzero count but no channel data to copy.
			job.old_count = 0
		job.phase = "rows"
		job.index = 0
		work += 1
	while job.phase == "rows" and int(job.index) < rows.size():
		if _frame_spent(start, budget_usec, work):
			return false
		var index: int = job.index
		error = _pack_row(job, rows[index], index)
		if not error.is_empty():
			return _finish(job, error)
		job.index = index + 1
		work += 1
	if job.phase == "rows":
		job.phase = "candidate"
	if job.phase == "candidate":
		if _frame_spent(start, budget_usec, work):
			return false
		error = _stage_candidate(job)
		if not error.is_empty():
			return _finish(job, error)
		job.phase = "commit"
		work += 1
	if _frame_spent(start, budget_usec, work):
		return false
	return _finish(job, _commit(job))


static func _frame_spent(start: int, budget_usec: int, work: int) -> bool:
	return budget_usec >= 0 and work > 0 and Time.get_ticks_usec() - start >= budget_usec


static func _pack_row(job: Dictionary, raw_row: Variant, index: int) -> Dictionary:
	if not raw_row is Dictionary:
		return _row_error(ErrorCodes.WRONG_TYPE, index, "", "must be an object")
	var row: Dictionary = raw_row
	for key in row:
		if key not in _ROW_FIELDS:
			return _row_error(ErrorCodes.INVALID_PARAMS, index, str(key), "is not a supported field")
	if not row.has("transform"):
		return _row_error(ErrorCodes.MISSING_REQUIRED_PARAM, index, "transform", "is required")
	var parsed_transform: Variant = McpJsonValues.parse_transform3d(row.transform)
	if parsed_transform == null or not (parsed_transform as Transform3D).is_finite():
		return _row_error(ErrorCodes.WRONG_TYPE, index, "transform", "must be a finite Transform3D")
	var transform: Transform3D = parsed_transform
	var buffer: PackedFloat32Array = job.buffer
	var offset := index * int(job.stride)
	# Godot's bulk buffer uses three matrix rows. Basis.x/y/z are columns.
	buffer[offset] = transform.basis.x.x
	buffer[offset + 1] = transform.basis.y.x
	buffer[offset + 2] = transform.basis.z.x
	buffer[offset + 3] = transform.origin.x
	buffer[offset + 4] = transform.basis.x.y
	buffer[offset + 5] = transform.basis.y.y
	buffer[offset + 6] = transform.basis.z.y
	buffer[offset + 7] = transform.origin.y
	buffer[offset + 8] = transform.basis.x.z
	buffer[offset + 9] = transform.basis.y.z
	buffer[offset + 10] = transform.basis.z.z
	buffer[offset + 11] = transform.origin.z
	# Even a double-precision engine uses float32 for this buffer.
	for component in range(offset, offset + _TRANSFORM_FLOATS):
		if not is_finite(buffer[component]):
			return _row_error(ErrorCodes.VALUE_OUT_OF_RANGE, index, "transform", "does not fit the float32 buffer")
	offset += _TRANSFORM_FLOATS
	var previous_buffer: PackedFloat32Array = job.previous_buffer
	var old_offset := index * int(job.old_stride) + _TRANSFORM_FLOATS
	var has_previous := index < int(job.old_count)
	var old_colors: bool = job.previous_settings.get("use_colors", false)
	if job.use_colors:
		if row.has("color"):
			var color: Variant = McpJsonValues.parse_color(row.color)
			if color == null or not _finite_color(color):
				return _row_error(ErrorCodes.WRONG_TYPE, index, "color", "must be a finite Color")
			if job.half_precision_channels and not _fits_compatibility_channel(color):
				return _row_error(ErrorCodes.VALUE_OUT_OF_RANGE, index, "color", "must fit the Compatibility renderer's half-precision channel range")
			_write_channel(buffer, offset, color)
		elif has_previous and old_colors:
			_copy_channel(buffer, offset, previous_buffer, old_offset)
		else:
			_write_channel(buffer, offset, Color.WHITE)
		offset += _CHANNEL_FLOATS
	if job.use_custom_data:
		if row.has("custom_data"):
			var custom: Variant = _parse_custom_data(row.custom_data)
			if custom == null:
				return _row_error(ErrorCodes.WRONG_TYPE, index, "custom_data", "must be an array of four finite shader values")
			if job.half_precision_channels and not _fits_compatibility_channel(custom):
				return _row_error(ErrorCodes.VALUE_OUT_OF_RANGE, index, "custom_data", "must fit the Compatibility renderer's half-precision channel range")
			_write_channel(buffer, offset, custom)
		elif has_previous and job.previous_settings.get("use_custom_data", false):
			_copy_channel(buffer, offset, previous_buffer, old_offset + (_CHANNEL_FLOATS if old_colors else 0))
		else:
			_write_channel(buffer, offset, _ZERO_CUSTOM_DATA)
	return {}


static func _parse_custom_data(value: Variant) -> Variant:
	if not value is Array or value.size() != _CHANNEL_FLOATS:
		return null
	for component in value:
		if not (component is float or component is int) or not is_finite(float(component)):
			return null
	# Color is only the engine's four-float storage type here. Do not interpret
	# custom data as a color or normalize the values to the unit interval.
	var custom := Color(value[0], value[1], value[2], value[3])
	return custom if _finite_color(custom) else null


static func _finite_color(value: Color) -> bool:
	return is_finite(value.r) and is_finite(value.g) and is_finite(value.b) and is_finite(value.a)


static func _fits_compatibility_channel(value: Color) -> bool:
	return maxf(maxf(absf(value.r), absf(value.g)), maxf(absf(value.b), absf(value.a))) < _COMPATIBILITY_CHANNEL_LIMIT


static func _write_channel(buffer: PackedFloat32Array, offset: int, value: Color) -> void:
	buffer[offset] = value.r
	buffer[offset + 1] = value.g
	buffer[offset + 2] = value.b
	buffer[offset + 3] = value.a


static func _copy_channel(to: PackedFloat32Array, to_offset: int, from: PackedFloat32Array, from_offset: int) -> void:
	for component in _CHANNEL_FLOATS:
		to[to_offset + component] = from[from_offset + component]


static func _row_error(code: String, index: int, field: String, message: String) -> Dictionary:
	var location := "instances[%d]" % index
	if not field.is_empty():
		location += "." + field
	var result := ErrorCodes.make(code, "%s %s" % [location, message])
	result.error.data = {"row": index, "field": field}
	return result


static func _stage_candidate(job: Dictionary) -> Dictionary:
	var mesh: Mesh = job.mesh
	var mesh_path: String = job.mesh_path
	if not mesh_path.is_empty():
		if not (FileAccess.file_exists(mesh_path) and ResourceLoader.exists(mesh_path)):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Mesh resource not found at mesh_path %s" % mesh_path)
		var resource := ResourceLoader.load(mesh_path)
		if resource == null:
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Could not load mesh_path %s" % mesh_path)
		if not resource is Mesh:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "mesh_path %s must refer to a Mesh resource" % mesh_path)
		mesh = resource
		job.mesh = mesh
	var previous: MultiMesh = job.previous
	var count: int = job.rows.size()
	if previous == null and mesh == null and count == 0:
		job.candidate = null
		job.changed = false
		return {}
	var candidate := MultiMesh.new()
	candidate.transform_format = MultiMesh.TRANSFORM_3D
	candidate.use_colors = job.use_colors
	candidate.use_custom_data = job.use_custom_data
	candidate.mesh = mesh
	candidate.instance_count = count
	if candidate.instance_count != count:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Godot did not allocate the MultiMesh instance count")
	if count > 0:
		candidate.buffer = job.buffer
	# Read back once. Compatibility stores color and custom channels at half
	# precision, while the headless driver exposes full 32-bit values.
	var candidate_buffer := _read_buffer(candidate)
	if candidate_buffer.size() != count * int(job.stride):
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Godot did not retain the full MultiMesh instance buffer")
	var settings: Dictionary = job.previous_settings
	if previous != null:
		candidate.custom_aabb = settings.custom_aabb
		candidate.physics_interpolation_quality = settings.quality
		candidate.visible_instance_count = -1 if int(settings.visible_count) < 0 else mini(int(settings.visible_count), count)
		candidate.resource_name = settings.name
		candidate.resource_local_to_scene = settings.local_to_scene
		var metadata: Dictionary = settings.metadata
		for key in metadata:
			candidate.set_meta(key, metadata[key])
	job.candidate = candidate
	job.changed = (
		previous == null or settings.format != MultiMesh.TRANSFORM_3D or settings.mesh != mesh
		or settings.instance_count != count or settings.use_colors != candidate.use_colors
		or settings.use_custom_data != candidate.use_custom_data
		or settings.visible_count != candidate.visible_instance_count
		or not _same_buffer(job.previous_buffer, candidate_buffer)
	)
	return {}


static func _abandoned(job: Dictionary) -> bool:
	if str(job.request_id).is_empty():
		return false
	var connection = job.connection
	if not is_instance_valid(connection) or not connection.is_inside_tree():
		return true
	var dispatcher = connection.dispatcher
	return dispatcher != null and not dispatcher.has_pending_deferred_response(job.request_id)


static func _execution_error(job: Dictionary) -> Dictionary:
	if not str(job.request_id).is_empty() and Time.get_ticks_msec() - int(job.started_ms) >= _DEFERRED_TIMEOUT_MS:
		return ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "multimesh_set_instances exceeded its %d ms budget" % _DEFERRED_TIMEOUT_MS)
	var root = job.scene_root
	if not is_instance_valid(root) or EditorInterface.get_edited_scene_root() != root or root.is_queued_for_deletion() or root.scene_file_path != job.scene_file:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The edited scene changed while MultiMesh instances were prepared")
	return _readiness_error()


static func _same_buffer(before: PackedFloat32Array, after: PackedFloat32Array) -> bool:
	return before.size() == after.size() and before.to_byte_array() == after.to_byte_array()


static func _commit(job: Dictionary) -> Dictionary:
	if _abandoned(job):
		return {}
	var error := _execution_error(job)
	if not error.is_empty():
		return error
	var root: Node = job.scene_root
	var target = job.target
	if not is_instance_valid(target) or target.is_queued_for_deletion():
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "%s was removed while MultiMesh instances were prepared" % job.target_path)
	if McpScenePath.from_node(target, root) != job.target_path:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "%s moved while MultiMesh instances were prepared" % job.target_path)
	error = _writable_error(target, root)
	if not error.is_empty():
		return error
	if _target_context(target, root) != job.target_context:
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "%s changed scene ownership while MultiMesh instances were prepared" % job.target_path)
	if not str(job.source_path).is_empty():
		var source = job.source
		if not is_instance_valid(source) or source.is_queued_for_deletion():
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "mesh_node_path %s was removed while MultiMesh instances were prepared" % job.source_path)
		if McpScenePath.from_node(source, root) != job.source_path or source.mesh != job.mesh:
			return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "mesh_node_path %s changed while MultiMesh instances were prepared" % job.source_path)
	var mesh_path: String = job.mesh_path
	if not mesh_path.is_empty():
		if not FileAccess.file_exists(mesh_path) or ResourceLoader.get_cached_ref(mesh_path) != job.mesh:
			return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "mesh_path %s changed while MultiMesh instances were prepared" % mesh_path)
	var previous: MultiMesh = job.previous
	if target.multimesh != previous or _settings(previous) != job.previous_settings or not _same_buffer(job.previous_buffer, _read_buffer(previous)):
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "%s MultiMesh changed while instances were prepared" % job.target_path)
	if job.changed:
		var undo_redo: EditorUndoRedoManager = job.undo_redo
		undo_redo.create_action("MCP: Set MultiMesh Instances on %s" % target.name, UndoRedo.MERGE_DISABLE, root)
		undo_redo.add_do_property(target, "multimesh", job.candidate)
		undo_redo.add_undo_property(target, "multimesh", previous)
		undo_redo.commit_action()
	return {"data": {
		"path": job.target_path,
		"instance_count": job.rows.size(),
		"use_colors": job.use_colors,
		"use_custom_data": job.use_custom_data,
		"changed": job.changed,
		"undoable": job.changed,
	}}


static func _finish(job: Dictionary, result: Dictionary) -> bool:
	job.result = result
	job.phase = "done"
	return true


static func _drive_job(job: Dictionary, connection, frame_signal: Variant = null) -> void:
	var work_id := ScriptWork.begin("multimesh_set_instances")
	if is_instance_valid(connection) and connection.is_inside_tree():
		var resume_signal: Signal = frame_signal if frame_signal is Signal else connection.get_tree().process_frame
		# The dispatcher registers the deferred request after set_instances returns.
		await resume_signal
		while not _step(job, _FRAME_BUDGET_USEC):
			await resume_signal
		if not job.result.is_empty() and is_instance_valid(connection) and connection.is_inside_tree():
			connection.send_deferred_response(job.request_id, job.result)
	else:
		_finish(job, {})
	ScriptWork.finish(work_id)
