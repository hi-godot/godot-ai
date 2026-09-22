@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MARKER := &"_godot_ai_physics_v1"

var _host: Script
var _watches: Array[Dictionary] = []
var _seen: Dictionary = {}


static func prepare_markers(entry: Dictionary) -> void:
	var name := str(ClassDB.class_get_property(entry.mesh, "name"))
	var body_name := str(entry.body.name)
	var wrapped := bool(entry.reparent_mesh)
	entry["old_marker_present"] = entry.mesh.has_meta(MARKER)
	entry["old_marker"] = entry.mesh.get_meta(MARKER) if entry.mesh.has_meta(MARKER) else null
	entry["marker"] = {
		"version": 1, "wrapped": wrapped,
		"body": NodePath(".." if wrapped else "../" + body_name),
		"collision": NodePath("../CollisionShape3D" if wrapped else "../" + body_name + "/CollisionShape3D"),
	}
	entry.body.set_meta(MARKER, {
		"version": 1, "wrapped": wrapped,
		"source": NodePath(name if wrapped else "../" + name),
		"collision": NodePath("CollisionShape3D"),
	})
	entry.collision.set_meta(MARKER, {
		"version": 1, "source": NodePath("../" + name if wrapped else "../../" + name),
		"body": NodePath(".."),
	})


static func record_marker_action(entry: Dictionary, undo: EditorUndoRedoManager, execute: bool) -> void:
	undo.add_do_method(entry.mesh, "set_meta", MARKER, entry.marker)
	if bool(entry.old_marker_present):
		undo.add_undo_method(entry.mesh, "set_meta", MARKER, entry.old_marker)
	else:
		undo.add_undo_method(entry.mesh, "remove_meta", MARKER)
	if not execute:
		entry.mesh.set_meta(MARKER, entry.marker)


static func _link(node: Node, marker: Variant, key: String) -> Node:
	if marker is not Dictionary or typeof(marker.get("version")) != TYPE_INT or marker.version != 1 or typeof(marker.get(key)) != TYPE_NODE_PATH:
		return null
	return node.get_node_or_null(marker[key])


static func relationship(mesh: MeshInstance3D, root: Node, body_type: String, wrapped: bool) -> Dictionary:
	var marker: Variant = mesh.get_meta(MARKER) if mesh.has_meta(MARKER) else {}
	var body := _link(mesh, marker, "body")
	var collision := _link(mesh, marker, "collision")
	if body == null or collision == null or collision.get_class() != "CollisionShape3D":
		return {}
	var classes := {"static": "StaticBody3D", "area": "Area3D", "rigid": "RigidBody3D", "character": "CharacterBody3D"}
	if body.get_class() != classes[body_type] or typeof(marker.get("wrapped")) != TYPE_BOOL or marker.wrapped != wrapped:
		return {}
	var body_marker: Variant = body.get_meta(MARKER) if body.has_meta(MARKER) else {}
	var collision_marker: Variant = collision.get_meta(MARKER) if collision.has_meta(MARKER) else {}
	if _link(body, body_marker, "source") != mesh or _link(body, body_marker, "collision") != collision:
		return {}
	if _link(collision, collision_marker, "source") != mesh or _link(collision, collision_marker, "body") != body:
		return {}
	if typeof(body_marker.get("wrapped")) != TYPE_BOOL or body_marker.wrapped != wrapped or collision.get_parent() != body:
		return {}
	if ClassDB.class_get_property(mesh, "owner") != root or ClassDB.class_get_property(body, "owner") != root or ClassDB.class_get_property(collision, "owner") != root:
		return {}
	if (wrapped and mesh.get_parent() != body) or (not wrapped and mesh.get_parent() != body.get_parent()):
		return {}
	return {"body": body, "collision": collision}


func _watch(resource: Resource, plan: Dictionary) -> void:
	if resource == null:
		return
	var callback := func(): plan["resource_changed"] = true
	resource.changed.connect(callback)
	_watches.append({"resource": resource, "callback": callback})


func _disconnect() -> void:
	for watch in _watches:
		if watch.resource.changed.is_connected(watch.callback):
			watch.resource.changed.disconnect(watch.callback)
	_watches.clear()


func _plan(path: String, validated: Dictionary) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(path, "paths", str(validated.scene_file))
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if node is not MeshInstance3D or not node.has_meta(MARKER):
		if node.get_parent() != null and node.get_parent().has_meta(MARKER):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot create beneath a generated body at %s: missing or inconsistent source provenance" % path)
		var fresh: Dictionary = _host._plan_generate_mesh(path, validated.scene_file, validated.scene_root, validated.shape_type, validated.reparent_mesh)
		if fresh.has("plan"):
			fresh.plan["world_transform"] = ClassDB.class_get_property(node, "global_transform")
			fresh.plan["source_owner"] = ClassDB.class_get_property(node, "owner")
		return fresh
	var mesh := node as MeshInstance3D
	var linked := relationship(mesh, validated.scene_root, validated.body_type, validated.reparent_mesh)
	if linked.is_empty() or ClassDB.class_get_property(mesh, "mesh") == null:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot refresh %s: generated provenance, ownership, body type or topology does not match" % path)
	var body := linked.body as CollisionObject3D
	var collision := linked.collision as CollisionShape3D
	if ClassDB.class_get_property(collision, "top_level"):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot refresh %s: collision top_level must remain false" % path)
	var shape_type: String = _host._auto_generate_shape(ClassDB.class_get_property(mesh, "mesh")) if validated.shape_type == "auto" else validated.shape_type
	var body_world: Transform3D = ClassDB.class_get_property(body, "global_transform")
	var basis := body_world.basis
	if absf(basis.determinant()) < 0.000001:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot refresh %s: body transform is singular" % path)
	var scale := basis.get_scale()
	var orthogonal := absf(basis.x.normalized().dot(basis.y.normalized())) < 0.0001 and absf(basis.x.normalized().dot(basis.z.normalized())) < 0.0001 and absf(basis.y.normalized().dot(basis.z.normalized())) < 0.0001
	if not orthogonal or (shape_type != "box" and not scale.abs().is_equal_approx(Vector3.ONE * absf(scale.x))):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot refresh %s: body scale/shear is unsupported for %s" % [path, shape_type])
	var mesh_to_body: Transform3D = body_world.affine_inverse() * ClassDB.class_get_property(mesh, "global_transform")
	var bounds := mesh_to_body * mesh.get_aabb()
	if bounds.size.x <= 0 or bounds.size.y <= 0 or bounds.size.z <= 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot refresh %s: mesh has empty bounds" % path)
	return {"plan": {
		"refresh": true, "mesh": mesh, "mesh_path": path, "parent": mesh.get_parent(),
		"body": body, "collision": collision, "shape_type": shape_type,
		"reparent_mesh": validated.reparent_mesh, "mesh_to_body": mesh_to_body, "bounds": bounds,
		"source_mesh": ClassDB.class_get_property(mesh, "mesh"), "source_bounds": mesh.get_aabb(), "source_transform": ClassDB.class_get_property(mesh, "global_transform"),
		"body_transform": ClassDB.class_get_property(body, "global_transform"), "body_parent": body.get_parent(), "body_top_level": ClassDB.class_get_property(body, "top_level"),
		"old_shape": ClassDB.class_get_property(collision, "shape"), "old_transform": ClassDB.class_get_property(collision, "transform"), "collision_top_level": ClassDB.class_get_property(collision, "top_level"),
		"marker": mesh.get_meta(MARKER).duplicate(true), "body_marker": body.get_meta(MARKER).duplicate(true),
		"collision_marker": collision.get_meta(MARKER).duplicate(true),
	}}


func _stale(plan: Dictionary, validated: Dictionary) -> String:
	var mesh = plan.mesh
	if not is_instance_valid(mesh) or not mesh.is_inside_tree():
		return "mesh was removed"
	if bool(plan.get("resource_changed", false)) or ClassDB.class_get_property(mesh, "mesh") != plan.source_mesh or not mesh.get_aabb().is_equal_approx(plan.source_bounds):
		return "geometry changed"
	if not bool(plan.get("refresh", false)):
		if ClassDB.class_get_property(mesh, "owner") != plan.source_owner or not ClassDB.class_get_property(mesh, "global_transform").is_equal_approx(plan.world_transform):
			return "source owner or world transform changed"
		if mesh.has_meta(MARKER) or mesh.get_parent().has_meta(MARKER):
			return "mesh provenance changed"
		return _host._plan_stale_reason(plan)
	var body = plan.body
	var collision = plan.collision
	if not is_instance_valid(body) or not is_instance_valid(collision) or not body.is_inside_tree() or not collision.is_inside_tree():
		return "body or collision was removed"
	var linked := relationship(mesh, validated.scene_root, validated.body_type, validated.reparent_mesh)
	if linked.is_empty() or linked.body != body or linked.collision != collision:
		return "generated relationship changed"
	if mesh.get_meta(MARKER) != plan.marker or body.get_meta(MARKER) != plan.body_marker or collision.get_meta(MARKER) != plan.collision_marker:
		return "provenance changed"
	if mesh.get_parent() != plan.parent or body.get_parent() != plan.body_parent or ClassDB.class_get_property(body, "top_level") != plan.body_top_level or ClassDB.class_get_property(collision, "top_level") != plan.collision_top_level:
		return "topology changed"
	if not ClassDB.class_get_property(mesh, "global_transform").is_equal_approx(plan.source_transform) or not ClassDB.class_get_property(body, "global_transform").is_equal_approx(plan.body_transform):
		return "source or body transform changed"
	if ClassDB.class_get_property(collision, "shape") != plan.old_shape or not ClassDB.class_get_property(collision, "transform").is_equal_approx(plan.old_transform):
		return "collision was edited"
	return ""


func _prepare(plan: Dictionary, validated: Dictionary) -> Dictionary:
	if not bool(plan.get("refresh", false)):
		return _host._create_generated_entry(plan, plan.shape_type, validated.body_type, validated.reparent_mesh)
	var shape: Shape3D
	if plan.shape_type in ["convex", "trimesh"]:
		var error: Dictionary = _host._validate_hull_workload(ClassDB.class_get_property(plan.mesh, "mesh"), plan.mesh_path, plan.shape_type)
		if not error.is_empty():
			return error
		shape = _host._fit_mesh_shape(plan.mesh, plan.shape_type, plan.mesh_to_body)
		if shape == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot fit degenerate mesh at %s" % plan.mesh_path)
	else:
		shape = ClassDB.instantiate(_host._SHAPE_3D_CLASSES[plan.shape_type])
		_host._apply_shape_size(shape, plan.shape_type, {"aabb": plan.bounds}, true)
	var entry := plan.duplicate()
	entry["new_shape"] = shape
	entry["new_transform"] = Transform3D.IDENTITY if plan.shape_type in ["convex", "trimesh"] else Transform3D(Basis.IDENTITY, _host._snap_tiny(plan.bounds.get_center()))
	return entry


func cleanup(job: Dictionary) -> void:
	_disconnect()
	for entry in job.created:
		if not bool(entry.get("refresh", false)) and is_instance_valid(entry.body):
			entry.body.free()
	job.created.clear()


func _fail(job: Dictionary, error: Dictionary) -> bool:
	cleanup(job)
	job.result = error
	job.phase = "done"
	return true


func step(job: Dictionary, budget_usec: int) -> bool:
	if _host == null:
		_host = load("res://addons/godot_ai/handlers/physics_shape_handler.gd")
	var v: Dictionary = job.validated
	if job.connection != null and not _host._deferred_request_pending(job.connection, job.request_id):
		return _fail(job, {})
	if Time.get_ticks_msec() - int(job.started_ms) > _host._GENERATE_DEFERRED_TIMEOUT_MS:
		return _fail(job, ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT, "Physics shape refresh exceeded its time budget"))
	if not is_instance_valid(v.scene_root) or EditorInterface.get_edited_scene_root() != v.scene_root:
		return _fail(job, ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "Edited scene changed during physics shape refresh"))
	var started := Time.get_ticks_usec()
	var work := 0
	while job.phase in ["plan", "prepare"]:
		if work > 0 and budget_usec >= 0 and Time.get_ticks_usec() - started >= budget_usec:
			return false
		if job.phase == "plan":
			if job.index >= v.paths.size():
				job.phase = "prepare"
				job.index = 0
				continue
			var planned := _plan(v.paths[job.index], v)
			if planned.has("error"):
				return _fail(job, planned)
			var plan: Dictionary = planned.plan
			var identity: int = plan.mesh.get_instance_id()
			if _seen.has(identity):
				return _fail(job, ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Multiple paths resolve to the same mesh"))
			_seen[identity] = true
			job.plans.append(plan)
			_watch(plan.source_mesh, plan)
			if bool(plan.get("refresh", false)):
				_watch(plan.old_shape, plan)
		else:
			if job.index >= job.plans.size():
				job.phase = "commit"
				break
			var plan: Dictionary = job.plans[job.index]
			var reason := _stale(plan, v)
			if not reason.is_empty():
				return _fail(job, ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "%s: %s" % [plan.mesh_path, reason]))
			var entry := _prepare(plan, v)
			if entry.has("error"):
				return _fail(job, entry)
			job.created.append(entry)
		job.index += 1
		work += 1
	for plan in job.plans:
		var reason := _stale(plan, v)
		if not reason.is_empty():
			return _fail(job, ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH, "%s: %s" % [plan.mesh_path, reason]))
	_disconnect()
	var entries: Array[Dictionary] = []
	entries.assign(job.created)
	_host._commit_generated_action(entries, v.scene_root, job.undo_redo, true)
	job.committed = true
	job.result = _host._generated_response(entries, v.scene_root, v.body_type)
	job.phase = "done"
	return true
