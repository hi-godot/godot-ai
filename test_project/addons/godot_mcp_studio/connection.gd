@tool
class_name Connection
extends Node

## WebSocket connection to the Godot MCP Studio Python server.

const DEFAULT_URL := "ws://127.0.0.1:9500"
const RECONNECT_DELAYS: Array[float] = [1.0, 2.0, 4.0, 8.0, 10.0]
const LOG_BUFFER_MAX := 500

# Error code constants (mirror protocol/errors.py)
const ERR_INVALID_PARAMS := "INVALID_PARAMS"
const ERR_EDITOR_NOT_READY := "EDITOR_NOT_READY"
const ERR_UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const ERR_INTERNAL_ERROR := "INTERNAL_ERROR"

var _peer := WebSocketPeer.new()
var _url := DEFAULT_URL
var _connected := false
var _reconnect_attempt := 0
var _reconnect_timer := 0.0
var _session_id := ""
var _command_queue: Array[Dictionary] = []
var _log_buffer: Array[String] = []

## Toggle MCP command logging in the Godot console.
var mcp_logging := true


func _ready() -> void:
	_session_id = _generate_session_id()
	_connect_to_server()


func _process(delta: float) -> void:
	_peer.poll()

	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_attempt = 0
				_log("connected to server")
				_send_handshake()

			while _peer.get_available_packet_count() > 0:
				var raw := _peer.get_packet().get_string_from_utf8()
				_handle_message(raw)

			# Dispatch queued commands (frame budget: 4ms)
			var budget_ms := 4.0
			var start := Time.get_ticks_msec()
			var idx := 0
			while idx < _command_queue.size() and (Time.get_ticks_msec() - start) < budget_ms:
				_dispatch_command(_command_queue[idx])
				idx += 1
			if idx > 0:
				_command_queue = _command_queue.slice(idx)

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				var code := _peer.get_close_code()
				_log("disconnected (code %d)" % code)
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_attempt_reconnect()

		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CONNECTING:
			pass


func disconnect_from_server() -> void:
	if _connected:
		_peer.close(1000, "Plugin unloading")
		_connected = false


func _connect_to_server() -> void:
	var err := _peer.connect_to_url(_url)
	if err != OK:
		_log("failed to initiate connection (error %d)" % err)


func _attempt_reconnect() -> void:
	var delay_idx := mini(_reconnect_attempt, RECONNECT_DELAYS.size() - 1)
	var delay := RECONNECT_DELAYS[delay_idx]
	_reconnect_attempt += 1
	_reconnect_timer = delay
	_log("reconnecting in %.0fs (attempt %d)" % [delay, _reconnect_attempt])
	_peer = WebSocketPeer.new()
	_connect_to_server()


func _send_handshake() -> void:
	_send_json({
		"type": "handshake",
		"session_id": _session_id,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"project_path": ProjectSettings.globalize_path("res://"),
		"plugin_version": "0.0.1",
		"protocol_version": 1,
	})


func _handle_message(raw: String) -> void:
	var parsed = JSON.parse_string(raw)
	if parsed == null:
		push_warning("Godot MCP Studio: failed to parse message: %s" % raw)
		return
	if parsed is Dictionary and parsed.has("request_id") and parsed.has("command"):
		_command_queue.append(parsed)


func _dispatch_command(cmd: Dictionary) -> void:
	var request_id: String = cmd.get("request_id", "")
	var command: String = cmd.get("command", "")
	var params: Dictionary = cmd.get("params", {})

	if mcp_logging:
		_log("[recv] %s(%s)" % [command, JSON.stringify(params)])

	var result: Dictionary

	match command:
		"get_editor_state":
			result = _handle_get_editor_state(params)
		"get_scene_tree":
			result = _handle_get_scene_tree(params)
		"get_selection":
			result = _handle_get_selection(params)
		"create_node":
			result = _handle_create_node(params)
		"get_logs":
			result = _handle_get_logs(params)
		"configure_client":
			result = _handle_configure_client(params)
		"check_client_status":
			result = _handle_check_client_status(params)
		_:
			result = _error(ERR_UNKNOWN_COMMAND, "Unknown command: %s" % command)

	result["request_id"] = request_id
	if not result.has("status"):
		result["status"] = "ok"

	if mcp_logging:
		var status: String = result.get("status", "ok")
		if status == "ok":
			_log("[send] %s -> ok" % command)
		else:
			var err_msg: String = result.get("error", {}).get("message", "unknown")
			_log("[send] %s -> error: %s" % [command, err_msg])

	_send_json(result)


# --- Path helpers ---

## Return a clean path relative to the scene root (e.g. /Main/Camera3D).
func _scene_path(node: Node, scene_root: Node) -> String:
	if scene_root == null or node == null:
		return ""
	if node == scene_root:
		return "/" + scene_root.name
	var relative := scene_root.get_path_to(node)
	return "/" + scene_root.name + "/" + str(relative)


## Resolve a clean scene path like "/Main/Camera3D" to the actual node.
func _resolve_scene_node(scene_path: String) -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null

	var root_prefix := "/" + scene_root.name
	if scene_path == root_prefix:
		return scene_root
	if scene_path.begins_with(root_prefix + "/"):
		var relative := scene_path.substr(root_prefix.length() + 1)
		return scene_root.get_node_or_null(relative)

	# Try as-is (relative path)
	return scene_root.get_node_or_null(scene_path)


# --- Command handlers ---

func _handle_get_editor_state(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	return {
		"data": {
			"godot_version": Engine.get_version_info().get("string", "unknown"),
			"project_name": ProjectSettings.get_setting("application/config/name", ""),
			"current_scene": scene_root.scene_file_path if scene_root else "",
			"is_playing": EditorInterface.is_playing_scene(),
		}
	}


func _handle_get_scene_tree(params: Dictionary) -> Dictionary:
	var max_depth: int = params.get("depth", 10)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {"data": {"nodes": [], "message": "No scene open"}}

	var nodes: Array[Dictionary] = []
	_walk_tree(scene_root, nodes, 0, max_depth, scene_root)
	return {"data": {"nodes": nodes, "total_count": nodes.size()}}


func _walk_tree(node: Node, out: Array[Dictionary], depth: int, max_depth: int, scene_root: Node) -> void:
	if depth > max_depth:
		return
	out.append({
		"name": node.name,
		"type": node.get_class(),
		"path": _scene_path(node, scene_root),
		"children_count": node.get_child_count(),
	})
	for child in node.get_children():
		_walk_tree(child, out, depth + 1, max_depth, scene_root)


func _handle_get_selection(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		paths.append(_scene_path(node, scene_root))
	return {"data": {"selected_paths": paths, "count": paths.size()}}


func _handle_create_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", "")

	if node_type.is_empty():
		return _error(ERR_INVALID_PARAMS, "Missing required param: type")

	if not ClassDB.class_exists(node_type):
		return _error(ERR_INVALID_PARAMS, "Unknown node type: %s" % node_type)
	if not ClassDB.is_parent_class(node_type, "Node"):
		return _error(ERR_INVALID_PARAMS, "%s is not a Node type" % node_type)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return _error(ERR_EDITOR_NOT_READY, "No scene open")

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = _resolve_scene_node(parent_path)
		if parent == null:
			return _error(ERR_INVALID_PARAMS, "Parent not found: %s" % parent_path)

	var new_node: Node = ClassDB.instantiate(node_type)
	if new_node == null:
		return _error(ERR_INTERNAL_ERROR, "Failed to instantiate %s" % node_type)

	if not node_name.is_empty():
		new_node.name = node_name

	parent.add_child(new_node, true)
	new_node.owner = scene_root

	return {
		"data": {
			"name": new_node.name,
			"type": new_node.get_class(),
			"path": _scene_path(new_node, scene_root),
			"parent_path": _scene_path(parent, scene_root),
		}
	}


func _handle_configure_client(params: Dictionary) -> Dictionary:
	var client_name: String = params.get("client", "")
	var client_type: int = McpClientConfigurator.client_type_from_string(client_name)
	if client_type < 0:
		var valid_names := ", ".join(McpClientConfigurator.CLIENT_TYPE_MAP.keys())
		return _error(ERR_INVALID_PARAMS, "Unknown client: %s. Use: %s" % [client_name, valid_names])
	var result := McpClientConfigurator.configure(client_type as McpClientConfigurator.ClientType)
	if result.get("status") == "error":
		return _error(ERR_INTERNAL_ERROR, result.get("message", "Configuration failed"))
	return {"data": result}


func _handle_check_client_status(_params: Dictionary) -> Dictionary:
	var results := {}
	for client_name in McpClientConfigurator.CLIENT_TYPE_MAP:
		var client_type: McpClientConfigurator.ClientType = McpClientConfigurator.CLIENT_TYPE_MAP[client_name]
		var status := McpClientConfigurator.check_status(client_type)
		match status:
			McpClientConfigurator.ConfigStatus.CONFIGURED:
				results[client_name] = "configured"
			McpClientConfigurator.ConfigStatus.NOT_CONFIGURED:
				results[client_name] = "not_configured"
			_:
				results[client_name] = "error"
	return {"data": {"clients": results}}


func _handle_get_logs(params: Dictionary) -> Dictionary:
	var count: int = params.get("count", 50)
	var start := maxi(0, _log_buffer.size() - count)
	var lines: Array[String] = []
	lines.assign(_log_buffer.slice(start))
	return {
		"data": {
			"lines": lines,
			"total_count": _log_buffer.size(),
			"returned_count": lines.size(),
		}
	}


# --- Helpers ---

func _error(code: String, message: String) -> Dictionary:
	return {"status": "error", "error": {"code": code, "message": message}}


func _log(msg: String) -> void:
	var line := "MCP | %s" % msg
	print(line)
	_log_buffer.append(line)
	if _log_buffer.size() > LOG_BUFFER_MAX:
		_log_buffer = _log_buffer.slice(-LOG_BUFFER_MAX)


func _send_json(data: Dictionary) -> void:
	if _connected:
		_peer.send_text(JSON.stringify(data))


func _generate_session_id() -> String:
	var bytes := PackedByteArray()
	for i in 16:
		bytes.append(randi() % 256)
	return bytes.hex_encode()
