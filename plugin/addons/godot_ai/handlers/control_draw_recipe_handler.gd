@tool
class_name ControlDrawRecipeHandler
extends RefCounted

## Handles the control_draw_recipe MCP command. Attaches a shared DrawRecipe
## script to a Control and stores the caller's ordered draw ops in node
## metadata under "_ops". The DrawRecipe script dispatches each op to a
## CanvasItem draw_* call in _draw(). One Ctrl+Z reverts script + meta as a
## single undo step.

const DRAW_RECIPE_SCRIPT := preload("res://addons/godot_ai/runtime/draw_recipe.gd")

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func control_draw_recipe(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var ops_raw: Variant = params.get("ops", null)
	var clear_existing: bool = bool(params.get("clear_existing", true))

	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")
	if typeof(ops_raw) != TYPE_ARRAY:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "ops must be an Array")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % path)
	if not node is Control:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"control_draw_recipe requires a Control node, got %s" % node.get_class()
		)

	var coerced := _coerce_ops(ops_raw)
	if coerced.has("error"):
		return coerced
	var coerced_ops: Array = coerced.ops

	var old_script: Variant = node.get_script()
	var script_replaced := false
	if old_script != null and old_script != DRAW_RECIPE_SCRIPT:
		if not clear_existing:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				(
					"Node %s already has a script. Pass clear_existing=true to replace."
					% path
				)
			)
		script_replaced = true

	var had_meta := node.has_meta("_ops")
	var old_ops: Variant = node.get_meta("_ops") if had_meta else null

	_undo_redo.create_action("MCP: Draw recipe on %s" % node.name)
	_undo_redo.add_do_method(node, "set_script", DRAW_RECIPE_SCRIPT)
	_undo_redo.add_do_method(node, "set_meta", "_ops", coerced_ops)
	_undo_redo.add_do_method(node, "queue_redraw")
	_undo_redo.add_undo_method(node, "set_script", old_script)
	if had_meta:
		_undo_redo.add_undo_method(node, "set_meta", "_ops", old_ops)
	else:
		_undo_redo.add_undo_method(node, "remove_meta", "_ops")
	_undo_redo.add_undo_method(node, "queue_redraw")
	_undo_redo.commit_action()

	return {
		"data":
		{
			"path": ScenePath.from_node(node, scene_root),
			"ops_count": coerced_ops.size(),
			"script_attached": old_script == null,
			"script_replaced": script_replaced,
			"undoable": true,
		}
	}


## Populate a freshly-instantiated Control with the draw recipe in memory
## (no undo action). Used by PR2's pattern_corner_brackets, which wraps the
## node-add + set_script/set_meta in its own create_action.
static func attach_recipe_to(node: Control, coerced_ops: Array) -> void:
	node.set_script(DRAW_RECIPE_SCRIPT)
	node.set_meta("_ops", coerced_ops)


## Validate and coerce every op dict. Returns {"ops": Array} or an error dict.
func _coerce_ops(ops: Array) -> Dictionary:
	var result: Array = []
	for i in ops.size():
		var op: Variant = ops[i]
		if typeof(op) != TYPE_DICTIONARY:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS, "ops[%d] must be a dictionary" % i
			)
		var coerced := _coerce_single_op(op, i)
		if coerced.has("error"):
			return coerced
		result.append(coerced.op)
	return {"ops": result}


func _coerce_single_op(op: Dictionary, idx: int) -> Dictionary:
	var draw_type: String = op.get("draw", "")
	if draw_type.is_empty():
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d]: missing 'draw' field" % idx
		)
	match draw_type:
		"line":
			return _coerce_line(op, idx)
		"rect":
			return _coerce_rect(op, idx)
		"arc":
			return _coerce_arc(op, idx)
		"circle":
			return _coerce_circle(op, idx)
		"polyline":
			return _coerce_polyline_or_polygon(op, idx, "polyline")
		"polygon":
			return _coerce_polyline_or_polygon(op, idx, "polygon")
		"string":
			return _coerce_string(op, idx)
	return McpErrorCodes.make(
		McpErrorCodes.INVALID_PARAMS,
		"ops[%d]: unknown draw type '%s'" % [idx, draw_type]
	)


func _require_fields(op: Dictionary, idx: int, kind: String, fields: Array) -> Dictionary:
	for f in fields:
		if not op.has(f):
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"ops[%d] (%s): missing '%s'" % [idx, kind, f]
			)
	return {}


func _coerce_line(op: Dictionary, idx: int) -> Dictionary:
	var missing := _require_fields(op, idx, "line", ["from", "to", "color"])
	if missing.has("error"):
		return missing
	var frm := UiHandler._coerce_for_type(op.from, TYPE_VECTOR2)
	if not frm.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (line): invalid 'from'" % idx
		)
	var to_ := UiHandler._coerce_for_type(op.to, TYPE_VECTOR2)
	if not to_.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (line): invalid 'to'" % idx
		)
	var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
	if not c.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (line): invalid 'color'" % idx
		)
	var out := {"draw": "line", "from": frm.value, "to": to_.value, "color": c.value}
	if op.has("width"):
		out["width"] = float(op.width)
	if op.has("antialiased"):
		out["antialiased"] = bool(op.antialiased)
	return {"op": out}


func _coerce_rect(op: Dictionary, idx: int) -> Dictionary:
	var missing := _require_fields(op, idx, "rect", ["rect", "color"])
	if missing.has("error"):
		return missing
	var r := UiHandler._coerce_for_type(op.rect, TYPE_RECT2)
	if not r.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (rect): invalid 'rect'" % idx
		)
	var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
	if not c.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (rect): invalid 'color'" % idx
		)
	var out := {"draw": "rect", "rect": r.value, "color": c.value}
	if op.has("filled"):
		out["filled"] = bool(op.filled)
	if op.has("width"):
		out["width"] = float(op.width)
	return {"op": out}


func _coerce_arc(op: Dictionary, idx: int) -> Dictionary:
	var missing := _require_fields(
		op, idx, "arc", ["center", "radius", "start_angle", "end_angle", "color"]
	)
	if missing.has("error"):
		return missing
	var center := UiHandler._coerce_for_type(op.center, TYPE_VECTOR2)
	if not center.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (arc): invalid 'center'" % idx
		)
	var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
	if not c.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (arc): invalid 'color'" % idx
		)
	var out := {
		"draw": "arc",
		"center": center.value,
		"radius": float(op.radius),
		"start_angle": float(op.start_angle),
		"end_angle": float(op.end_angle),
		"color": c.value,
	}
	if op.has("point_count"):
		out["point_count"] = int(op.point_count)
	if op.has("width"):
		out["width"] = float(op.width)
	if op.has("antialiased"):
		out["antialiased"] = bool(op.antialiased)
	return {"op": out}


func _coerce_circle(op: Dictionary, idx: int) -> Dictionary:
	var missing := _require_fields(op, idx, "circle", ["center", "radius", "color"])
	if missing.has("error"):
		return missing
	var center := UiHandler._coerce_for_type(op.center, TYPE_VECTOR2)
	if not center.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (circle): invalid 'center'" % idx
		)
	var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
	if not c.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (circle): invalid 'color'" % idx
		)
	return {
		"op":
		{
			"draw": "circle",
			"center": center.value,
			"radius": float(op.radius),
			"color": c.value,
		}
	}


func _coerce_polyline_or_polygon(op: Dictionary, idx: int, kind: String) -> Dictionary:
	if not op.has("points"):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (%s): missing 'points'" % [idx, kind]
		)
	if typeof(op.points) != TYPE_ARRAY:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"ops[%d] (%s): 'points' must be an Array" % [idx, kind]
		)
	var points := PackedVector2Array()
	for j in op.points.size():
		var p := UiHandler._coerce_for_type(op.points[j], TYPE_VECTOR2)
		if not p.ok:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"ops[%d] (%s): points[%d] invalid" % [idx, kind, j]
			)
		points.append(p.value)

	var out := {"draw": kind, "points": points}

	if op.has("colors"):
		if typeof(op.colors) != TYPE_ARRAY:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS,
				"ops[%d] (%s): 'colors' must be an Array" % [idx, kind]
			)
		var colors := PackedColorArray()
		for k in op.colors.size():
			var ck := UiHandler._coerce_for_type(op.colors[k], TYPE_COLOR)
			if not ck.ok:
				return McpErrorCodes.make(
					McpErrorCodes.INVALID_PARAMS,
					"ops[%d] (%s): colors[%d] invalid" % [idx, kind, k]
				)
			colors.append(ck.value)
		out["colors"] = colors
	elif op.has("color"):
		var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
		if not c.ok:
			return McpErrorCodes.make(
				McpErrorCodes.INVALID_PARAMS, "ops[%d] (%s): invalid 'color'" % [idx, kind]
			)
		out["color"] = c.value
	else:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"ops[%d] (%s): missing 'color' or 'colors'" % [idx, kind]
		)

	if op.has("width"):
		out["width"] = float(op.width)
	if op.has("antialiased"):
		out["antialiased"] = bool(op.antialiased)
	return {"op": out}


func _coerce_string(op: Dictionary, idx: int) -> Dictionary:
	var missing := _require_fields(op, idx, "string", ["position", "text", "color"])
	if missing.has("error"):
		return missing
	var pos := UiHandler._coerce_for_type(op.position, TYPE_VECTOR2)
	if not pos.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (string): invalid 'position'" % idx
		)
	var c := UiHandler._coerce_for_type(op.color, TYPE_COLOR)
	if not c.ok:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS, "ops[%d] (string): invalid 'color'" % idx
		)
	var out := {
		"draw": "string",
		"position": pos.value,
		"text": str(op.text),
		"color": c.value,
	}
	if op.has("font_size"):
		out["font_size"] = int(op.font_size)
	if op.has("align"):
		out["align"] = int(op.align)
	if op.has("max_width"):
		out["max_width"] = float(op.max_width)
	return {"op": out}
