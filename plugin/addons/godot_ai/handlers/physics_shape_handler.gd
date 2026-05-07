@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Sizes a CollisionShape2D/CollisionShape3D to match a visual sibling's
## bounds. Auto-creates the concrete Shape subclass when the slot is empty
## or the requested type differs — bundling creation and sizing in a single
## undo action.
##
## Shape type defaults: Box for 3D, Rectangle for 2D.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


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
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND, "Source node not found: %s" % source_path)

	var shape_type: String = params.get("shape_type", "box" if is_3d else "rectangle")
	var type_map := _SHAPE_3D_CLASSES if is_3d else _SHAPE_2D_CLASSES
	# Accept either the short form ("box") or the matching Godot class name
	# ("BoxShape3D") — every other tool in the server takes class names, and
	# resource_get_info(type="Shape3D") surfaces concrete_subclasses by class.
	if not type_map.has(shape_type):
		for short_form in type_map:
			if type_map[short_form] == shape_type:
				shape_type = short_form
				break
	if not type_map.has(shape_type):
		var valid_pairs: Array[String] = []
		for short_form in type_map:
			valid_pairs.append("%s (%s)" % [short_form, type_map[short_form]])
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid shape_type '%s' for %s. Valid: %s" % [shape_type, node.get_class(), ", ".join(valid_pairs)]
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
			# get_aabb() is local-space; pre-multiply by the source's scale
			# so the collider tracks what you actually see in the viewport.
			var scale_3d: Vector3 = (source as Node3D).transform.basis.get_scale()
			aabb.position = aabb.position * scale_3d
			aabb.size = aabb.size * scale_3d
			return {"aabb": aabb}
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
