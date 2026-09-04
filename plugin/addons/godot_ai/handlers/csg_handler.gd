@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## CSG authoring — create CSG shapes (box, sphere, cylinder, torus, prism)
## and set their boolean operation (union / intersection / subtraction) so
## agents can carve geometry (holes, caves, tunnels) directly in the editor.
##
## All ops target nodes in the currently edited scene by scene-relative
## path. All write ops are undoable via EditorUndoRedoManager. Sibling CSG
## shapes under the same parent combine automatically; use a CSGCombiner3D
## parent when you need explicit grouping.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const SHAPES := {
	"box": "CSGBox3D",
	"sphere": "CSGSphere3D",
	"cylinder": "CSGCylinder3D",
	"torus": "CSGTorus3D",
	"polygon": "CSGPolygon3D",
}

const OPERATIONS := {
	"union": CSGShape3D.OPERATION_UNION,
	"intersection": CSGShape3D.OPERATION_INTERSECTION,
	"subtraction": CSGShape3D.OPERATION_SUBTRACTION,
}

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


## Create a CSG shape under a Node3D parent.
## params: {parent_path, name="", shape="box", operation="union"}
## Returns: {path, name, shape, operation, undoable}
func create(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var shape: String = params.get("shape", "box")
	var operation: String = params.get("operation", "union")
	var scene_file: String = params.get("scene_file", "")

	var shape_class: String = SHAPES.get(shape, "")
	if shape_class.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown shape: %s. Valid shapes: %s" % [shape, ", ".join(SHAPES.keys())])
	if not OPERATIONS.has(operation):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown operation: %s. Valid operations: %s" % [operation, ", ".join(OPERATIONS.keys())])

	var scene_check := McpScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
				McpScenePath.format_parent_error(parent_path, scene_root))
	if not parent is Node3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"CSG parent must be a Node3D (got %s)" % parent.get_class())

	var node: CSGShape3D = ClassDB.instantiate(shape_class)
	if node == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to instantiate %s" % shape_class)
	var node_name: String = params.get("name", "")
	if node_name.is_empty():
		node_name = shape_class
	node.name = node_name
	node.operation = OPERATIONS[operation]

	_undo_redo.create_action("MCP: Create %s" % node.name)
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {"data": {
		"path": McpScenePath.from_node(node, scene_root),
		"name": node.name,
		"shape": shape,
		"operation": operation,
		"undoable": true,
	}}


## Set the boolean operation of a CSG shape.
## params: {path, operation}
## Returns: {operation, undoable}
func set_operation(params: Dictionary) -> Dictionary:
	var operation: String = params.get("operation", "")
	if not OPERATIONS.has(operation):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown operation: %s. Valid operations: %s" % [operation, ", ".join(OPERATIONS.keys())])
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", ""))
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is CSGShape3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node is not a CSGShape3D: %s" % params.get("path", ""))
	var shape: CSGShape3D = node
	var prev: int = shape.operation
	var next: int = OPERATIONS[operation]
	## Target the node in both callbacks so the action lands in the scene
	## undo history (first-target routing); `set` exists on every Object.
	_undo_redo.create_action("MCP: CSG set_operation")
	_undo_redo.add_do_method(shape, "set", "operation", next)
	_undo_redo.add_undo_method(shape, "set", "operation", prev)
	_undo_redo.commit_action()
	return {"data": {"operation": operation, "undoable": true}}
