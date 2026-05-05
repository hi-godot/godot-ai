@tool
class_name McpConnection
extends Node

## WebSocket transport to the Godot AI Python server.
## Only handles connect, reconnect, send, and receive.
## Command dispatch is owned by McpDispatcher.

const RECONNECT_DELAYS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 60.0]
const RECONNECT_VERBOSE_ATTEMPTS := 5
const RECONNECT_LOG_EVERY_N_ATTEMPTS := 10
## Backpressure policy: do not queue responses once the WebSocket's current
## outbound buffer plus the next payload would exceed this cap. Command
## responses get a compact structured error when that can still be sent;
## state events report failure so their callers can retry on a later tick.
const OUTBOUND_BUFFER_LIMIT_BYTES := 4 * 1024 * 1024
## Cap the inbound packet drain per `_process` tick. A flooding peer or a
## fast batch could otherwise saturate `_handle_message` in one frame and
## blow the documented 4ms budget. Packets beyond this cap spill to the
## next frame; the cumulative spill counter is logged so flood patterns
## are observable in `logs_read`. See audit-v2 finding #12 (issue #356).
const PACKET_DRAIN_CAP_PER_TICK := 32
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

var _peer := WebSocketPeer.new()
## Set by plugin.gd after resolving the configured WebSocket port once for the
## server spawn. Reconnects reuse this cached value so they keep dialing the
## same port the Python server was asked to bind.
var ws_port := ClientConfigurator.DEFAULT_WS_PORT
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

var dispatcher
var log_buffer
## Set by plugin.gd when the HTTP port is occupied by an incompatible or
## unverified server. Keeping the Connection node alive lets handlers and the
## dock share one object, but no WebSocket is opened to the wrong server.
var connect_blocked := false
var connect_block_reason := ""
var _blocked_notice_logged := false
## Compatibility property used by existing handlers. Setting true increments
## the pause depth; setting false decrements it. Processing stays paused until
## every nested pause has resumed.
var pause_processing: bool:
	get: return _pause_depth > 0
	set(value):
		if value:
			pause()
		else:
			resume()
var _pause_depth := 0
## Cumulative count of inbound packets that didn't fit in their tick's drain
## budget and got deferred to a subsequent tick. Reset on disconnect so each
## connection starts with a clean spillover history. Logged whenever new
## spillover occurs so flood patterns surface in `logs_read`.
var _packet_spillover_total := 0


func _ready() -> void:
	_session_id = _make_session_id(ProjectSettings.globalize_path("res://"))
	## Increase outbound buffer for large messages (e.g. screenshot base64).
	## Default is 64 KB; screenshots can be several MB.
	_peer.outbound_buffer_size = OUTBOUND_BUFFER_LIMIT_BYTES
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

			_drain_inbound_packets(_peer)

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


## Drain up to PACKET_DRAIN_CAP_PER_TICK inbound packets and dispatch each
## via `_handle_message`. Anything past the cap stays in the peer's queue
## and gets picked up next tick. The cumulative spillover count is logged
## (via `log_buffer`) only when the cap was actually hit AND packets remain
## — sustained flood thus emits one log line per tick with the running
## total, while a normal-traffic frame stays silent.
##
## `peer` is untyped (Variant) so tests can inject a duck-typed fake with
## `get_available_packet_count()` + `get_packet()`. Production passes the
## real `_peer: WebSocketPeer`.
func _drain_inbound_packets(peer) -> Dictionary:
	var drained := 0
	while peer.get_available_packet_count() > 0 and drained < PACKET_DRAIN_CAP_PER_TICK:
		var raw: String = peer.get_packet().get_string_from_utf8()
		_handle_message(raw)
		drained += 1

	var spilled := 0
	if drained >= PACKET_DRAIN_CAP_PER_TICK and peer.get_available_packet_count() > 0:
		spilled = peer.get_available_packet_count()
		_packet_spillover_total += spilled
		if log_buffer:
			log_buffer.log(
				(
					"[backpressure] inbound drain capped at %d/tick;"
					+ " %d packets spilled to next frame (cumulative %d)"
				)
				% [PACKET_DRAIN_CAP_PER_TICK, spilled, _packet_spillover_total]
			)

	return {"drained": drained, "spilled": spilled}


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
	## Reset the spillover counter so a flood pattern from the previous
	## connection doesn't pollute the next one's `logs_read` baseline.
	_packet_spillover_total = 0
	if dispatcher:
		dispatcher.clear_deferred_responses()


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
	_url = "ws://127.0.0.1:%d" % ws_port
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
	_peer.outbound_buffer_size = OUTBOUND_BUFFER_LIMIT_BYTES
	_connect_to_server()


func pause() -> void:
	_pause_depth += 1


func resume() -> void:
	_pause_depth = maxi(0, _pause_depth - 1)


func pause_depth() -> int:
	return _pause_depth


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
		"plugin_version": ClientConfigurator.get_plugin_version(),
		"protocol_version": 1,
		"readiness": _last_readiness,
		"editor_pid": OS.get_process_id(),
		"server_launch_mode": ClientConfigurator.get_server_launch_mode(),
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
func send_event(event_name: String, data: Dictionary = {}) -> bool:
	return _send_json({"type": "event", "event": event_name, "data": data})


## Push a command response for a request_id whose handler deferred its reply
## (see McpDispatcher.DEFERRED_RESPONSE). `payload` must carry either a `data`
## or `error` field in the same shape handlers normally return.
func send_deferred_response(request_id: String, payload: Dictionary) -> void:
	if dispatcher != null and not dispatcher.has_pending_deferred_response(request_id):
		if log_buffer:
			log_buffer.log("[defer] dropped late response for expired request %s" % request_id)
		return
	var response := payload.duplicate()
	response["request_id"] = request_id
	if not response.has("status"):
		response["status"] = "ok" if payload.has("data") else "error"
	if _send_json(response) and dispatcher != null:
		dispatcher.complete_deferred_response(request_id)


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
		if send_event("scene_changed", {"current_scene": scene_path}):
			_last_scene_path = scene_path
			if log_buffer:
				log_buffer.log("[event] scene_changed -> %s" % scene_path)

	var playing := EditorInterface.is_playing_scene()
	if playing != _last_play_state:
		var state := "playing" if playing else "stopped"
		if send_event("play_state_changed", {"play_state": state}):
			_last_play_state = playing
			if log_buffer:
				log_buffer.log("[event] play_state_changed -> %s" % state)

	var readiness := get_readiness()
	if readiness != _last_readiness:
		if send_event("readiness_changed", {"readiness": readiness}):
			_last_readiness = readiness
			if log_buffer:
				log_buffer.log("[event] readiness -> %s" % readiness)


func _get_current_scene_path() -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	return scene_root.scene_file_path if scene_root else ""


func _send_json(data: Dictionary) -> bool:
	if not _connected:
		return false
	var text := JSON.stringify(data)
	var message_bytes := text.to_utf8_buffer().size()
	var buffered_bytes := _peer.get_current_outbound_buffered_amount()
	if _would_exceed_outbound_backpressure(buffered_bytes, message_bytes):
		return _handle_outbound_backpressure(data, buffered_bytes, message_bytes)
	var err := _peer.send_text(text)
	if err != OK:
		if log_buffer:
			log_buffer.log("[send] websocket send_text failed: %s" % error_string(err))
		return false
	return true


static func _would_exceed_outbound_backpressure(buffered_bytes: int, message_bytes: int) -> bool:
	return buffered_bytes + message_bytes > OUTBOUND_BUFFER_LIMIT_BYTES


func _handle_outbound_backpressure(
	data: Dictionary,
	buffered_bytes: int,
	message_bytes: int,
) -> bool:
	var request_id: String = data.get("request_id", "")
	if request_id.is_empty():
		if log_buffer:
			log_buffer.log(
				"[send] requestless payload blocked by websocket backpressure "
				+ "(buffered=%d, message=%d, limit=%d)"
				% [buffered_bytes, message_bytes, OUTBOUND_BUFFER_LIMIT_BYTES]
			)
		return false

	var err_response := _make_backpressure_error(request_id, buffered_bytes, message_bytes)
	var err_text := JSON.stringify(err_response)
	var err_bytes := err_text.to_utf8_buffer().size()
	if _would_exceed_outbound_backpressure(buffered_bytes, err_bytes):
		if log_buffer:
			log_buffer.log(
				"[send] dropped response for request %s due to websocket backpressure "
				+ "(buffered=%d, message=%d, limit=%d)"
				% [request_id, buffered_bytes, message_bytes, OUTBOUND_BUFFER_LIMIT_BYTES]
			)
		return false

	var send_err := _peer.send_text(err_text)
	if send_err != OK:
		if log_buffer:
			log_buffer.log("[send] websocket backpressure error send failed: %s" % error_string(send_err))
		return false
	if log_buffer:
		log_buffer.log(
			"[send] %s -> error: outbound websocket backpressure"
			% data.get("command", "response")
		)
	return true


static func _make_backpressure_error(
	request_id: String,
	buffered_bytes: int,
	message_bytes: int,
) -> Dictionary:
	return {
		"request_id": request_id,
		"status": "error",
		"data": {},
		"error": {
			"code": ErrorCodes.INTERNAL_ERROR,
			"message": (
				"Outbound WebSocket buffer is full; dropped response before queueing "
				+ "more data. Retry with a smaller payload (for screenshots, lower "
				+ "max_resolution or set include_image=false)."
			),
			"data": {
				"buffered_bytes": buffered_bytes,
				"message_bytes": message_bytes,
				"limit_bytes": OUTBOUND_BUFFER_LIMIT_BYTES,
			},
		},
	}


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
