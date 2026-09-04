@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## GridMap authoring — set, fill, clear, and read 3D cells plus mesh-library
## items directly in the editor scene with full undo/redo support.
##
## All ops target GridMap nodes in the currently edited scene by
## scene-relative path (e.g. "/Main/Terrain"). All write ops are undoable
## via EditorUndoRedoManager.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_FILL_CELLS := 4096

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


## Set a single cell item. item = -1 erases the cell.
## params: {path, item, map_x, map_y, map_z, orientation=0}
## Returns: {map_x, map_y, map_z, item, orientation, undoable}
func set_item(params: Dictionary) -> Dictionary:
	var gm := _resolve_gridmap(params)
	if gm.has("error"): return gm
	var node: GridMap = gm.node
	var pos := Vector3i(int(params.get("map_x", 0)), int(params.get("map_y", 0)), int(params.get("map_z", 0)))
	var item := int(params.get("item", 0))
	var orientation := int(params.get("orientation", 0))
	if orientation < 0 or orientation > 24:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"orientation must be in 0..24 (GridMap baked rotations), got %d" % orientation)
	var prev := _capture_cell_state(node, pos)
	_undo_redo.create_action("MCP: GridMap set_item")
	_undo_redo.add_do_method(node, "set_cell_item", pos, item, orientation)
	_undo_redo.add_undo_method(self, "_restore_cell_state", node, pos, prev)
	_undo_redo.commit_action()
	return {"data": {"map_x": pos.x, "map_y": pos.y, "map_z": pos.z,
		"item": item, "orientation": orientation, "undoable": true}}


## Fill a box region with one item in a single undo action.
## params: {path, item, rect_x, rect_y, rect_z, rect_w, rect_h, rect_d, orientation=0}
## Returns: {cells_filled, rect: {x, y, z, w, h, d}}
func fill(params: Dictionary) -> Dictionary:
	var gm := _resolve_gridmap(params)
	if gm.has("error"): return gm
	var node: GridMap = gm.node
	var item := int(params.get("item", 0))
	var orientation := int(params.get("orientation", 0))
	if orientation < 0 or orientation > 24:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"orientation must be in 0..24 (GridMap baked rotations), got %d" % orientation)
	var rx := int(params.get("rect_x", 0)); var ry := int(params.get("rect_y", 0)); var rz := int(params.get("rect_z", 0))
	var rw := int(params.get("rect_w", 1)); var rh := int(params.get("rect_h", 1)); var rd := int(params.get("rect_d", 1))
	if rw <= 0 or rh <= 0 or rd <= 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"rect_w, rect_h and rect_d must be > 0 (got %d x %d x %d)" % [rw, rh, rd])
	var cell_count := rw * rh * rd
	if cell_count > MAX_FILL_CELLS:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Region too large: %d cells exceeds max %d" % [cell_count, MAX_FILL_CELLS])
	var snapshot: Array[Dictionary] = []
	for x in range(rx, rx + rw):
		for y in range(ry, ry + rh):
			for z in range(rz, rz + rd):
				var pos := Vector3i(x, y, z)
				snapshot.append({"pos": pos, "state": _capture_cell_state(node, pos)})
	_undo_redo.create_action("MCP: GridMap fill %dx%dx%d" % [rw, rh, rd])
	## First callback targets the node so the action lands in the scene undo
	## history (first-target routing); _apply_fill batches the rest of the
	## region into a single history entry instead of one per cell.
	_undo_redo.add_do_method(node, "set_cell_item", snapshot[0].pos, item, orientation)
	_undo_redo.add_do_method(self, "_apply_fill", node, snapshot, item, orientation)
	_undo_redo.add_undo_method(self, "_restore_rect_snapshot", node, snapshot)
	_undo_redo.commit_action()
	return {"data": {"cells_filled": snapshot.size(),
		"rect": {"x": rx, "y": ry, "z": rz, "w": rw, "h": rh, "d": rd}, "undoable": true}}


## Remove all cells from the GridMap.
## params: {path}
## Returns: {cleared: true}
func clear_layer(params: Dictionary) -> Dictionary:
	var gm := _resolve_gridmap(params)
	if gm.has("error"): return gm
	var node: GridMap = gm.node
	var used := node.get_used_cells()
	if used.size() > MAX_FILL_CELLS:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"GridMap has %d cells, exceeds max %d for undoable clear"
			% [used.size(), MAX_FILL_CELLS])
	var snapshot := _capture_used_cells_snapshot(node)
	_undo_redo.create_action("MCP: GridMap clear")
	_undo_redo.add_do_method(node, "clear")
	_undo_redo.add_undo_method(self, "_restore_cells_snapshot", node, snapshot)
	_undo_redo.commit_action()
	return {"data": {"cleared": true, "undoable": true}}


## Return all used cell coordinates.
## params: {path}
## Returns: {cells: [{x, y, z}, ...], count: int}
func get_used_cells(params: Dictionary) -> Dictionary:
	var gm := _resolve_gridmap(params)
	if gm.has("error"): return gm
	var node: GridMap = gm.node
	var result: Array = []
	for c in node.get_used_cells():
		result.append({"x": c.x, "y": c.y, "z": c.z})
	return {"data": {"cells": result, "count": result.size()}}


## List the items available in the GridMap's MeshLibrary, so agents can
## discover item ids and names before placing cells (the 3D analogue of
## tileset atlas inspection).
## params: {path}
## Returns: {library: res:// path or "", items: [{item, name, mesh}...], count}
func list_library_items(params: Dictionary) -> Dictionary:
	var gm := _resolve_gridmap(params)
	if gm.has("error"): return gm
	var node: GridMap = gm.node
	var library: MeshLibrary = node.mesh_library
	if library == null:
		return {"data": {"library": "", "items": [], "count": 0}}
	var items: Array = []
	var ids := library.get_item_list()
	ids.sort()
	for item in ids:
		var mesh: Mesh = library.get_item_mesh(item)
		var mesh_path := mesh.resource_path if mesh != null else ""
		items.append({
			"item": item,
			"name": library.get_item_name(item),
			"mesh": mesh_path,
		})
	return {"data": {"library": library.resource_path, "items": items, "count": items.size()}}


## Resolve a GridMap node from params["path"] in the currently edited
## scene. Returns {"node": GridMap} on success, or an error dict.
func _resolve_gridmap(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var scene_file: String = params.get("scene_file", "")
	var resolved := McpNodeValidator.resolve_or_error(path, "path", scene_file)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is GridMap:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node is not a GridMap: %s" % path)
	return {"node": node}


func _capture_cell_state(node: GridMap, pos: Vector3i) -> Dictionary:
	var item := node.get_cell_item(pos)
	if item == -1:
		return {"has_item": false}
	return {"has_item": true, "item": item, "orientation": node.get_cell_item_orientation(pos)}


func _capture_used_cells_snapshot(node: GridMap) -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = []
	for pos in node.get_used_cells():
		snapshot.append({"pos": pos, "state": _capture_cell_state(node, pos)})
	return snapshot


func _restore_cells_snapshot(node: GridMap, snapshot: Array[Dictionary]) -> void:
	node.clear()
	for entry in snapshot:
		_restore_cell_state(node, entry.pos, entry.state)


## Batched do-method for fill: one undo-history entry applies the whole
## region instead of one entry per cell.
func _apply_fill(node: GridMap, snapshot: Array[Dictionary], item: int, orientation: int) -> void:
	for entry in snapshot:
		node.set_cell_item(entry.pos, item, orientation)


func _restore_rect_snapshot(node: GridMap, snapshot: Array[Dictionary]) -> void:
	for entry in snapshot:
		_restore_cell_state(node, entry.pos, entry.state)


func _restore_cell_state(node: GridMap, pos: Vector3i, state: Dictionary) -> void:
	if not state.get("has_item", false):
		node.set_cell_item(pos, -1)
		return
	node.set_cell_item(pos, int(state.get("item", 0)), int(state.get("orientation", 0)))
