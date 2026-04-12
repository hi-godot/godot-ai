@tool
class_name Connection
extends Node

## WebSocket connection to the Godot MCP Studio Python server.

const DEFAULT_URL := "ws://127.0.0.1:9500"
const RECONNECT_DELAYS := [1.0, 2.0, 4.0, 8.0, 10.0]

var _peer := WebSocketPeer.new()
var _url := DEFAULT_URL
var _connected := false
var _reconnect_attempt := 0
var _reconnect_timer := 0.0
var _session_id := ""
var _command_queue: Array[Dictionary] = []


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
				print("Godot MCP Studio: connected to server")
				_send_handshake()

			# Receive messages
			while _peer.get_available_packet_count() > 0:
				var raw := _peer.get_packet().get_string_from_utf8()
				_handle_message(raw)

			# Dispatch queued commands (frame budget: 4ms)
			var budget_ms := 4.0
			var start := Time.get_ticks_msec()
			while _command_queue.size() > 0 and (Time.get_ticks_msec() - start) < budget_ms:
				var cmd: Dictionary = _command_queue.pop_front()
				_dispatch_command(cmd)

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				var code := _peer.get_close_code()
				print("Godot MCP Studio: disconnected (code %d)" % code)

			# Reconnect with backoff
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_attempt_reconnect()

		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close to complete

		WebSocketPeer.STATE_CONNECTING:
			pass  # Wait for connection


func disconnect_from_server() -> void:
	if _connected:
		_peer.close(1000, "Plugin unloading")
		_connected = false


func _connect_to_server() -> void:
	var err := _peer.connect_to_url(_url)
	if err != OK:
		print("Godot MCP Studio: failed to initiate connection (error %d)" % err)


func _attempt_reconnect() -> void:
	var delay_idx := mini(_reconnect_attempt, RECONNECT_DELAYS.size() - 1)
	var delay := RECONNECT_DELAYS[delay_idx]
	_reconnect_attempt += 1
	_reconnect_timer = delay

	print("Godot MCP Studio: reconnecting in %.0fs (attempt %d)" % [delay, _reconnect_attempt])

	# Create fresh peer for reconnect
	_peer = WebSocketPeer.new()
	_connect_to_server()


func _send_handshake() -> void:
	var handshake := {
		"type": "handshake",
		"session_id": _session_id,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"project_path": ProjectSettings.globalize_path("res://"),
		"plugin_version": "0.0.1",
		"protocol_version": 1,
	}
	_send_json(handshake)


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
		_:
			result = {
				"request_id": request_id,
				"status": "error",
				"error": {
					"code": "UNKNOWN_COMMAND",
					"message": "Unknown command: %s" % command,
				}
			}
			_send_json(result)
			return

	result["request_id"] = request_id
	result["status"] = "ok"
	_send_json(result)


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
	_walk_tree(scene_root, nodes, 0, max_depth)
	return {"data": {"nodes": nodes, "total_count": nodes.size()}}


func _walk_tree(node: Node, out: Array[Dictionary], depth: int, max_depth: int) -> void:
	if depth > max_depth:
		return

	out.append({
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()),
		"children_count": node.get_child_count(),
	})

	for child in node.get_children():
		_walk_tree(child, out, depth + 1, max_depth)


func _handle_get_selection(_params: Dictionary) -> Dictionary:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		paths.append(str(node.get_path()))
	return {"data": {"selected_paths": paths, "count": paths.size()}}


func _handle_create_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", "")

	if node_type.is_empty():
		return {
			"status": "error",
			"error": {"code": "INVALID_PARAMS", "message": "Missing required param: type"}
		}

	# Verify the type exists
	if not ClassDB.class_exists(node_type):
		return {
			"status": "error",
			"error": {"code": "INVALID_PARAMS", "message": "Unknown node type: %s" % node_type}
		}
	if not ClassDB.is_parent_class(node_type, "Node"):
		return {
			"status": "error",
			"error": {"code": "INVALID_PARAMS", "message": "%s is not a Node type" % node_type}
		}

	# Find the parent
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {
			"status": "error",
			"error": {"code": "EDITOR_NOT_READY", "message": "No scene open"}
		}

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = scene_root.get_node_or_null(parent_path)
		if parent == null:
			# Try absolute path
			parent = scene_root.get_tree().root.get_node_or_null(parent_path)
		if parent == null:
			return {
				"status": "error",
				"error": {"code": "INVALID_PARAMS", "message": "Parent not found: %s" % parent_path}
			}

	# Create the node
	var new_node: Node = ClassDB.instantiate(node_type)
	if new_node == null:
		return {
			"status": "error",
			"error": {"code": "INTERNAL_ERROR", "message": "Failed to instantiate %s" % node_type}
		}

	if not node_name.is_empty():
		new_node.name = node_name

	# Add to parent and set owner so it saves with the scene
	parent.add_child(new_node, true)
	new_node.owner = scene_root

	return {
		"data": {
			"name": new_node.name,
			"type": new_node.get_class(),
			"path": str(new_node.get_path()),
			"parent_path": str(parent.get_path()),
		}
	}


func _send_json(data: Dictionary) -> void:
	if _connected:
		_peer.send_text(JSON.stringify(data))


func _generate_session_id() -> String:
	var bytes := PackedByteArray()
	for i in 16:
		bytes.append(randi() % 256)
	return bytes.hex_encode()
