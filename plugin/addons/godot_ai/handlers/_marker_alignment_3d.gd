@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const PATH_PARAMS: Array[String] = ["path", "source_marker_path", "target_marker_path"]
const AXIS_TOLERANCE := 0.0001
const POSITION_TOLERANCE := 0.0001
const MAX_NORMALIZED_INVERSE_COMPONENT := 100000.0


static func align(params: Dictionary, undo_redo: EditorUndoRedoManager) -> Dictionary:
	for key in PATH_PARAMS + ["orientation", "scene_file"]:
		if params.has(key) and not params[key] is String:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "%s must be a string" % key)
	for key in PATH_PARAMS:
		if params.get(key, "").is_empty():
			return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % key)
	var orientation: String = params.get("orientation", "match")
	if orientation != "match" and orientation != "face_to_face":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "orientation must be 'match' or 'face_to_face', got '%s'" % orientation)
	var scene := McpScenePath.require_edited_scene(params.get("scene_file", ""))
	if scene.has("error"):
		return scene
	var scene_root: Node = scene.node
	var nodes: Array[Node] = []
	var data := {"orientation": orientation, "changed": false, "undoable": false}
	for key in PATH_PARAMS:
		var path: String = params[key]
		var node := McpScenePath.resolve(path, scene_root)
		var canonical := McpScenePath.from_node(node, scene_root)
		if canonical.is_empty() or not node.is_inside_tree():
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "%s: %s" % [key, McpScenePath.format_node_error(path, scene_root)])
		data[key] = canonical
		nodes.append(node)

	var mover := nodes[0] as Node3D
	var source := nodes[1] as Marker3D
	var target := nodes[2] as Marker3D
	if mover == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "path must refer to a Node3D: %s" % data.path)
	if source == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "source_marker_path must refer to a Marker3D: %s" % data.source_marker_path)
	if target == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "target_marker_path must refer to a Marker3D: %s" % data.target_marker_path)
	var world := mover.get_world_3d()
	if world == null or source.get_world_3d() != world or target.get_world_3d() != world:
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "The mover and both markers must share a World3D: %s, %s, %s" % [data.path, data.source_marker_path, data.target_marker_path])

	var source_chain: Array[Node3D] = []
	var current: Node3D = source
	while current != null and current != mover:
		source_chain.append(current)
		current = current.get_parent_node_3d()
	if current != mover or source_chain.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "source_marker_path must be a strict descendant that inherits the transform of %s: %s" % [data.path, data.source_marker_path])
	if target == mover or mover.is_ancestor_of(target):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "target_marker_path must be outside the subtree of %s: %s" % [data.path, data.target_marker_path])
	var write_error := McpNodeValidator.writable_error(mover, scene_root)
	if not write_error.is_empty():
		return write_error
	var ancestor: Node = mover
	while ancestor != scene_root:
		if ancestor.owner == null:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "Cannot persist the transform of %s because %s has no scene owner" % [data.path, McpScenePath.from_node(ancestor, scene_root)])
		ancestor = ancestor.get_parent()

	var plan := _plan(mover, source_chain, target, data)
	if plan.has("error"):
		return plan
	if plan.has("transform"):
		undo_redo.create_action("MCP: Align Markers on %s" % mover.name, UndoRedo.MERGE_DISABLE, scene_root)
		undo_redo.add_do_property(mover, &"transform", plan.transform)
		undo_redo.add_undo_property(mover, &"transform", plan.previous)
		undo_redo.commit_action()
		data.changed = true
		data.undoable = true
	return {"data": data}


static func _plan(mover: Node3D, source_chain: Array[Node3D], target: Marker3D, data: Dictionary) -> Dictionary:
	var previous := mover.transform
	var mover_world := mover.global_transform
	if not _usable_transform(previous) or not _usable_transform(mover_world):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "path has a non-finite, degenerate, or ill-conditioned transform: %s" % data.path)
	var parent := mover.get_parent_node_3d()
	var parent_world := parent.global_transform if parent != null else Transform3D.IDENTITY
	var inverse: Variant = _parent_basis_inverse(parent_world)
	if inverse == null:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "path has a non-finite or ill-conditioned transform parent: %s" % data.path)
	var parent_inverse: Basis = inverse

	var source_world := source_chain[0].global_transform
	var target_world := target.global_transform
	var source_frame: Variant = _marker_axes(source_world)
	var target_frame: Variant = _marker_axes(target_world)
	if source_frame == null:
		return _marker_transform_error("source_marker_path", data.source_marker_path)
	if target_frame == null:
		return _marker_transform_error("target_marker_path", data.target_marker_path)
	var source_axes: Basis = source_frame
	var goal_axes: Basis = target_frame
	if data.orientation == "face_to_face":
		# A half-turn about the target's local Y keeps its up axis and reverses X and Z.
		goal_axes = Basis(-goal_axes.x, goal_axes.y, -goal_axes.z)
	if _pose_matches(source_world.origin, source_axes, target_world.origin, goal_axes):
		return {}

	var rotation := goal_axes.orthonormalized() * source_axes.orthonormalized().transposed()
	var goal_origin := target_world.origin + rotation * (mover_world.origin - source_world.origin)
	# Use the full basis, including scale or shear hidden by Node3D's disable-scale option.
	var old_world_basis := parent_world.basis * previous.basis
	var new_world_basis := rotation * old_world_basis
	var candidate := Transform3D(parent_inverse * new_world_basis, parent_inverse * (goal_origin - parent_world.origin))
	if not _usable_transform(candidate):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot express the aligned local transform for %s" % data.path)

	# Evaluate the same transform chain Godot will use before adding an undo action.
	var moved_world := _inherited_transform(parent_world, candidate, mover)
	if not moved_world.is_finite() or not _basis_matches(moved_world.basis, rotation * mover_world.basis):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot preserve the world basis of %s with the aligned local transform" % data.path)
	var predicted := moved_world
	for index in range(source_chain.size() - 1, -1, -1):
		var step := source_chain[index]
		predicted = _inherited_transform(predicted, step.transform, step)
	var predicted_frame: Variant = _marker_axes(predicted)
	if predicted_frame == null or not _pose_matches(predicted.origin, predicted_frame, target_world.origin, goal_axes):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Cannot align %s with %s within transform precision" % [data.source_marker_path, data.target_marker_path])
	return {"previous": previous, "transform": candidate}


static func _marker_transform_error(key: String, path: String) -> Dictionary:
	return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s requires a finite transform with nondegenerate, orthogonal, right-handed world axes: %s" % [key, path])


static func _marker_axes(world_transform: Transform3D) -> Variant:
	if not world_transform.is_finite():
		return null
	var axes := _unit_axes(world_transform.basis)
	if (absf(axes.x.dot(axes.y)) > AXIS_TOLERANCE or absf(axes.x.dot(axes.z)) > AXIS_TOLERANCE
		or absf(axes.y.dot(axes.z)) > AXIS_TOLERANCE or axes.determinant() <= 0.0):
		return null
	return axes


static func _pose_matches(origin: Vector3, axes: Basis, goal_origin: Vector3, goal_axes: Basis) -> bool:
	return (origin.distance_to(goal_origin) <= POSITION_TOLERANCE
		and axes.x.distance_to(goal_axes.x) <= AXIS_TOLERANCE
		and axes.y.distance_to(goal_axes.y) <= AXIS_TOLERANCE
		and axes.z.distance_to(goal_axes.z) <= AXIS_TOLERANCE)


static func _basis_matches(actual: Basis, expected: Basis) -> bool:
	if not expected.is_finite():
		return false
	for index in 3:
		var magnitude := _axis_magnitude(expected[index])
		if magnitude == 0.0 or (actual[index] / magnitude).distance_to(expected[index] / magnitude) > AXIS_TOLERANCE:
			return false
	return true


static func _inherited_transform(parent: Transform3D, local: Transform3D, node: Node3D) -> Transform3D:
	var world_transform := parent * local
	if node.is_scale_disabled() and world_transform.is_finite():
		world_transform.basis = world_transform.basis.orthonormalized()
	return world_transform


static func _usable_transform(transform: Transform3D) -> bool:
	return transform.is_finite() and absf(_unit_axes(transform.basis).determinant()) > AXIS_TOLERANCE


static func _parent_basis_inverse(parent_world: Transform3D) -> Variant:
	if not parent_world.is_finite():
		return null
	var magnitude := _basis_magnitude(parent_world.basis)
	if magnitude == 0.0:
		return null
	# Scale first so the determinant tests conditioning independently of uniform scale.
	var normalized := parent_world.basis / magnitude
	var rows := normalized.transposed()
	if rows.x.dot(rows.y.cross(rows.z)) == 0.0:
		return null
	var inverse := normalized.inverse()
	if not inverse.is_finite() or _basis_magnitude(inverse) > MAX_NORMALIZED_INVERSE_COMPONENT:
		return null
	inverse /= magnitude
	return inverse if inverse.is_finite() else null


static func _unit_axes(basis: Basis) -> Basis:
	return Basis(_unit_axis(basis.x), _unit_axis(basis.y), _unit_axis(basis.z))


static func _unit_axis(axis: Vector3) -> Vector3:
	# Scale before measuring length so tiny and large axes remain usable.
	var magnitude := _axis_magnitude(axis)
	return (axis / magnitude).normalized() if magnitude > 0.0 else Vector3.ZERO


static func _axis_magnitude(axis: Vector3) -> float:
	return maxf(absf(axis.x), maxf(absf(axis.y), absf(axis.z)))


static func _basis_magnitude(basis: Basis) -> float:
	return maxf(_axis_magnitude(basis.x), maxf(_axis_magnitude(basis.y), _axis_magnitude(basis.z)))
