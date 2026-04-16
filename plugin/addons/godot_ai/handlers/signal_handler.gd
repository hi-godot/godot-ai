@tool
class_name SignalHandler
extends RefCounted

## Handles signal listing, connecting, and disconnecting on scene nodes.

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


func list_signals(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: path")

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % path)

	var signals: Array[Dictionary] = []
	for sig in node.get_signal_list():
		var args: Array[Dictionary] = []
		for arg in sig.get("args", []):
			args.append({"name": arg.get("name", ""), "type": type_string(arg.get("type", 0))})
		signals.append({
			"name": sig.get("name", ""),
			"args": args,
		})

	var connections: Array[Dictionary] = []
	for sig in signals:
		for conn in node.get_signal_connection_list(sig.name):
			var callable: Callable = conn.get("callable", Callable())
			var target := callable.get_object()
			if target == null:
				continue  # skip connections to freed objects
			connections.append({
				"signal": sig.name,
				"target": ScenePath.from_node(target, scene_root) if target is Node else str(target),
				"method": callable.get_method(),
			})

	return {
		"data": {
			"path": ScenePath.from_node(node, scene_root),
			"signals": signals,
			"signal_count": signals.size(),
			"connections": connections,
			"connection_count": connections.size(),
		}
	}


func connect_signal(params: Dictionary) -> Dictionary:
	var resolved := _resolve_signal_params(params)
	if resolved.has("error"):
		return resolved

	var source: Node = resolved.source
	var target: Node = resolved.target
	var signal_name: String = resolved.signal_name
	var method: String = resolved.method
	var scene_root: Node = resolved.scene_root

	if not source.has_signal(signal_name):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Signal '%s' not found on %s" % [signal_name, params.path])

	if not target.has_method(method):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Method '%s' not found on %s" % [method, params.target])

	var callable := Callable(target, method)
	if source.is_connected(signal_name, callable):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Signal '%s' already connected to %s.%s" % [signal_name, params.target, method])

	_undo_redo.create_action("MCP: Connect signal %s" % signal_name)
	_undo_redo.add_do_method(source, "connect", signal_name, callable)
	_undo_redo.add_undo_method(source, "disconnect", signal_name, callable)
	_undo_redo.commit_action()

	return {"data": _signal_response(source, signal_name, target, method, scene_root)}


func disconnect_signal(params: Dictionary) -> Dictionary:
	var resolved := _resolve_signal_params(params)
	if resolved.has("error"):
		return resolved

	var source: Node = resolved.source
	var target: Node = resolved.target
	var signal_name: String = resolved.signal_name
	var method: String = resolved.method
	var scene_root: Node = resolved.scene_root

	var callable := Callable(target, method)
	if not source.is_connected(signal_name, callable):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Signal '%s' is not connected to %s.%s" % [signal_name, params.target, method])

	_undo_redo.create_action("MCP: Disconnect signal %s" % signal_name)
	_undo_redo.add_do_method(source, "disconnect", signal_name, callable)
	_undo_redo.add_undo_method(source, "connect", signal_name, callable)
	_undo_redo.commit_action()

	return {"data": _signal_response(source, signal_name, target, method, scene_root)}


func _resolve_signal_params(params: Dictionary) -> Dictionary:
	for key in ["path", "signal", "target", "method"]:
		if params.get(key, "").is_empty():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: %s" % key)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var source_result := _resolve_node_or_autoload(params.path, scene_root, "Source")
	if source_result.has("error"):
		return source_result
	var source: Node = source_result.node

	var target_result := _resolve_node_or_autoload(params.target, scene_root, "Target")
	if target_result.has("error"):
		return target_result
	var target: Node = target_result.node

	return {
		"source": source,
		"target": target,
		"signal_name": params.signal,
		"method": params.method,
		"scene_root": scene_root,
	}


## Resolve a path to a Node, with three distinct outcomes:
##   1. Found in the edited scene tree → returns {node}
##   2. Declared as an autoload AND instantiated at edit time → returns {node}
##   3. Declared as an autoload but NOT instantiated at edit time → returns
##      INVALID_PARAMS with guidance. Most autoloads are runtime-only, so a
##      silent "not found" hides the real reason the connection can't be made.
##   4. Not in scene and not a declared autoload → returns INVALID_PARAMS.
func _resolve_node_or_autoload(path: String, scene_root: Node, role: String) -> Dictionary:
	var node := ScenePath.resolve(path, scene_root)
	if node != null:
		return {"node": node}

	var name := path.trim_prefix("/")
	if ProjectSettings.has_setting("autoload/" + name):
		# Autoload is declared — see if the editor has it instanced.
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			var live := (tree as SceneTree).root.get_node_or_null(name)
			if live != null:
				return {"node": live}
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"%s '%s' is a declared autoload but isn't instantiated in the editor. " % [role, name] +
			"Most autoloads are runtime-only; edit-time signal connection isn't supported for them. " +
			"Connect it from a script attached to the scene using @onready + connect(), " +
			"or enable editor-instancing for this autoload in Project Settings > Autoload.")

	return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
		"%s node not found: %s (not in scene tree or autoloads)" % [role, path])


func _signal_response(source: Node, signal_name: String, target: Node, method: String, scene_root: Node) -> Dictionary:
	return {
		"source": ScenePath.from_node(source, scene_root),
		"signal": signal_name,
		"target": ScenePath.from_node(target, scene_root),
		"method": method,
		"undoable": true,
	}
