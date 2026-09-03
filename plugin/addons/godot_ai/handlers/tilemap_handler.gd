@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## TileMap / TileMapLayer authoring — set, fill, clear, and read tile cells
## directly in the editor scene with full undo/redo support.
##
## All ops target TileMapLayer nodes in the currently edited scene by
## scene-relative path (e.g. "/LavaLake20x20/Ground").

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_RECT_FILL_CELLS := 4096

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


## Set a single tile cell.
## params: {path, source_id, atlas_col, atlas_row, map_x, map_y}
## Returns: {map_x, map_y, source_id, atlas_col, atlas_row}
func set_cell(params: Dictionary) -> Dictionary:
	var layer := _resolve_layer(params)
	if layer.has("error"): return layer
	var node: TileMapLayer = layer.node
	var pos   := Vector2i(params.get("map_x", 0), params.get("map_y", 0))
	var src   := int(params.get("source_id", 0))
	var atlas := Vector2i(params.get("atlas_col", 0), params.get("atlas_row", 0))
	var prev := _capture_cell_state(node, pos)
	_undo_redo.create_action("MCP: TileMap set_cell")
	_undo_redo.add_do_method(node, "set_cell", pos, src, atlas)
	_undo_redo.add_undo_method(self, "_restore_cell_state", node, pos, prev)
	_undo_redo.commit_action()
	return {"data": {"map_x": pos.x, "map_y": pos.y, "source_id": src,
		"atlas_col": atlas.x, "atlas_row": atlas.y, "undoable": true}}


## Fill a rectangular region with one tile type in a single undo action.
## params: {path, source_id, atlas_col, atlas_row, rect_x, rect_y, rect_w, rect_h}
## Returns: {cells_filled, rect: {x, y, w, h}}
func set_cells_rect(params: Dictionary) -> Dictionary:
	var layer := _resolve_layer(params)
	if layer.has("error"): return layer
	var node: TileMapLayer = layer.node
	var src   := int(params.get("source_id", 0))
	var atlas := Vector2i(params.get("atlas_col", 0), params.get("atlas_row", 0))
	var rx    := int(params.get("rect_x", 0));  var ry := int(params.get("rect_y", 0))
	var rw    := int(params.get("rect_w", 1));  var rh := int(params.get("rect_h", 1))
	if rw <= 0 or rh <= 0:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"rect_w and rect_h must be > 0 (got %d x %d)" % [rw, rh]
		)
	var cell_count := rw * rh
	if cell_count > MAX_RECT_FILL_CELLS:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Rect too large: %d cells exceeds max %d" % [cell_count, MAX_RECT_FILL_CELLS]
		)
	var cells: Array[Vector2i] = []
	var snapshot: Array[Dictionary] = []
	for x in range(rx, rx + rw):
		for y in range(ry, ry + rh):
			var pos := Vector2i(x, y)
			cells.append(pos)
			snapshot.append({"pos": pos, "state": _capture_cell_state(node, pos)})
	_undo_redo.create_action("MCP: TileMap set_cells_rect %dx%d" % [rw, rh])
	for pos in cells:
		_undo_redo.add_do_method(node, "set_cell", pos, src, atlas)
	_undo_redo.add_undo_method(self, "_restore_rect_snapshot", node, snapshot)
	_undo_redo.commit_action()
	return {"data": {"cells_filled": cells.size(),
		"rect": {"x": rx, "y": ry, "w": rw, "h": rh}, "undoable": true}}


## Remove all tiles from a TileMapLayer.
## params: {path}
## Returns: {cleared: true}
func clear_layer(params: Dictionary) -> Dictionary:
	var layer := _resolve_layer(params)
	if layer.has("error"): return layer
	var node: TileMapLayer = layer.node
	var snapshot := _capture_used_cells_snapshot(node)
	_undo_redo.create_action("MCP: TileMap clear")
	_undo_redo.add_do_method(node, "clear")
	_undo_redo.add_undo_method(self, "_restore_cells_snapshot", node, snapshot)
	_undo_redo.commit_action()
	return {"data": {"cleared": true, "undoable": true}}


## Return all used cell coordinates.
## params: {path}
## Returns: {cells: [{x, y}, ...], count: int}
func get_used_cells(params: Dictionary) -> Dictionary:
	var layer := _resolve_layer(params)
	if layer.has("error"): return layer
	var node: TileMapLayer = layer.node
	var cells := node.get_used_cells()
	var result: Array = []
	for c in cells:
		result.append({"x": c.x, "y": c.y})
	return {"data": {"cells": result, "count": result.size()}}


## Resolve a TileMapLayer node from params["path"] in the currently edited
## scene. Returns {"node": TileMapLayer} on success, or an error dict.
func _resolve_layer(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var scene_file: String = params.get("scene_file", "")
	var resolved := McpNodeValidator.resolve_or_error(path, "path", scene_file)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is TileMapLayer:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node is not a TileMapLayer: %s" % path)
	return {"node": node}


func _capture_cell_state(node: TileMapLayer, pos: Vector2i) -> Dictionary:
	var source_id := node.get_cell_source_id(pos)
	if source_id == -1:
		return {"has_tile": false}
	var atlas: Vector2i = node.get_cell_atlas_coords(pos)
	var alternative := node.get_cell_alternative_tile(pos)
	return {
		"has_tile": true,
		"source_id": source_id,
		"atlas_col": atlas.x,
		"atlas_row": atlas.y,
		"alternative": alternative,
	}


func _capture_used_cells_snapshot(node: TileMapLayer) -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = []
	for pos in node.get_used_cells():
		snapshot.append({"pos": pos, "state": _capture_cell_state(node, pos)})
	return snapshot


func _restore_cells_snapshot(node: TileMapLayer, snapshot: Array[Dictionary]) -> void:
	node.clear()
	for entry in snapshot:
		_restore_cell_state(node, entry.pos, entry.state)


func _restore_rect_snapshot(node: TileMapLayer, snapshot: Array[Dictionary]) -> void:
	for entry in snapshot:
		_restore_cell_state(node, entry.pos, entry.state)


func _restore_cell_state(node: TileMapLayer, pos: Vector2i, state: Dictionary) -> void:
	if not state.get("has_tile", false):
		node.erase_cell(pos)
		return
	node.set_cell(
		pos,
		int(state.get("source_id", -1)),
		Vector2i(int(state.get("atlas_col", -1)), int(state.get("atlas_row", -1))),
		int(state.get("alternative", 0))
	)
