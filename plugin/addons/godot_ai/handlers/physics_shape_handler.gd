@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Sizes a CollisionShape2D/CollisionShape3D to match a visual sibling's
## bounds. Auto-creates the concrete Shape subclass when the slot is empty
## or the requested type differs — bundling creation and sizing in a single
## undo action.
##
## Shape type defaults: Box for 3D, Rectangle for 2D.

var _undo_redo: EditorUndoRedoManager
var _connection


func _init(undo_redo: EditorUndoRedoManager, connection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


const _SHAPE_3D_CLASSES := {
	"box": "BoxShape3D",
	"sphere": "SphereShape3D",
	"capsule": "CapsuleShape3D",
	"cylinder": "CylinderShape3D",
}

const _SHAPE_2D_CLASSES := {
	"rectangle": "RectangleShape2D",
	"circle": "CircleShape2D",
	"capsule": "CapsuleShape2D",
}

const _GENERATED_BODY_CLASSES := {
	"static": "StaticBody3D",
	"area": "Area3D",
}
const _GENERATE_DIRECT_MAX_PATHS := 16
const _GENERATE_MAX_PATHS := 1024
## One deferred request may spend this long across editor frames. The Python
## handler's timeout is this plus its transport margin (a source-shape test
## keeps the two together).
const _GENERATE_DEFERRED_TIMEOUT_MS := 30000
## Wall-clock budget one editor frame gives the job, the same order as the
## dispatcher's own tick budget: a 1024-path request neither stalls the editor
## nor waits out hundreds of near-empty frames.
const _GENERATE_FRAME_BUDGET_USEC := 4000
const _GENERATE_COLLIDER_SUFFIX := "Collider"
const _GENERATE_SCALE_EPSILON := 0.0001


## Accept either the short form ("box") or the matching Godot class name
## ("BoxShape3D") — every other tool in the server takes class names, and
## resource_get_info(type="Shape3D") surfaces concrete_subclasses by class.
## Returns "" when neither form matches.
static func _normalize_shape_type(type_map: Dictionary, requested: String) -> String:
	if type_map.has(requested):
		return requested
	for short_form in type_map:
		if type_map[short_form] == requested:
			return short_form
	return ""


## Generates sibling physics bodies and collision shapes for MeshInstance3D
## nodes. Every path and option is validated before the first mutation, and a
## deferred request re-validates each mesh again when it is applied, so a
## scene edited during the window can only fail the whole request, never
## leave a partially generated batch.
func generate(params: Dictionary) -> Dictionary:
	var validated := _validate_generate_request(params)
	if validated.has("error"):
		return validated

	var request_id: String = params.get("_request_id", "")
	if _connection != null and not request_id.is_empty():
		var job := _generate_job(validated, _undo_redo, _connection, request_id)
		_drive_generate_job(job, _connection)
		return {
			"_deferred": true,
			"_deferred_timeout_ms": _GENERATE_DEFERRED_TIMEOUT_MS,
		}

	## `dispatch_direct()` strips the request id, so batch_execute and unit-test
	## callers cannot yield across frames. Keep that compatibility path bounded;
	## larger requests must use the normal MCP command and its deferred reply.
	var path_count: int = validated.paths.size()
	if path_count > _GENERATE_DIRECT_MAX_PATHS:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			(
				"physics_shape_generate received %d paths; inside batch_execute at most %d are "
				+ "supported — call resource_manage(op='physics_shape_generate') directly for larger batches"
			) % [path_count, _GENERATE_DIRECT_MAX_PATHS],
		)
	var job := _generate_job(validated, _undo_redo, null, "")
	while not _generate_step(job, -1):
		pass
	return job.result


## Validate the request shape and options first (no scene needed), then the
## edited scene. Nothing here touches a node.
static func _validate_generate_request(params: Dictionary) -> Dictionary:
	var requested_shape := String(params.get("shape_type", "box"))
	var shape_type := _normalize_shape_type(_SHAPE_3D_CLASSES, requested_shape)
	if shape_type.is_empty():
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid shape_type '%s'. Valid: %s" % [requested_shape, ", ".join(_SHAPE_3D_CLASSES.keys())]
		)
	var body_type := String(params.get("body_type", "static"))
	if not _GENERATED_BODY_CLASSES.has(body_type):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid body_type '%s'. Valid: %s" % [body_type, ", ".join(_GENERATED_BODY_CLASSES.keys())]
		)

	var raw_paths: Variant = params.get("paths", [])
	if not raw_paths is Array:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"paths must be an array of MeshInstance3D scene paths, got %s" % type_string(typeof(raw_paths)),
		)
	if raw_paths.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: paths")
	if raw_paths.size() > _GENERATE_MAX_PATHS:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"paths supports at most %d entries per request, got %d" % [_GENERATE_MAX_PATHS, raw_paths.size()],
		)
	var paths: Array[String] = []
	var seen := {}
	for index in raw_paths.size():
		var raw_path: Variant = raw_paths[index]
		if not raw_path is String:
			return ErrorCodes.make(
				ErrorCodes.WRONG_TYPE,
				"paths[%d] must be a MeshInstance3D scene path string, got %s"
				% [index, type_string(typeof(raw_path))],
			)
		if seen.has(raw_path):
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				"paths lists %s twice (entries %d and %d); each mesh gets one collider"
				% [raw_path, int(seen[raw_path]), index],
			)
		seen[raw_path] = index
		paths.append(raw_path)

	var scene_check := McpScenePath.require_edited_scene(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	return {
		"data": true,
		"scene_root": scene_check.node,
		"scene_file": params.get("scene_file", ""),
		"shape_type": shape_type,
		"body_type": body_type,
		"paths": paths,
	}


## Resolve one mesh and capture everything the apply step must find unchanged.
static func _plan_generate_mesh(
	mesh_path: String, scene_file: String, scene_root: Node, shape_type: String
) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(mesh_path, "paths", scene_file)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if node == scene_root:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"%s is the scene root — a sibling body needs a parent inside the scene" % mesh_path
		)
	if not node is MeshInstance3D:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Node at %s is %s — must be MeshInstance3D" % [mesh_path, node.get_class()]
		)
	var mesh := node as MeshInstance3D
	var parent := mesh.get_parent()
	if parent == null:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"MeshInstance3D at %s has no parent — cannot create a sibling body" % mesh_path
		)
	if mesh.mesh == null:
		return ErrorCodes.make(
			ErrorCodes.RESOURCE_NOT_FOUND,
			"MeshInstance3D at %s has no mesh resource — there are no bounds to fit" % mesh_path
		)
	var collider_name := mesh.name + _GENERATE_COLLIDER_SUFFIX
	var existing := parent.get_node_or_null(NodePath(collider_name))
	if existing != null:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"MeshInstance3D at %s already has a collider sibling at %s — remove or rename it first"
			% [mesh_path, McpScenePath.from_node(existing, scene_root)]
		)
	## A sibling in parent space inherits the parent chain's scale exactly like
	## the mesh does, so its box matches the visual; but Godot cannot scale a
	## sphere, capsule or cylinder non-uniformly (the warning it prints is a
	## deformed collider). A top-level mesh ignores its parent's transform.
	if not mesh.top_level and shape_type != "box" and parent is Node3D:
		var parent_scale: Vector3 = (parent as Node3D).global_transform.basis.get_scale()
		var spread := absf(parent_scale.x - parent_scale.y)
		spread = maxf(spread, absf(parent_scale.y - parent_scale.z))
		if spread > _GENERATE_SCALE_EPSILON * maxf(1.0, parent_scale.length()):
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				(
					"MeshInstance3D at %s sits under a parent chain scaled %s; a %s collider "
					+ "cannot be scaled non-uniformly — use shape_type 'box' or reparent the mesh"
				) % [mesh_path, parent_scale, shape_type]
			)
	var source_transform := mesh.global_transform if mesh.top_level else mesh.transform
	var body_transform := Transform3D(
		Basis(source_transform.basis.get_rotation_quaternion()),
		source_transform.origin,
	)
	var mesh_to_body := body_transform.affine_inverse() * source_transform
	var bounds: AABB = mesh_to_body * mesh.get_aabb()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"MeshInstance3D at %s has empty bounds %s — nothing to fit" % [mesh_path, bounds]
		)
	return {"plan": {
		"mesh": mesh,
		"mesh_path": mesh_path,
		"parent": parent,
		"collider_name": collider_name,
		"top_level": mesh.top_level,
		"source_transform": source_transform,
		"body_transform": body_transform,
		"bounds": bounds,
	}}


## Why a plan captured earlier no longer describes the scene, or "" when it
## still does. Checked again right before each body is added, so a deferred
## request can never apply plan-time state to a mesh that moved, was
## reparented, lost its mesh, gained a collider, or went away meanwhile.
static func _plan_stale_reason(plan: Dictionary) -> String:
	var mesh: MeshInstance3D = plan.mesh
	## A node taken out of the tree and queued to free is still a valid
	## instance for the rest of the frame; not being in the tree is what
	## "removed" means here.
	if not is_instance_valid(mesh) or not mesh.is_inside_tree():
		return "was removed"
	var parent: Node = plan.parent
	if not is_instance_valid(parent) or mesh.get_parent() != parent:
		return "was reparented"
	if mesh.top_level != bool(plan.top_level):
		return "changed its top_level setting"
	var source_transform := mesh.global_transform if mesh.top_level else mesh.transform
	if not source_transform.is_equal_approx(plan.source_transform):
		return "moved"
	if mesh.mesh == null:
		return "lost its mesh resource"
	if parent.get_node_or_null(NodePath(str(plan.collider_name))) != null:
		return "gained a collider sibling"
	return ""


## Build one detached body/collision pair from a prevalidated mesh plan.
static func _create_generated_entry(
	plan: Dictionary, shape_type: String, body_type: String
) -> Dictionary:
	var mesh: MeshInstance3D = plan.mesh
	var body: CollisionObject3D = ClassDB.instantiate(_GENERATED_BODY_CLASSES[body_type])
	body.name = str(plan.collider_name)
	body.top_level = bool(plan.top_level)
	body.transform = plan.body_transform
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var bounds: AABB = plan.bounds
	collision.position = bounds.get_center()
	var shape: Shape3D = ClassDB.instantiate(_SHAPE_3D_CLASSES[shape_type])
	_apply_shape_size(shape, shape_type, {"aabb": bounds}, true)
	collision.shape = shape
	body.add_child(collision)
	return {
		"mesh": mesh,
		"parent": plan.parent,
		"body": body,
		"collision": collision,
	}


## Record all generated nodes as one undo action, optionally executing it.
static func _commit_generated_action(
	created_nodes: Array[Dictionary],
	scene_root: Node,
	undo_redo: EditorUndoRedoManager,
	execute: bool,
) -> void:
	undo_redo.create_action("MCP: Generate physics shapes for %d mesh(es)" % created_nodes.size())
	for entry in created_nodes:
		var parent: Node = entry.parent
		var body: CollisionObject3D = entry.body
		var collision: CollisionShape3D = entry.collision
		undo_redo.add_do_method(parent, "add_child", body, true)
		undo_redo.add_do_method(body, "set_owner", scene_root)
		undo_redo.add_do_method(collision, "set_owner", scene_root)
		undo_redo.add_do_reference(body)
		undo_redo.add_undo_method(parent, "remove_child", body)
	undo_redo.commit_action(execute)


## Build the public response after every body is present in the edited scene.
static func _generated_response(
	created_nodes: Array[Dictionary], scene_root: Node, shape_type: String, body_type: String
) -> Dictionary:
	var created: Array[Dictionary] = []
	for entry in created_nodes:
		created.append({
			"mesh_path": McpScenePath.from_node(entry.mesh, scene_root),
			"body_path": McpScenePath.from_node(entry.body, scene_root),
			"shape_path": McpScenePath.from_node(entry.collision, scene_root),
			"shape_type": shape_type,
			"body_type": body_type,
		})
	return {"data": {"created": created, "undoable": true}}


## The whole request as a value the frame loop (or a test) advances with
## `_generate_step`. Phase "plan" resolves and measures every path; phase
## "apply" re-validates each plan and adds its body immediately; the last
## step records one undo action and fills `result`.
static func _generate_job(
	validated: Dictionary, undo_redo: EditorUndoRedoManager, connection, request_id: String
) -> Dictionary:
	return {
		"validated": validated,
		"undo_redo": undo_redo,
		"connection": connection,
		"request_id": request_id,
		"phase": "plan",
		"index": 0,
		"plans": [],
		"created": [],
		"result": {},
		"started_ms": Time.get_ticks_msec(),
	}


## Advance the job for at most `budget_usec` of wall-clock time (0 does one
## item, a negative budget runs to completion). Returns true once `job.result`
## holds the reply, or once the request was abandoned (empty result).
static func _generate_step(job: Dictionary, budget_usec: int) -> bool:
	if str(job.phase) == "done":
		return true
	var validated: Dictionary = job.validated
	var connection = job.connection
	if connection != null:
		if not _deferred_request_pending(connection, str(job.request_id)):
			## The dispatcher gave up on this request (timeout, client gone):
			## nothing may be left behind and nothing can be answered.
			_generate_rollback(job)
			job.phase = "done"
			return true
		if Time.get_ticks_msec() - int(job.started_ms) > _GENERATE_DEFERRED_TIMEOUT_MS:
			return _generate_fail(job, ErrorCodes.make(
				ErrorCodes.DEFERRED_TIMEOUT,
				"physics_shape_generate exceeded its %d ms budget" % _GENERATE_DEFERRED_TIMEOUT_MS,
			))
	var scene_root: Node = validated.scene_root
	if not is_instance_valid(scene_root) or EditorInterface.get_edited_scene_root() != scene_root:
		return _generate_fail(job, ErrorCodes.make(
			ErrorCodes.EDITED_SCENE_MISMATCH,
			"The edited scene changed while physics shapes were generated",
		))
	## The budget is checked before each item after the first, so every step
	## makes progress and a phase that just finished its last item moves on.
	var frame_start := Time.get_ticks_usec()
	var work := 0
	var paths: Array = validated.paths
	while str(job.phase) == "plan":
		if int(job.index) >= paths.size():
			job.phase = "apply"
			job.index = 0
			break
		if work > 0 and budget_usec >= 0 and Time.get_ticks_usec() - frame_start >= budget_usec:
			return false
		var planned := _plan_generate_mesh(
			str(paths[int(job.index)]), str(validated.scene_file), scene_root, str(validated.shape_type)
		)
		if planned.has("error"):
			return _generate_fail(job, planned)
		job.plans.append(planned.plan)
		job.index = int(job.index) + 1
		work += 1
	var plans: Array = job.plans
	while str(job.phase) == "apply" and int(job.index) < plans.size():
		if work > 0 and budget_usec >= 0 and Time.get_ticks_usec() - frame_start >= budget_usec:
			return false
		var plan: Dictionary = plans[int(job.index)]
		var stale := _plan_stale_reason(plan)
		if not stale.is_empty():
			var code: String = ErrorCodes.NODE_NOT_FOUND if stale == "was removed" else ErrorCodes.EDITED_SCENE_MISMATCH
			return _generate_fail(job, ErrorCodes.make(
				code,
				"MeshInstance3D at %s %s while physics shapes were generated; nothing was changed"
				% [str(plan.mesh_path), stale],
			))
		var entry := _create_generated_entry(plan, str(validated.shape_type), str(validated.body_type))
		var parent: Node = plan.parent
		parent.add_child(entry.body, true)
		entry.body.set_owner(scene_root)
		entry.collision.set_owner(scene_root)
		job.created.append(entry)
		job.index = int(job.index) + 1
		work += 1
	## The nodes are already in the scene, so commit with execute=false: one
	## atomic undo/redo action without replaying every mutation now.
	var created: Array[Dictionary] = []
	created.assign(job.created)
	_commit_generated_action(created, scene_root, job.undo_redo, false)
	job.result = _generated_response(
		created, scene_root, str(validated.shape_type), str(validated.body_type)
	)
	job.phase = "done"
	return true


static func _generate_fail(job: Dictionary, error: Dictionary) -> bool:
	_generate_rollback(job)
	job.result = error
	job.phase = "done"
	return true


## Remove and free every body this job added; none is in an undo action yet.
static func _generate_rollback(job: Dictionary) -> void:
	for entry in job.created:
		var body: Node = entry.body
		if not is_instance_valid(body):
			continue
		var parent := body.get_parent()
		if parent != null:
			parent.remove_child(body)
		body.free()
	job.created.clear()


## Check that the connection and deferred dispatcher entry are both live.
static func _deferred_request_pending(connection, request_id: String) -> bool:
	if not is_instance_valid(connection):
		return false
	var dispatcher = connection.dispatcher
	return dispatcher == null or dispatcher.has_pending_deferred_response(request_id)


## Drive a deferred job one editor frame at a time and reply when it ends.
## `send_deferred_response` itself drops a reply whose request is gone.
static func _drive_generate_job(job: Dictionary, connection) -> void:
	if not is_instance_valid(connection):
		return
	var tree: SceneTree = connection.get_tree()
	if tree == null:
		return
	## The first yield lets the dispatcher register the deferred request before
	## any validation error or successful result can be sent.
	await tree.process_frame
	while is_instance_valid(connection) and not _generate_step(job, _GENERATE_FRAME_BUDGET_USEC):
		await tree.process_frame
	if is_instance_valid(connection) and not job.result.is_empty():
		connection.send_deferred_response(str(job.request_id), job.result)


func autofit(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	if node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var scene_root: Node = _resolved.scene_root

	var is_3d := node is CollisionShape3D
	var is_2d := node is CollisionShape2D
	if not (is_3d or is_2d):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Node at %s is %s — must be CollisionShape3D or CollisionShape2D" % [node_path, node.get_class()]
		)

	var source_path: String = params.get("source_path", "")
	var source: Node = null
	if source_path.is_empty():
		var search := _find_bounds_visual(node, is_3d, scene_root)
		if search.has("error"):
			return search.error
		source = search.source
	else:
		source = McpScenePath.resolve(source_path, scene_root)
		if source == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
				"source_path: %s" % McpScenePath.format_node_error(source_path, scene_root))

	var requested_shape: String = params.get("shape_type", "box" if is_3d else "rectangle")
	var type_map := _SHAPE_3D_CLASSES if is_3d else _SHAPE_2D_CLASSES
	var shape_type := _normalize_shape_type(type_map, requested_shape)
	if shape_type.is_empty():
		var valid_pairs: Array[String] = []
		for short_form in type_map:
			valid_pairs.append("%s (%s)" % [short_form, type_map[short_form]])
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid shape_type '%s' for %s. Valid: %s" % [requested_shape, node.get_class(), ", ".join(valid_pairs)]
		)
	var shape_class: String = type_map[shape_type]

	# Measure the visual.
	var bounds := _measure_bounds(source, is_3d)
	if bounds.has("error"):
		return bounds.error

	# Reuse the existing shape if it already matches the requested class;
	# otherwise create a fresh one of the right type in the same undo action.
	var existing_shape: Shape3D = null
	var existing_shape_2d: Shape2D = null
	if is_3d:
		existing_shape = node.shape
	else:
		existing_shape_2d = node.shape

	var needs_new_shape := false
	if is_3d:
		needs_new_shape = existing_shape == null or existing_shape.get_class() != shape_class
	else:
		needs_new_shape = existing_shape_2d == null or existing_shape_2d.get_class() != shape_class

	var target_shape: Resource
	if needs_new_shape:
		var instance := ClassDB.instantiate(shape_class)
		if instance == null:
			return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % shape_class)
		target_shape = instance
	else:
		target_shape = existing_shape if is_3d else existing_shape_2d

	# Compute and apply size.
	var size_info := _apply_shape_size(target_shape, shape_type, bounds, is_3d)
	var old_shape = existing_shape if is_3d else existing_shape_2d

	_undo_redo.create_action("MCP: Autofit %s on %s" % [shape_class, node.name])
	if needs_new_shape:
		_undo_redo.add_do_property(node, "shape", target_shape)
		_undo_redo.add_undo_property(node, "shape", old_shape)
		_undo_redo.add_do_reference(target_shape)
	else:
		# Existing shape stays, but its size changes — snapshot size for undo.
		for key in size_info.applied:
			var new_val = target_shape.get(key)
			var old_val = size_info.previous.get(key)
			_undo_redo.add_do_property(target_shape, key, new_val)
			_undo_redo.add_undo_property(target_shape, key, old_val)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"source_path": McpScenePath.from_node(source, scene_root) if source_path.is_empty() else source_path,
			"shape_type": shape_type,
			"shape_class": shape_class,
			"shape_created": needs_new_shape,
			"size": size_info.size_response,
			"undoable": true,
		}
	}


## Returns `{source: Node}` on success, `{error: <error dict>}` on failure.
## Ambiguous tier-2 matches put candidate scene paths in
## `error.data.candidates` so callers can pick one explicitly.
static func _find_bounds_visual(collision_node: Node, is_3d: bool, scene_root: Node) -> Dictionary:
	var parent := collision_node.get_parent()
	if parent == null:
		return {"error": _no_visual_error(is_3d)}

	# Tier 1: direct siblings of the collision shape. Uses the broad
	# VisualInstance3D filter for backwards compatibility — callers who put
	# the visual directly next to the collision picked it on purpose.
	var siblings := _measurable_visuals(parent.get_children(), collision_node, is_3d, false)
	if not siblings.is_empty():
		return {"source": siblings[0]}

	# Tier 2: parent siblings (uncles). Tighten the filter to
	# GeometryInstance3D so we don't auto-pick a Light3D / DirectionalLight3D
	# as a collision source. Auto-pick only when unambiguous; surface
	# multiple candidates so the agent chooses.
	var grandparent := parent.get_parent()
	if grandparent == null:
		return {"error": _no_visual_error(is_3d)}
	var uncles := _measurable_visuals(grandparent.get_children(), parent, is_3d, true)
	if uncles.size() == 1:
		return {"source": uncles[0]}
	if uncles.size() > 1:
		var paths: Array[String] = []
		for n in uncles:
			paths.append(McpScenePath.from_node(n, scene_root))
		var msg := "Multiple visual candidates near %s — pass source_path explicitly. Candidates: %s" % [
			McpScenePath.from_node(collision_node, scene_root),
			", ".join(paths),
		]
		var err := ErrorCodes.make(ErrorCodes.INVALID_PARAMS, msg)
		err["error"]["data"] = {"candidates": paths}
		return {"error": err}
	return {"error": _no_visual_error(is_3d)}


## Filter `nodes` for ones we can measure as a collision source. When
## `strict` is true (tier 2 / uncles) only GeometryInstance3D counts in 3D —
## avoids picking up lights as accidental sources. 2D filter is already
## narrow enough that strictness doesn't change behavior.
static func _measurable_visuals(nodes: Array, exclude: Node, is_3d: bool, strict: bool) -> Array[Node]:
	var out: Array[Node] = []
	for n in nodes:
		if n == exclude:
			continue
		if is_3d:
			if strict:
				if n is GeometryInstance3D:
					out.append(n)
			elif n is VisualInstance3D:
				out.append(n)
		elif n is Sprite2D or n is TextureRect:
			out.append(n)
	return out


static func _no_visual_error(is_3d: bool) -> Dictionary:
	var hint := "MeshInstance3D" if is_3d else "Sprite2D"
	return ErrorCodes.make(
		ErrorCodes.INVALID_PARAMS,
		"No visual found near collision shape — searched siblings and parent-siblings. Pass source_path explicitly (e.g. a %s)" % hint,
	)


## Measure the visual bounds of `source`. Returns {aabb: AABB} for 3D or
## {rect: Rect2} for 2D on success, or {error: ...} on failure.
## Bounds are returned in world-ish size (local extents scaled by the source
## node's own transform scale) so a MeshInstance3D at scale=(2,2,2) gives an
## 8× volume collider, not a unit collider.
static func _measure_bounds(source: Node, is_3d: bool) -> Dictionary:
	if is_3d:
		if source is VisualInstance3D:
			var aabb: AABB = (source as VisualInstance3D).get_aabb()
			# get_aabb() is local-space; apply the source's scale so the
			# collider tracks what you actually see in the viewport. Going
			# through the transform keeps a mirrored (negative) scale a
			# positive size, which BoxShape3D would otherwise reject.
			var scale_3d: Vector3 = (source as Node3D).transform.basis.get_scale()
			return {"aabb": Transform3D(Basis.from_scale(scale_3d), Vector3.ZERO) * aabb}
		return {"error": ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Source %s has no measurable 3D bounds (must be VisualInstance3D subclass)" % source.get_class()
		)}
	# 2D
	if source is Sprite2D:
		var s: Sprite2D = source
		var srect: Rect2 = s.get_rect()
		# get_rect() reports the local texture rect and ignores scale.
		srect.position = srect.position * s.scale
		srect.size = srect.size * s.scale
		return {"rect": srect}
	if source is TextureRect:
		var tr: TextureRect = source
		# tr.size is the Control's laid-out size, which is Vector2.ZERO
		# before the first layout pass (e.g. just after the node was created
		# via MCP). Fall back to the texture's own size when that happens,
		# so autofit doesn't silently produce a zero-sized shape.
		var tr_size: Vector2 = tr.size
		if tr_size.is_zero_approx():
			if tr.texture != null:
				tr_size = tr.texture.get_size() * tr.scale
			else:
				return {"error": ErrorCodes.make(
					ErrorCodes.INVALID_PARAMS,
					"TextureRect at %s has zero layout size and no texture to fall back to — autofit would produce a zero-sized shape" % source.name
				)}
		return {"rect": Rect2(Vector2.ZERO, tr_size)}
	return {"error": ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Source %s has no measurable 2D bounds (must be Sprite2D or TextureRect)" % source.get_class()
	)}


## Apply size to `shape` based on `bounds` and the requested shape_type.
## Returns {applied: [property_names], previous: {name: old_value}, size_response: dict}.
static func _apply_shape_size(shape: Resource, shape_type: String, bounds: Dictionary, is_3d: bool) -> Dictionary:
	var applied: Array[String] = []
	var previous := {}
	var size_response := {}

	if is_3d:
		var aabb: AABB = bounds.aabb
		var size_v: Vector3 = aabb.size
		match shape_type:
			"box":
				previous["size"] = shape.get("size")
				(shape as BoxShape3D).size = size_v
				applied.append("size")
				size_response = {"x": size_v.x, "y": size_v.y, "z": size_v.z}
			"sphere":
				var r := maxf(maxf(size_v.x, size_v.y), size_v.z) * 0.5
				previous["radius"] = shape.get("radius")
				(shape as SphereShape3D).radius = r
				applied.append("radius")
				size_response = {"radius": r}
			"capsule":
				var cap := shape as CapsuleShape3D
				var r2 := maxf(size_v.x, size_v.z) * 0.5
				var h := size_v.y
				previous["radius"] = cap.radius
				previous["height"] = cap.height
				# CapsuleShape3D enforces height >= 2*radius and silently
				# clamps setters that would violate it. Read back the
				# stored values so the response reflects reality.
				cap.radius = r2
				cap.height = h
				applied.append("radius")
				applied.append("height")
				size_response = {"radius": cap.radius, "height": cap.height}
			"cylinder":
				var cyl := shape as CylinderShape3D
				var r3 := maxf(size_v.x, size_v.z) * 0.5
				var ch := size_v.y
				previous["radius"] = cyl.radius
				previous["height"] = cyl.height
				cyl.radius = r3
				cyl.height = ch
				applied.append("radius")
				applied.append("height")
				size_response = {"radius": cyl.radius, "height": cyl.height}
	else:
		var rect: Rect2 = bounds.rect
		var sz: Vector2 = rect.size
		match shape_type:
			"rectangle":
				previous["size"] = shape.get("size")
				(shape as RectangleShape2D).size = sz
				applied.append("size")
				size_response = {"x": sz.x, "y": sz.y}
			"circle":
				var cr := maxf(sz.x, sz.y) * 0.5
				previous["radius"] = shape.get("radius")
				(shape as CircleShape2D).radius = cr
				applied.append("radius")
				size_response = {"radius": cr}
			"capsule":
				var cap2 := shape as CapsuleShape2D
				var cr2 := sz.x * 0.5
				var ch2 := sz.y
				previous["radius"] = cap2.radius
				previous["height"] = cap2.height
				# CapsuleShape2D has the same height >= 2*radius invariant
				# as its 3D counterpart; read back what Godot actually kept.
				cap2.radius = cr2
				cap2.height = ch2
				applied.append("radius")
				applied.append("height")
				size_response = {"radius": cap2.radius, "height": cap2.height}

	return {"applied": applied, "previous": previous, "size_response": size_response}
