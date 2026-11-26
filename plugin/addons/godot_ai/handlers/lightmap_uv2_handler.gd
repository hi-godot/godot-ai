@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScenePath := preload("res://addons/godot_ai/utils/scene_path.gd")
const ParamValidators := preload("res://addons/godot_ai/handlers/_param_validators.gd")

const COMMAND := "check_lightmap_uv2"
const FRAME_BUDGET_USEC := 4000
const TIMEOUT_MSEC := 30000
const TRIANGLE_PRIMITIVES := {
	&"BoxMesh": true, &"CapsuleMesh": true, &"CylinderMesh": true,
	&"PlaneMesh": true, &"PrismMesh": true, &"QuadMesh": true,
	&"RibbonTrailMesh": true, &"SphereMesh": true, &"TextMesh": true,
	&"TorusMesh": true, &"TubeTrailMesh": true,
}
const GI_MODES := {
	GeometryInstance3D.GI_MODE_STATIC: "static",
	GeometryInstance3D.GI_MODE_DYNAMIC: "dynamic",
	GeometryInstance3D.GI_MODE_DISABLED: "disabled",
}


## Store one resource's channel metadata, then reuse it for all its placements.
## Only deficient surfaces need individual records in the request-local cache.
class MeshChannels extends RefCounted:
	enum Kind { ARRAY, PRIMITIVE, POINT, UNSUPPORTED }

	var kind := Kind.UNSUPPORTED
	var mesh_type: String
	var mesh_path: String
	var triangles := 0
	var deficient: Array[Dictionary] = []
	var resource: Mesh
	var surface_count := 0
	var add_uv2 := false

	func _init(mesh: Mesh) -> void:
		resource = mesh
		mesh_path = mesh.resource_path
		mesh_type = mesh.get_class()
		var script := mesh.get_script() as Script
		if script != null:
			var global_name := script.get_global_name()
			if not global_name.is_empty():
				mesh_type = str(global_name)
			return
		match mesh_type:
			"ArrayMesh":
				kind = Kind.ARRAY
				surface_count = mesh.get_surface_count()
			"PointMesh":
				kind = Kind.POINT
			_:
				if TRIANGLE_PRIMITIVES.has(StringName(mesh_type)):
					kind = Kind.PRIMITIVE
					triangles = 1
					## Even a surface count can force PrimitiveMesh to generate
					## geometry. These native types declare a triangle surface
					## with normals and use add_uv2 for the second UV channel.
					add_uv2 = (mesh as PrimitiveMesh).add_uv2
					if not add_uv2:
						deficient.append(_surface(0, "", ["missing_uv2"]))

	func is_current() -> bool:
		## clear_surfaces() and a still-lazy primitive can change without
		## emitting Resource.changed in Godot 4.7.
		if kind == Kind.ARRAY:
			return resource.get_surface_count() == surface_count
		if kind == Kind.PRIMITIVE:
			return (resource as PrimitiveMesh).add_uv2 == add_uv2
		return true

	func read_array_surface(mesh: ArrayMesh, index: int) -> void:
		if mesh.surface_get_primitive_type(index) != Mesh.PRIMITIVE_TRIANGLES:
			return
		triangles += 1
		var format := mesh.surface_get_format(index)
		var issues: Array[String] = []
		if (format & Mesh.ARRAY_FORMAT_TEX_UV2) == 0:
			issues.append("missing_uv2")
		if (format & Mesh.ARRAY_FORMAT_NORMAL) == 0:
			issues.append("missing_normals")
		if not issues.is_empty():
			deficient.append(_surface(index, mesh.surface_get_name(index), issues))

	static func _surface(index: int, surface_name: String, issues: Array[String]) -> Dictionary:
		return {"surface_index": index, "surface_name": surface_name, "issues": issues}


class Cursor extends RefCounted:
	var node_id: int
	var owner_id: int
	var next_child := -1

	func _init(node: Node) -> void:
		node_id = node.get_instance_id()
		owner_id = node.owner.get_instance_id() if node.owner != null else 0


class ScanJob extends RefCounted:
	var request_id: String
	var started_msec := Time.get_ticks_msec()
	var scene_id: int
	var scene_file: String
	var scene_path: String
	var scene_generation: int
	var target_id: int
	var target_path: String
	var scope: String
	var offset: int
	var limit: int
	var stack: Array[Cursor] = []
	var mesh_cache: Dictionary[int, MeshChannels] = {}
	var scanned_meshes: Array[MeshChannels] = []
	var invalidated := false
	var mesh_instances := 0
	var triangle_surfaces := 0
	var unsupported := 0
	var missing := 0
	var total := 0
	var findings: Array[Dictionary] = []

	var array_mesh: ArrayMesh
	var array_mesh_id: int
	var channels: MeshChannels
	var surface_index := 0
	var finding_index := 0
	var placement_path: String
	var placement_visible: bool
	var placement_gi_mode: int

	func invalidate() -> void:
		invalidated = true

	func advance(scene_root: Node) -> void:
		## One step per surface (or per cached finding), child, or node. A
		## large ArrayMesh or many siblings yield just like a deep scene does.
		var cursor := stack.back() as Cursor
		var node := instance_from_id(cursor.node_id) as Node
		if node == null or node.is_queued_for_deletion():
			invalidate()
			return
		if channels != null:
			_advance_mesh()
			return
		if cursor.next_child == -1:
			cursor.next_child = 0
			node.child_order_changed.connect(invalidate)
			var instance := node as MeshInstance3D
			if instance != null:
				_begin_mesh(instance, scene_root)
			return

		## LightmapGI includes internal children in native Node traversal,
		## and prunes each ownerless branch. Instance editability is irrelevant.
		if cursor.next_child >= node.get_child_count(true):
			stack.pop_back()
			return
		var child := node.get_child(cursor.next_child, true)
		cursor.next_child += 1
		if child.owner != null:
			stack.append(Cursor.new(child))

	func _begin_mesh(instance: MeshInstance3D, scene_root: Node) -> void:
		placement_visible = instance.is_visible_in_tree()
		placement_gi_mode = instance.gi_mode
		if scope == "bake_candidates" and (not placement_visible or placement_gi_mode != GeometryInstance3D.GI_MODE_STATIC):
			return
		var mesh := instance.mesh
		if mesh == null:
			return
		var mesh_id := mesh.get_instance_id()
		channels = mesh_cache.get(mesh_id)
		if channels == null:
			channels = MeshChannels.new(mesh)
			if channels.kind in [MeshChannels.Kind.ARRAY, MeshChannels.Kind.PRIMITIVE]:
				scanned_meshes.append(channels)
			mesh.changed.connect(invalidate)
			if channels.kind == MeshChannels.Kind.ARRAY:
				array_mesh = mesh as ArrayMesh
				array_mesh_id = mesh_id
				surface_index = 0
			else:
				mesh_cache[mesh_id] = channels
		elif not channels.is_current():
			invalidate()
			return
		if channels.kind == MeshChannels.Kind.POINT:
			channels = null
			return

		if channels.kind == MeshChannels.Kind.UNSUPPORTED:
			unsupported += 1
			if total >= offset and findings.size() < limit:
				placement_path = ScenePath.from_node(instance, scene_root)
			_record("unsupported_mesh", {"mesh_type": channels.mesh_type})
			channels = null
			return

		mesh_instances += 1
		finding_index = 0
		if findings.size() < limit and (array_mesh != null or total + channels.deficient.size() > offset):
			placement_path = ScenePath.from_node(instance, scene_root)

	func _advance_mesh() -> void:
		if array_mesh != null:
			if not channels.is_current():
				invalidate()
				return
			if surface_index < channels.surface_count:
				channels.read_array_surface(array_mesh, surface_index)
				surface_index += 1
				return
			mesh_cache[array_mesh_id] = channels
			array_mesh = null
		var remaining := channels.deficient.size() - finding_index
		if findings.size() == limit or remaining <= offset - total:
			missing += remaining
			total += remaining
			finding_index += remaining
		if finding_index < channels.deficient.size():
			missing += 1
			_record("surface", channels.deficient[finding_index])
			finding_index += 1
			return
		triangle_surfaces += channels.triangles
		channels = null

	func _record(kind: String, details: Dictionary) -> void:
		if total >= offset and findings.size() < limit:
			var row := {"kind": kind, "path": placement_path, "mesh_path": channels.mesh_path}
			row.merge(details)
			if scope == "all":
				row["visible_in_tree"] = placement_visible
				row["gi_mode"] = GI_MODES[placement_gi_mode]
			findings.append(row)
		total += 1

	func changed_error() -> Dictionary:
		var error := ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The subtree or mesh changed during the lightmap UV2 check. Retry the scan.")
		error.error["data"] = {"retryable": true}
		return error

	func response(deadline_usec: int) -> Dictionary:
		## These values can change silently. Yielding here would allow an
		## already-checked mesh to change before the report is published.
		for mesh in scanned_meshes:
			if Time.get_ticks_usec() >= deadline_usec:
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Too many distinct meshes to verify in one editor frame. Check a smaller subtree with path.")
			if not mesh.is_current():
				return changed_error()
		var complete := unsupported == 0
		var status := "clear"
		if missing > 0:
			status = "missing_channels"
		elif not complete:
			status = "incomplete"
		elif triangle_surfaces == 0:
			status = "no_eligible_geometry"
		return {"data": {
			"scope": scope, "path": target_path, "status": status, "complete": complete,
			"mesh_instances_checked": mesh_instances,
			"triangle_surfaces_checked": triangle_surfaces,
			"unsupported_mesh_instances": unsupported,
			"missing_surface_count": missing,
			"findings": findings, "total_count": total,
			"offset": offset, "limit": limit, "has_more": total - offset > findings.size(),
		}}


var _connection: McpConnection
var _frame_signal: Variant
var _edited_root: Callable
var _frame_budget_usec: int
var _scene_generation := 0
var _jobs: Array[ScanJob] = []
var _next_job := 0
var _driving := false


func _init(
	connection: McpConnection,
	scene_changed_signal: Signal = Signal(),
	frame_signal: Variant = null,
	edited_root: Callable = Callable(),
	frame_budget_usec: int = FRAME_BUDGET_USEC,
) -> void:
	_connection = connection
	_frame_signal = frame_signal
	_edited_root = edited_root
	_frame_budget_usec = frame_budget_usec
	if not scene_changed_signal.is_null():
		scene_changed_signal.connect(_on_scene_changed)


func check_lightmap_uv2(params: Dictionary) -> Dictionary:
	var strings := {"path": "", "scene_file": "", "scope": "bake_candidates"}
	for key in strings:
		var value: Variant = params.get(key, strings[key])
		var error: Variant = ParamValidators.require_string(key, value)
		if error != null:
			return error
		strings[key] = str(value)
	if strings.scope not in ["bake_candidates", "all"]:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "scope must be 'bake_candidates' or 'all', got '%s'" % strings.scope)

	var page := {"offset": 0, "limit": 100}
	for key in page:
		var value: Variant = params.get(key, page[key])
		## JSON numbers arrive as floats. Only whole int64 values are safe
		## to convert. The exclusive bound is exactly representable as float.
		if value is float and is_finite(value) and value == floor(value) and absf(value) < 9223372036854775808.0:
			value = int(value)
		if not value is int:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be an integer" % key)
		page[key] = value
	if page.offset < 0 or page.limit < 1 or page.limit > 200:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "offset must be at least 0 and limit must be in 1..200 (got offset=%d, limit=%d)" % [page.offset, page.limit])

	var request_id: String = params.get("_request_id", "")
	if request_id.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Call check_lightmap_uv2 directly with a request ID so it can reply after scanning across editor frames.")
	if not is_instance_valid(_connection) or not _connection.is_inside_tree() or _connection.dispatcher == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "The editor connection is unavailable.")

	var scene_check := ScenePath.require_edited_scene(strings.scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node
	var target := scene_root if strings.path.is_empty() else ScenePath.resolve(strings.path, scene_root)
	if not _in_bake_tree(target, scene_root):
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "Node '%s' is not in an owned branch of the edited scene." % strings.path)

	var job := ScanJob.new()
	job.request_id = request_id
	job.scene_id = scene_root.get_instance_id()
	job.scene_file = scene_root.scene_file_path
	job.scene_path = ScenePath.from_node(scene_root, scene_root)
	job.scene_generation = _scene_generation
	job.target_id = target.get_instance_id()
	job.target_path = ScenePath.from_node(target, scene_root)
	job.scope = strings.scope
	job.offset = page.offset
	job.limit = page.limit
	job.stack.append(Cursor.new(target))
	_jobs.append(job)
	if not _driving:
		var frame: Signal = _frame_signal if _frame_signal is Signal else _connection.get_tree().process_frame
		_drive_jobs(self, frame)
	return {"_deferred": true, "_deferred_timeout_ms": TIMEOUT_MSEC}


func _on_scene_changed(_root: Node) -> void:
	_scene_generation += 1


static func _in_bake_tree(node: Node, root: Node) -> bool:
	var current := node
	while current != null and current != root and current.owner != null:
		current = current.get_parent()
	return current == root and not node.is_queued_for_deletion()


func _context_error(job: ScanJob, root: Node) -> Dictionary:
	if (
		job.scene_generation != _scene_generation
		or root == null or root.is_queued_for_deletion()
		or root.get_instance_id() != job.scene_id or root.scene_file_path != job.scene_file
		or ScenePath.from_node(root, root) != job.scene_path
	):
		return ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "The edited scene changed during the lightmap UV2 check. Run the check again in the intended scene.")
	var target := instance_from_id(job.target_id) as Node
	if (
		not _in_bake_tree(target, root)
		or ScenePath.from_node(target, root) != job.target_path
	):
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "The lightmap UV2 check target '%s' changed during the check." % job.target_path)
	if not job.stack.is_empty():
		var cursor := job.stack.back() as Cursor
		var active_node := instance_from_id(cursor.node_id) as Node
		if not _in_bake_tree(active_node, target) or (active_node.owner.get_instance_id() if active_node.owner != null else 0) != cursor.owner_id:
			job.invalidate()
	return {}


## Keep the handler alive until the driver retires. Ordinary teardown may
## release the lazy handler cache before the next process_frame resumes it.
static func _drive_jobs(handler, frame: Signal) -> void:
	var work_id := ScriptWork.begin(COMMAND)
	handler._driving = true
	var connection: McpConnection = handler._connection
	while not handler._jobs.is_empty():
		## Even the first slice starts after the dispatcher reserves the reply.
		await frame
		if not is_instance_valid(connection) or not connection.is_inside_tree() or connection.dispatcher == null:
			handler._jobs.clear()
			break
		handler._step_jobs()
	handler._next_job = 0
	handler._driving = false
	ScriptWork.finish(work_id)


func _step_jobs() -> void:
	var frame_end := Time.get_ticks_usec() + _frame_budget_usec
	var job_count := _jobs.size()
	@warning_ignore("integer_division")
	var quantum := maxi(1, _frame_budget_usec / job_count)
	var root: Node = _edited_root.call() if _edited_root.is_valid() else EditorInterface.get_edited_scene_root()
	for i in job_count:
		if i > 0 and Time.get_ticks_usec() >= frame_end:
			break
		_next_job %= _jobs.size()
		var job := _jobs[_next_job]
		if not _connection.dispatcher.has_pending_deferred_response(job.request_id):
			_jobs.remove_at(_next_job)
			continue
		var response := _context_error(job, root)
		if response.is_empty() and Time.get_ticks_msec() - job.started_msec >= TIMEOUT_MSEC:
			response = ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "The lightmap UV2 check exceeded 30 seconds.")
		if response.is_empty() and job.invalidated:
			response = job.changed_error()
		elif response.is_empty() and job.stack.is_empty():
			if i > 0:
				break  # Give final verification a fresh frame.
			response = job.response(Time.get_ticks_usec() + FRAME_BUDGET_USEC)
		elif response.is_empty():
			var slice_end := mini(frame_end, Time.get_ticks_usec() + quantum)
			while not job.invalidated and not job.stack.is_empty():
				job.advance(root)
				if Time.get_ticks_usec() >= slice_end:
					break
			if job.invalidated:
				response = job.changed_error()
		if not response.is_empty():
			_jobs.remove_at(_next_job)
			_connection.send_deferred_response(job.request_id, response)
		else:
			_next_job += 1
