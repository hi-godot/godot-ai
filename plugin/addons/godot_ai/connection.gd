@tool
class_name McpConnection
extends Node

## WebSocket transport to the Godot AI Python server.
## Only handles connect, reconnect, send, and receive.
## Command dispatch is owned by McpDispatcher.

const RECONNECT_DELAYS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 60.0]
const RECONNECT_VERBOSE_ATTEMPTS := 5
const RECONNECT_LOG_EVERY_N_ATTEMPTS := 10

var _peer := WebSocketPeer.new()
## Resolved from `McpClientConfigurator.ws_port()` in `_ready` so EditorSettings
## overrides land before the first connect. Previously a file-scope const, which
## baked the port at script compile time — meaning a reconfigured ws_port only
## took effect on the next editor restart.
var _url := ""
var _connected := false
var _reconnect_attempt := 0
var _reconnect_timer := 0.0
var _session_id := ""
## Godot-AI Python package version reported by the server in its `handshake_ack`
## reply. Empty until the ack lands. Older servers (pre-handshake_ack) leave
## this empty forever — callers that gate on it (the dock's mismatch banner)
## must treat empty as "unknown, don't raise a false alarm".
var server_version := ""

var dispatcher: McpDispatcher
var log_buffer: McpLogBuffer
## Set by plugin.gd when the HTTP port is occupied by an incompatible or
## unverified server. Keeping the Connection node alive lets handlers and the
## dock share one object, but no WebSocket is opened to the wrong server.
var connect_blocked := false
var connect_block_reason := ""
var _blocked_notice_logged := false
## Set to true to skip _process() during operations like save_scene
## that may trigger re-entrant frame processing.
var pause_processing := false


func _ready() -> void:
	_session_id = _make_session_id(ProjectSettings.globalize_path("res://"))
	_url = "ws://127.0.0.1:%d" % McpClientConfigurator.ws_port()
	## Increase outbound buffer for large messages (e.g. screenshot base64).
	## Default is 64 KB; screenshots can be several MB.
	_peer.outbound_buffer_size = 4 * 1024 * 1024  # 4 MB
	if connect_blocked:
		_log_blocked_notice_once()
		set_process(false)
		return
	_connect_to_server()
	_hook_editor_signals()


func _process(delta: float) -> void:
	if pause_processing:
		return
	_peer.poll()

	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_attempt = 0
				log_buffer.log("connected to server")
				_send_handshake()

			while _peer.get_available_packet_count() > 0:
				var raw := _peer.get_packet().get_string_from_utf8()
				_handle_message(raw)

			_check_state_changes()

			if dispatcher:
				for response in dispatcher.tick():
					_send_json(response)

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_clear_on_disconnect()
				var code := _peer.get_close_code()
				log_buffer.log("disconnected (code %d)" % code)
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_attempt_reconnect()

		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CONNECTING:
			pass


var is_connected: bool:
	get: return _connected


func disconnect_from_server() -> void:
	if _connected:
		_peer.close(1000, "Plugin unloading")
		_connected = false


## Reset per-connection state that was filled in by the previous server
## and must NOT bleed into the next one. `force_restart_server` swaps
## servers without reloading the plugin, so without this reset the dock
## would keep showing the killed server's version until the next ack.
## Also fires on plain reconnect-loop drops — correct either way.
func _clear_on_disconnect() -> void:
	server_version = ""


## Full pre-free cleanup for plugin unload: stop _process, close the
## socket, and drop dispatcher/log_buffer refs so their Callable-held
## RefCounted handlers decref before plugin.gd clears _handlers.
## See issue #46 and plugin.gd::_exit_tree.
func teardown() -> void:
	set_process(false)
	disconnect_from_server()
	dispatcher = null
	log_buffer = null


func _connect_to_server() -> void:
	var err := _peer.connect_to_url(_url)
	if err != OK:
		log_buffer.log("failed to initiate connection (error %d)" % err)


func _attempt_reconnect() -> void:
	if connect_blocked:
		_log_blocked_notice_once()
		set_process(false)
		return
	var delay := _reconnect_delay_for_attempt(_reconnect_attempt)
	_reconnect_attempt += 1
	_reconnect_timer = delay
	if _should_log_reconnect_attempt(_reconnect_attempt):
		log_buffer.log(
			"reconnecting (attempt %d; next retry in %.0fs if needed)"
			% [_reconnect_attempt, delay]
		)
	## Always create a fresh WebSocketPeer before reconnecting. A peer that has
	## reached STATE_CLOSED is terminal; reusing it can leave the editor stuck in
	## a quiet reconnect loop after the Python server restarts.
	_peer = WebSocketPeer.new()
	_peer.outbound_buffer_size = 4 * 1024 * 1024  # 4 MB
	_connect_to_server()


static func _reconnect_delay_for_attempt(attempt_index: int) -> float:
	var delay_idx := mini(attempt_index, RECONNECT_DELAYS.size() - 1)
	return RECONNECT_DELAYS[delay_idx]


static func _should_log_reconnect_attempt(attempt_number: int) -> bool:
	## Log the first few failures for immediate diagnostics, then only periodic
	## progress markers. Reconnect continues indefinitely; the log should not.
	return (
		attempt_number <= RECONNECT_VERBOSE_ATTEMPTS
		or attempt_number % RECONNECT_LOG_EVERY_N_ATTEMPTS == 0
	)


func _log_blocked_notice_once() -> void:
	if _blocked_notice_logged:
		return
	_blocked_notice_logged = true
	if log_buffer and not connect_block_reason.is_empty():
		log_buffer.log(connect_block_reason)


func _send_handshake() -> void:
	_last_readiness = get_readiness()
	_send_json({
		"type": "handshake",
		"session_id": _session_id,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"project_path": ProjectSettings.globalize_path("res://"),
		"plugin_version": McpClientConfigurator.get_plugin_version(),
		"protocol_version": 1,
		"readiness": _last_readiness,
		"editor_pid": OS.get_process_id(),
		"server_launch_mode": McpClientConfigurator.get_server_launch_mode(),
	})


func _handle_message(raw: String) -> void:
	var parsed = JSON.parse_string(raw)
	if parsed == null:
		push_warning("MCP: failed to parse message: %s" % raw)
		return
	if not (parsed is Dictionary):
		return
	if parsed.get("type", "") == "handshake_ack":
		server_version = str(parsed.get("server_version", ""))
		return
	if parsed.has("request_id") and parsed.has("command"):
		if dispatcher:
			dispatcher.enqueue(parsed)


## Send a state event to the server (not a command response).
func send_event(event_name: String, data: Dictionary = {}) -> void:
	_send_json({"type": "event", "event": event_name, "data": data})


## Push a command response for a request_id whose handler deferred its reply
## (see McpDispatcher.DEFERRED_RESPONSE). `payload` must carry either a `data`
## or `error` field in the same shape handlers normally return.
func send_deferred_response(request_id: String, payload: Dictionary) -> void:
	var response := payload.duplicate()
	response["request_id"] = request_id
	if not response.has("status"):
		response["status"] = "ok" if payload.has("data") else "error"
	_send_json(response)


func _hook_editor_signals() -> void:
	# Scene change: poll in _process since there's no direct signal for scene switch
	# Play state: EditorInterface signals
	EditorInterface.get_editor_settings()  # ensure interface is ready
	_last_scene_path = _get_current_scene_path()
	_last_play_state = EditorInterface.is_playing_scene()


var _last_scene_path := ""
var _last_play_state := false
var _last_readiness := ""


## Compute current editor readiness from live Godot state.
static func get_readiness() -> String:
	if EditorInterface.get_resource_filesystem().is_scanning():
		return "importing"
	if EditorInterface.is_playing_scene():
		return "playing"
	if EditorInterface.get_edited_scene_root() == null:
		return "no_scene"
	return "ready"


## Check for scene/play state changes each frame (lightweight polling).
func _check_state_changes() -> void:
	var scene_path := _get_current_scene_path()
	if scene_path != _last_scene_path:
		_last_scene_path = scene_path
		send_event("scene_changed", {"current_scene": scene_path})
		if log_buffer:
			log_buffer.log("[event] scene_changed -> %s" % scene_path)

	var playing := EditorInterface.is_playing_scene()
	if playing != _last_play_state:
		_last_play_state = playing
		var state := "playing" if playing else "stopped"
		send_event("play_state_changed", {"play_state": state})
		if log_buffer:
			log_buffer.log("[event] play_state_changed -> %s" % state)

	var readiness := get_readiness()
	if readiness != _last_readiness:
		_last_readiness = readiness
		send_event("readiness_changed", {"readiness": readiness})
		if log_buffer:
			log_buffer.log("[event] readiness -> %s" % readiness)


func _get_current_scene_path() -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	return scene_root.scene_file_path if scene_root else ""


func _send_json(data: Dictionary) -> void:
	if _connected:
		_peer.send_text(JSON.stringify(data))


## Build a human-readable session ID of form "<slug>@<4hex>" from the project path.
## The slug is derived from the project directory name so agents can recognize
## which editor they're targeting; the hex suffix disambiguates same-project twins.
static func _make_session_id(project_path: String) -> String:
	var base := project_path.rstrip("/\\").get_file()
	if base == "":
		base = "project"
	var slug := _slugify(base)
	if slug == "":
		slug = "project"
	var suffix := _rand_hex(4)
	return "%s@%s" % [slug, suffix]


static func _slugify(s: String) -> String:
	var out := ""
	var prev_dash := false
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
			prev_dash = false
		elif not prev_dash and out != "":
			out += "-"
			prev_dash = true
	return out.trim_suffix("-")


static func _rand_hex(n: int) -> String:
	var bytes := PackedByteArray()
	var byte_count := int(ceil(float(n) / 2.0))
	for i in byte_count:
		bytes.append(randi() % 256)
	return bytes.hex_encode().substr(0, n)
