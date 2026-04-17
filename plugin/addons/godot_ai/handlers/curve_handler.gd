@tool
class_name CurveHandler
extends RefCounted

## Replaces all points on a Curve / Curve2D / Curve3D resource. The point
## list shape depends on resource type (see `set_points` for the schemas).
##
## Dedicated tool rather than a property set because Curve2D/Curve3D.add_point
## is a method call, not a property — resource_create's `properties` dict can't
## reach it.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func set_points(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")
	var new_points: Array = params.get("points", [])

	var has_node_target := not node_path.is_empty()
	var has_file_target := not resource_path.is_empty()
	if has_node_target and has_file_target:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Provide either path+property or resource_path, not both"
		)
	if not has_node_target and not has_file_target:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Must provide either path+property (node-attached curve) or resource_path (standalone .tres)"
		)
	if has_node_target and property.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: property")
	if not (new_points is Array):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "points must be an array")

	var curve: Resource
	var node: Node = null
	var curve_created := false
	if has_file_target:
		if not ResourceLoader.exists(resource_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource not found: %s" % resource_path)
		# ResourceLoader.load() returns Godot's cached Resource. Duplicate
		# before mutating so: (a) open scenes holding a reference to this
		# .tres don't silently see the new points outside any undo action,
		# and (b) if ResourceSaver.save() fails we haven't corrupted the
		# in-memory cache (cache/disk divergence). Also guard against
		# ResourceLoader.exists() succeeding but load() returning null
		# (corrupt .tres, unregistered class) — otherwise curve.get_class()
		# on the response line below would crash the plugin.
		var loaded_curve: Resource = ResourceLoader.load(resource_path)
		if loaded_curve == null:
			return McpErrorCodes.make(
				McpErrorCodes.INTERNAL_ERROR,
				"Failed to load curve from %s (file exists but load returned null — may be corrupt)" % resource_path
			)
		curve = loaded_curve.duplicate()
	else:
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")
		node = ScenePath.resolve(node_path, scene_root)
		if node == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
		if not (property in node):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"Property '%s' not found on %s" % [property, node.get_class()]
			)
		curve = node.get(property)
		# Auto-create a fresh Curve subclass if the slot is empty. Infer the
		# concrete class from the property's hint_string (e.g. Path3D.curve's
		# hint is "Curve3D"). Creation is bundled into the same undo action
		# as the point-set below, so Ctrl-Z rolls back both.
		if curve == null:
			var inferred := _infer_curve_class(node, property)
			if inferred.is_empty():
				return McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve slot on %s.%s is null and the Curve class can't be inferred from the property hint — create one first with resource_create (type=Curve3D/Curve2D/Curve)" % [node.get_class(), property]
				)
			curve = ClassDB.instantiate(inferred)
			if curve == null:
				return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % inferred)
			curve_created = true

	if not (curve is Curve or curve is Curve2D or curve is Curve3D):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Resource is %s — must be Curve, Curve2D, or Curve3D" % curve.get_class()
		)

	var coerced := _coerce_points(curve, new_points)
	if coerced.has("error"):
		return coerced.error

	var new_snapshot: Array = coerced.snapshot

	if has_file_target:
		_apply_snapshot_to_curve(curve, new_snapshot)
		var save_err := ResourceSaver.save(curve, resource_path)
		if save_err != OK:
			return McpErrorCodes.make(
				McpErrorCodes.INTERNAL_ERROR,
				"Failed to save curve to %s: %s" % [resource_path, error_string(save_err)]
			)
		# Refresh the FileSystem dock so it picks up the edit without manual
		# reimport. Sibling save-paths in this PR (_save_created_resource,
		# _save_environment, _save_texture) all do this — keep consistent.
		var efs := EditorInterface.get_resource_filesystem()
		if efs != null:
			efs.update_file(resource_path)
		return {
			"data": {
				"resource_path": resource_path,
				"curve_class": curve.get_class(),
				"point_count": new_snapshot.size(),
				"undoable": false,
				"reason": "File save is persistent; edit the .tres file manually to revert",
			}
		}

	# Inline (node-attached) path: swap the curve property so the action lands
	# cleanly in scene history, mirroring the resource-swap pattern used by
	# material_handler::assign_material. When curve_created is true the
	# "old" value is null — undo clears the slot back to empty.
	var new_curve: Resource = curve if curve_created else curve.duplicate()
	_apply_snapshot_to_curve(new_curve, new_snapshot)
	var old_curve: Resource = null if curve_created else curve

	_undo_redo.create_action("MCP: Set %d points on %s.%s" % [new_snapshot.size(), node.name, property])
	_undo_redo.add_do_property(node, property, new_curve)
	_undo_redo.add_undo_property(node, property, old_curve)
	_undo_redo.add_do_reference(new_curve)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": node_path,
			"property": property,
			"curve_class": new_curve.get_class(),
			"point_count": new_snapshot.size(),
			"curve_created": curve_created,
			"undoable": true,
		}
	}


## Infer the concrete Curve class to instantiate for a null property slot.
## Reads the property's hint_string (set by Godot on resource-typed exports)
## to get the exact accepted class name (e.g. "Curve3D" for Path3D.curve).
## Returns empty string if no viable curve class can be determined.
static func _infer_curve_class(node: Node, property: String) -> String:
	for prop in node.get_property_list():
		if prop.name != property:
			continue
		var hint_string: String = prop.get("hint_string", "")
		if hint_string.is_empty():
			return ""
		if not ClassDB.class_exists(hint_string):
			return ""
		if hint_string == "Curve" or hint_string == "Curve2D" or hint_string == "Curve3D":
			return hint_string
		# Some custom properties may list a parent class; require an exact
		# match against our three supported types to avoid surprises.
		return ""
	return ""


## Convert input `points` into a normalized snapshot of typed values for
## the given curve type. Returns {snapshot: Array} on success or
## {error: ...} on failure.
static func _coerce_points(curve: Resource, points: Array) -> Dictionary:
	var snapshot: Array = []
	if curve is Curve:
		for i in range(points.size()):
			var p = points[i]
			if not (p is Dictionary) or not p.has("offset") or not p.has("value"):
				return {"error": McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve points[%d] must be {offset, value, [left_tangent, right_tangent]}" % i
				)}
			snapshot.append({
				"offset": float(p["offset"]),
				"value": float(p["value"]),
				"left_tangent": float(p.get("left_tangent", 0.0)),
				"right_tangent": float(p.get("right_tangent", 0.0)),
			})
	elif curve is Curve2D:
		for i in range(points.size()):
			var p2 = points[i]
			if not (p2 is Dictionary) or not p2.has("position"):
				return {"error": McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve2D points[%d] must have 'position' (and optional 'in', 'out')" % i
				)}
			var pos = NodeHandler._coerce_value(p2["position"], TYPE_VECTOR2)
			var in_v = NodeHandler._coerce_value(p2.get("in", {"x": 0, "y": 0}), TYPE_VECTOR2)
			var out_v = NodeHandler._coerce_value(p2.get("out", {"x": 0, "y": 0}), TYPE_VECTOR2)
			if not (pos is Vector2 and in_v is Vector2 and out_v is Vector2):
				return {"error": McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve2D points[%d] in/position/out must coerce to Vector2" % i
				)}
			snapshot.append({"position": pos, "in": in_v, "out": out_v})
	else:  # Curve3D
		for i in range(points.size()):
			var p3 = points[i]
			if not (p3 is Dictionary) or not p3.has("position"):
				return {"error": McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve3D points[%d] must have 'position' (and optional 'in', 'out', 'tilt')" % i
				)}
			var pos3 = NodeHandler._coerce_value(p3["position"], TYPE_VECTOR3)
			var in3 = NodeHandler._coerce_value(p3.get("in", {"x": 0, "y": 0, "z": 0}), TYPE_VECTOR3)
			var out3 = NodeHandler._coerce_value(p3.get("out", {"x": 0, "y": 0, "z": 0}), TYPE_VECTOR3)
			var tilt := float(p3.get("tilt", 0.0))
			if not (pos3 is Vector3 and in3 is Vector3 and out3 is Vector3):
				return {"error": McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"Curve3D points[%d] in/position/out must coerce to Vector3" % i
				)}
			snapshot.append({"position": pos3, "in": in3, "out": out3, "tilt": tilt})
	return {"snapshot": snapshot}


static func _snapshot_curve(curve: Resource) -> Array:
	var snapshot: Array = []
	if curve is Curve:
		var c: Curve = curve
		for i in range(c.point_count):
			snapshot.append({
				"offset": c.get_point_position(i).x,
				"value": c.get_point_position(i).y,
				"left_tangent": c.get_point_left_tangent(i),
				"right_tangent": c.get_point_right_tangent(i),
			})
	elif curve is Curve2D:
		var c2: Curve2D = curve
		for i in range(c2.point_count):
			snapshot.append({
				"position": c2.get_point_position(i),
				"in": c2.get_point_in(i),
				"out": c2.get_point_out(i),
			})
	elif curve is Curve3D:
		var c3: Curve3D = curve
		for i in range(c3.point_count):
			snapshot.append({
				"position": c3.get_point_position(i),
				"in": c3.get_point_in(i),
				"out": c3.get_point_out(i),
				"tilt": c3.get_point_tilt(i),
			})
	return snapshot


func _apply_snapshot_to_curve(curve: Resource, snapshot: Array) -> void:
	curve.clear_points()
	if curve is Curve:
		for p: Dictionary in snapshot:
			curve.add_point(
				Vector2(p.offset, p.value),
				p.left_tangent,
				p.right_tangent
			)
	elif curve is Curve2D:
		for p: Dictionary in snapshot:
			curve.add_point(p.position, p["in"], p.out)
	elif curve is Curve3D:
		for i in range(snapshot.size()):
			var p: Dictionary = snapshot[i]
			curve.add_point(p.position, p["in"], p.out)
			curve.set_point_tilt(i, p.tilt)
