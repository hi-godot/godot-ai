@tool
class_name McpDebuggerPlugin
extends EditorDebuggerPlugin

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Editor-side half of the game-process capture bridge.
##
## The game-side counterpart (`plugin/addons/godot_ai/runtime/game_helper.gd`,
## registered as autoload `_mcp_game_helper`) listens on EngineDebugger's
## message channel. This plugin sends "mcp:take_screenshot" requests and
## routes the replies back through the WebSocket McpConnection using the
## request_id the MCP dispatcher threaded through params.
##
## Why this exists: the game always runs as a separate OS process. Even
## "Embed Game Mode" on Windows/Linux (and macOS 4.5+) just reparents the
## game's window into the editor — the game's framebuffer is never reachable
## from the editor's Viewport. The debugger channel is the engine's own
## supported IPC and works identically regardless of embed mode.

const CAPTURE_PREFIX := "mcp"
## CI runners under xvfb can be slow to spin up the game subprocess and
## register the autoload's capture. 8s keeps the message responsive for
## interactive users while still covering slow-CI startup.
const DEFAULT_TIMEOUT_SEC := 8.0
## How long to wait for the game-side autoload to beacon mcp:hello
## before sending the screenshot request. Godot's debugger drops
## messages whose prefix has no registered capture, so sending
## take_screenshot before the game registers its "mcp" capture is a
## silent black hole. On CI the game subprocess has been observed
## taking ~15s to boot + register.
const GAME_READY_WAIT_SEC := 20.0

var _log_buffer: McpLogBuffer
var _game_log_buffer: McpGameLogBuffer

## Pending request_id -> {connection, timer, timeout_callable}.
## We retain the bound timeout lambda so `_clear_pending` can disconnect
## it on success/error; otherwise the SceneTreeTimer pins the captured
## request_id until `timeout_sec` elapses (8s default).
var _pending: Dictionary = {}

## Flipped true when the game-side autoload sends its "mcp:hello" boot
## beacon for the current project_run. Reset as soon as a new run is
## requested, before Godot has attached the fresh debugger session, so
## editor_state cannot leak readiness from the previous game process.
var _game_ready := false
var _game_run_token := 0
var _ready_run_token := -1
var _game_session_id := -1
var _game_run_active := false
signal game_ready


func _init(log_buffer: McpLogBuffer = null, game_log_buffer: McpGameLogBuffer = null) -> void:
	_log_buffer = log_buffer
	_game_log_buffer = game_log_buffer


func _has_capture(prefix: String) -> bool:
	return prefix == CAPTURE_PREFIX


## Fires when a debugger session attaches — once for the editor's own
## self-session at startup, and again each time the user hits Play and a
## new game subprocess connects. Reset _game_ready so the next capture
## request waits for the (new) game's mcp:hello beacon before sending,
## avoiding stale-flag timeouts across Play→Stop→Play cycles.
##
## Do NOT log here: add_debugger_plugin() triggers this virtual before
## plugin.gd's _enter_tree logs "plugin loaded", and ci-reload-test
## asserts "plugin loaded" is the first line after a plugin reload.
func _setup_session(session_id: int) -> void:
	_game_ready = false
	_ready_run_token = -1
	_game_session_id = session_id


func begin_game_run() -> void:
	_game_run_token += 1
	_game_run_active = true
	_game_ready = false
	_ready_run_token = -1
	_game_session_id = -1
	if _log_buffer:
		_log_buffer.log("[debug] game capture pending run token %d" % _game_run_token)


func end_game_run() -> void:
	_game_run_active = false
	_game_ready = false
	_ready_run_token = -1
	_game_session_id = -1


func is_game_capture_ready() -> bool:
	return _game_run_active and _game_ready and _ready_run_token == _game_run_token


func _capture(message: String, data: Array, _session_id: int) -> bool:
	## Godot passes the full "prefix:tail" string as `message`.
	match message:
		"mcp:screenshot_response":
			_on_screenshot_response(data)
			return true
		"mcp:screenshot_error":
			_on_screenshot_error(data)
			return true
		"mcp:log_batch":
			_on_log_batch(data)
			return true
		"mcp:hello":
			if not _game_run_active:
				if _log_buffer:
					_log_buffer.log("[debug] ignored mcp:hello with no active game run")
				return true
			if _game_session_id != -1 and _session_id != _game_session_id:
				if _log_buffer:
					_log_buffer.log("[debug] ignored stale mcp:hello from debugger session %d (current %d)" % [_session_id, _game_session_id])
				return true
			## Boot beacon from the game-side autoload. Tells us the
			## game has registered its "mcp" capture and is safe to send
			## take_screenshot to — before this, Godot's debugger would
			## drop our message silently. Also marks a fresh play
			## cycle: rotate the game-log buffer so each run starts
			## clean and gets a new run_id.
			_game_ready = true
			_ready_run_token = _game_run_token
			game_ready.emit()
			if _game_log_buffer:
				var run_id := _game_log_buffer.clear_for_new_run()
				if _log_buffer:
					_log_buffer.log("[debug] <- mcp:hello from game_helper (run %s)" % run_id)
			elif _log_buffer:
				_log_buffer.log("[debug] <- mcp:hello from game_helper")
			return true
		"mcp:eval_response":
			_on_eval_response(data)
			return true
		"mcp:eval_error":
			_on_eval_error(data)
			return true
		"mcp:get_property_response":
			_on_get_property_response(data)
			return true
		"mcp:get_property_error":
			_on_get_property_error(data)
			return true
		"mcp:set_property_response":
			_on_set_property_response(data)
			return true
		"mcp:set_property_error":
			_on_set_property_error(data)
			return true
		"mcp:call_method_response":
			_on_call_method_response(data)
			return true
		"mcp:call_method_error":
			_on_call_method_error(data)
			return true
		"mcp:click_response":
			_on_click_response(data)
			return true
		"mcp:key_press_response":
			_on_key_press_response(data)
			return true
		"mcp:key_press_error":
			_on_key_press_error(data)
			return true
		"mcp:mouse_move_response":
			_on_mouse_move_response(data)
			return true
		"mcp:key_hold_response":
			_on_key_hold_response(data)
			return true
		"mcp:key_hold_error":
			_on_key_hold_error(data)
			return true
		"mcp:key_release_response":
			_on_key_release_response(data)
			return true
		"mcp:key_release_error":
			_on_key_release_error(data)
			return true
		"mcp:scroll_response":
			_on_scroll_response(data)
			return true
		"mcp:list_signals_response":
			_on_list_signals_response(data)
			return true
		"mcp:list_signals_error":
			_on_list_signals_error(data)
			return true
		"mcp:connect_signal_response":
			_on_connect_signal_response(data)
			return true
		"mcp:connect_signal_error":
			_on_connect_signal_error(data)
			return true
		"mcp:disconnect_signal_response":
			_on_disconnect_signal_response(data)
			return true
		"mcp:disconnect_signal_error":
			_on_disconnect_signal_error(data)
			return true
		"mcp:emit_signal_response":
			_on_emit_signal_response(data)
			return true
		"mcp:emit_signal_error":
			_on_emit_signal_error(data)
			return true
		"mcp:pause_response":
			_on_pause_response(data)
			return true
		"mcp:get_scene_tree_response":
			_on_get_scene_tree_response(data)
			return true
		"mcp:get_scene_tree_error":
			_on_get_scene_tree_error(data)
			return true
		"mcp:get_node_info_response":
			_on_get_node_info_response(data)
			return true
		"mcp:get_node_info_error":
			_on_get_node_info_error(data)
			return true
		"mcp:spawn_node_response":
			_on_spawn_node_response(data)
			return true
		"mcp:spawn_node_error":
			_on_spawn_node_error(data)
			return true
		"mcp:remove_node_response":
			_on_remove_node_response(data)
			return true
		"mcp:remove_node_error":
			_on_remove_node_error(data)
			return true
		"mcp:instantiate_scene_response":
			_on_instantiate_scene_response(data)
			return true
		"mcp:instantiate_scene_error":
			_on_instantiate_scene_error(data)
			return true
		"mcp:get_performance_response":
			_on_get_performance_response(data)
			return true
		"mcp:get_ui_elements_response":
			_on_get_ui_elements_response(data)
			return true
		"mcp:get_nodes_in_group_response":
			_on_get_nodes_in_group_response(data)
			return true
		"mcp:get_nodes_in_group_error":
			_on_get_nodes_in_group_error(data)
			return true
		"mcp:find_nodes_by_class_response":
			_on_find_nodes_by_class_response(data)
			return true
		"mcp:find_nodes_by_class_error":
			_on_find_nodes_by_class_error(data)
			return true
		"mcp:get_camera_response":
			_on_get_camera_response(data)
			return true
		"mcp:set_camera_response":
			_on_set_camera_response(data)
			return true
		"mcp:set_camera_error":
			_on_set_camera_error(data)
			return true
		"mcp:raycast_response":
			_on_raycast_response(data)
			return true
		"mcp:raycast_error":
			_on_raycast_error(data)
			return true
		"mcp:play_animation_response":
			_on_play_animation_response(data)
			return true
		"mcp:play_animation_error":
			_on_play_animation_error(data)
			return true
		"mcp:serialize_state_response":
			_on_serialize_state_response(data)
			return true
		"mcp:serialize_state_error":
			_on_serialize_state_error(data)
			return true
		"mcp:get_audio_response":
			_on_get_audio_response(data)
			return true
		"mcp:audio_play_response":
			_on_audio_play_response(data)
			return true
		"mcp:audio_play_error":
			_on_audio_play_error(data)
			return true
		"mcp:audio_bus_response":
			_on_audio_bus_response(data)
			return true
		"mcp:audio_bus_error":
			_on_audio_bus_error(data)
			return true
		"mcp:environment_response":
			_on_environment_response(data)
			return true
		"mcp:environment_error":
			_on_environment_error(data)
			return true
		"mcp:physics_body_response":
			_on_physics_body_response(data)
			return true
		"mcp:physics_body_error":
			_on_physics_body_error(data)
			return true
		"mcp:light_3d_response":
			_on_light_3d_response(data)
			return true
		"mcp:light_3d_error":
			_on_light_3d_error(data)
			return true
		"mcp:mesh_instance_response":
			_on_mesh_instance_response(data)
			return true
		"mcp:mesh_instance_error":
			_on_mesh_instance_error(data)
			return true
		"mcp:navigate_path_response":
			_on_navigate_path_response(data)
			return true
		"mcp:navigate_path_error":
			_on_navigate_path_error(data)
			return true
		"mcp:navigation_3d_response":
			_on_navigation_3d_response(data)
			return true
		"mcp:navigation_3d_error":
			_on_navigation_3d_error(data)
			return true
		"mcp:animation_tree_response":
			_on_animation_tree_response(data)
			return true
		"mcp:animation_tree_error":
			_on_animation_tree_error(data)
			return true
		"mcp:create_animation_response":
			_on_create_animation_response(data)
			return true
		"mcp:create_animation_error":
			_on_create_animation_error(data)
			return true
		"mcp:skeleton_ik_response":
			_on_skeleton_ik_response(data)
			return true
		"mcp:skeleton_ik_error":
			_on_skeleton_ik_error(data)
			return true
		"mcp:time_scale_response":
			_on_time_scale_response(data)
			return true
		"mcp:window_response":
			_on_window_response(data)
			return true
		"mcp:gamepad_response":
			_on_gamepad_response(data)
			return true
		"mcp:mouse_drag_response":
			_on_mouse_drag_response(data)
			return true
		"mcp:ui_debug_response":
			_on_ui_debug_response(data)
			return true
		"mcp:ui_debug_error":
			_on_ui_debug_error(data)
			return true
		"mcp:debug_draw_response":
			_on_debug_draw_response(data)
			return true
		"mcp:input_state_response":
			_on_input_state_response(data)
			return true
		"mcp:create_timer_response":
			_on_create_timer_response(data)
			return true
		"mcp:create_timer_error":
			_on_create_timer_error(data)
			return true
		"mcp:tween_property_response":
			_on_tween_property_response(data)
			return true
		"mcp:tween_property_error":
			_on_tween_property_error(data)
			return true
	return false


func _on_log_batch(data: Array) -> void:
	if _game_log_buffer == null:
		return
	## data layout: [[[level, text], [level, text], ...]]
	if data.is_empty() or not (data[0] is Array):
		return
	var entries: Array = data[0]
	for entry in entries:
		if not (entry is Array) or entry.size() < 2:
			continue
		_game_log_buffer.append(str(entry[0]), str(entry[1]))


## Request a game-process framebuffer capture over the debugger channel.
## Reply is pushed back through `connection` out-of-band because the MCP
## dispatcher has already returned a deferred-response marker for this
## request_id. Synchronous from the caller's perspective — if the
## game-side autoload hasn't beaconed yet, the wait + send run as a
## fire-and-forget coroutine kicked off from here. Structured this way
## so the call site in EditorHandler stays a plain non-await invocation.
func request_game_screenshot(
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float = DEFAULT_TIMEOUT_SEC,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: screenshot request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule capture")
		return

	if is_game_capture_ready():
		_send_take_screenshot(tree, request_id, max_resolution, connection, timeout_sec)
		return

	## Not ready yet — run the wait-then-send flow as a detached
	## coroutine. It keeps itself alive via the signal subscription on
	## tree.process_frame; the caller doesn't need to (and shouldn't)
	## await this entrypoint.
	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello (%s)" % request_id)
	_wait_then_send(tree, request_id, max_resolution, connection, timeout_sec)


## Coroutine: poll each editor frame until the mcp:hello beacon arrives
## (flipping _game_ready true) or the deadline elapses. Once resolved,
## either dispatch the capture or return an actionable timeout error.
func _wait_then_send(
	tree: SceneTree,
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var deadline := Time.get_ticks_msec() + int(GAME_READY_WAIT_SEC * 1000.0)
	while not is_game_capture_ready() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not is_game_capture_ready():
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game-side autoload never registered its debugger capture within %ds. Is the game actually running? Check Project Settings → Autoload for _mcp_game_helper." % int(GAME_READY_WAIT_SEC))
		return
	_send_take_screenshot(tree, request_id, max_resolution, connection, timeout_sec)


## Send the mcp:take_screenshot message and arm the reply timeout.
## Assumes _game_ready is true.
func _send_take_screenshot(
	tree: SceneTree,
	request_id: String,
	max_resolution: int,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running and started from this editor?")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void: _on_timeout(request_id)
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message("mcp:take_screenshot", [request_id, max_resolution])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:take_screenshot (%s)" % request_id)


func _first_active_session() -> EditorDebuggerSession:
	for s in get_sessions():
		if s is EditorDebuggerSession and s.is_active():
			return s
	return null


func _on_screenshot_response(data: Array) -> void:
	if data.size() < 6:
		push_warning("MCP debugger: malformed screenshot response (expected 6 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending = _pending.get(request_id)
	if pending == null:
		## Timed out or unknown — silently drop.
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return

	connection.send_deferred_response(request_id, {
		"data": {
			"source": "game",
			"width": int(data[2]),
			"height": int(data[3]),
			"original_width": int(data[4]),
			"original_height": int(data[5]),
			"format": "png",
			"image_base64": data[1],
		}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:screenshot_response (%s)" % request_id)


func _on_screenshot_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending = _pending.get(request_id)
	if pending == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)


func _on_timeout(request_id: String) -> void:
	var pending = _pending.get(request_id)
	if pending == null:
		return
	_pending.erase(request_id)
	var connection: McpConnection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
		"Game screenshot timed out. The running game must include the _mcp_game_helper autoload (added automatically when the plugin is enabled — check Project Settings → Autoload). If the autoload is missing, re-enable the plugin and relaunch the game. For headless or custom-main-loop builds, use source='viewport' instead.")
	if _log_buffer:
		_log_buffer.log("[debug] !! screenshot timeout (%s)" % request_id)


func _send_error(connection: McpConnection, request_id: String, code: String, message: String) -> void:
	if connection == null or not is_instance_valid(connection):
		return
	var err := ErrorCodes.make(code, message)
	connection.send_deferred_response(request_id, err)


func _clear_pending(request_id: String) -> void:
	var pending: Dictionary = _pending.get(request_id, {})
	var timer: SceneTreeTimer = pending.get("timer")
	var cb: Callable = pending.get("timeout_callable", Callable())
	if timer != null and timer.timeout.is_connected(cb):
		timer.timeout.disconnect(cb)
	_pending.erase(request_id)


## --- game_eval: execute arbitrary GDScript in the running game ---

func request_game_eval(
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 10.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: eval request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule eval")
		return

	if is_game_capture_ready():
		_send_eval(tree, code, request_id, connection, timeout_sec)
		return

	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello before eval (%s)" % request_id)
	_wait_then_eval(tree, code, request_id, connection, timeout_sec)


func _wait_then_eval(
	tree: SceneTree,
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var deadline := Time.get_ticks_msec() + int(GAME_READY_WAIT_SEC * 1000.0)
	while not is_game_capture_ready() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if not is_game_capture_ready():
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game-side autoload never registered its debugger capture within %ds. Is the game actually running?" % int(GAME_READY_WAIT_SEC))
		return
	_send_eval(tree, code, request_id, connection, timeout_sec)


func _send_eval(
	tree: SceneTree,
	code: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running?")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void:
		var pending_entry = _pending.get(request_id)
		if pending_entry == null:
			return
		_pending.erase(request_id)
		var conn: McpConnection = pending_entry.connection
		if conn == null or not is_instance_valid(conn):
			return
		_send_error(conn, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game eval timed out after %.0fs — eval code may be stuck in an infinite loop / await, OR triggered a GDScript runtime error that halted execution before responding. Check logs_read(source='game') for push_error/runtime errors from this run." % timeout_sec)
		if _log_buffer:
			_log_buffer.log("[debug] !! eval timeout (%s)" % request_id)
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message("mcp:eval", [request_id, code])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:eval (%s)" % request_id)


func _on_eval_response(data: Array) -> void:
	if data.size() < 2:
		push_warning("MCP debugger: malformed eval response (expected 2 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return

	var result_json: String = data[1] if data.size() > 1 else "null"
	var json := JSON.new()
	var parse_err := json.parse(result_json)
	connection.send_deferred_response(request_id, {
		"data": {
			"result": json.data if parse_err == OK else result_json,
			"source": "game",
		}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_response (%s)" % request_id)


func _on_eval_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_error (%s): %s" % [request_id, message])


## --- game_get_property / game_set_property ---

func request_game_get_property(
	node_path: String,
	property: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 5.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: get_property request missing request_id")
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree")
		return
	_send_debugger(tree, "mcp:get_property", [request_id, node_path, property],
		request_id, connection, timeout_sec)


func request_game_set_property(
	node_path: String,
	property: String,
	value_json: String,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 5.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: set_property request missing request_id")
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree")
		return
	_send_debugger(tree, "mcp:set_property", [request_id, node_path, property, value_json],
		request_id, connection, timeout_sec)


func _send_debugger(
	tree: SceneTree,
	message: String,
	payload: Array,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float,
) -> void:
	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running?")
		return

	var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
	var timeout_callable := func() -> void:
		var pending_entry = _pending.get(request_id)
		if pending_entry == null:
			return
		_pending.erase(request_id)
		var conn: McpConnection = pending_entry.connection
		if conn == null or not is_instance_valid(conn):
			return
		_send_error(conn, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game command '%s' timed out after %.0fs." % [message, timeout_sec])
		if _log_buffer:
			_log_buffer.log("[debug] !! %s timeout (%s)" % [message, request_id])
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message(message, payload)
	if _log_buffer:
		_log_buffer.log("[debug] -> %s (%s)" % [message, request_id])


func _on_get_property_response(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var result_json: String = data[1] if data.size() > 1 else "null"
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	var parsed = JSON.parse_string(result_json)
	connection.send_deferred_response(request_id, {
		"data": {"value": parsed if parsed != null else result_json, "source": "game"}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:get_property_response (%s)" % request_id)


func _on_get_property_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)


func _on_set_property_response(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var result_json: String = data[1] if data.size() > 1 else "null"
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	var parsed = JSON.parse_string(result_json)
	connection.send_deferred_response(request_id, {
		"data": {"value": parsed if parsed != null else result_json, "source": "game"}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:set_property_response (%s)" % request_id)


func _on_set_property_error(data: Array) -> void:
	if data.size() < 2:
		return
	var request_id: String = data[0]
	var message: String = data[1]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)
	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, message)


## --- game_call_method ---

func request_game_call_method(
	node_path: String, method_name: String, args: Array,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0,
) -> void:
	if request_id.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree")
		return
	_send_debugger(tree, "mcp:call_method",
		[request_id, node_path, method_name, JSON.stringify(args)],
		request_id, connection, timeout_sec)


func _on_call_method_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "null")
	conn.send_deferred_response(rid,
		{"data": {"result": parsed if parsed != null else data[1], "source": "game"}})


func _on_call_method_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


## --- Input simulation ---

func request_game_click(x: float, y: float, button: int,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:click", [request_id, x, y, button], request_id, connection, timeout_sec)


func request_game_key_press(key: String, action: String, pressed: bool,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:key_press", [request_id, key, action, pressed], request_id, connection, timeout_sec)


func request_game_mouse_move(x: float, y: float, rel_x: float, rel_y: float,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:mouse_move", [request_id, x, y, rel_x, rel_y], request_id, connection, timeout_sec)


func _on_click_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_key_press_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_key_press_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_mouse_move_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func request_game_key_hold(key: String, action: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:key_hold", [request_id, key, action], request_id, connection, timeout_sec)


func request_game_key_release(key: String, action: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:key_release", [request_id, key, action], request_id, connection, timeout_sec)


func request_game_scroll(x: float, y: float,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:scroll", [request_id, x, y], request_id, connection, timeout_sec)


func _on_key_hold_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_key_hold_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_key_release_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_key_release_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_scroll_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]; var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid); var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func request_game_list_signals(node_path: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:list_signals", [request_id, node_path], request_id, connection, timeout_sec)


func request_game_connect_signal(node_path: String, signal_name: String, target_node_path: String, target_method: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:connect_signal", [request_id, node_path, signal_name, target_node_path, target_method], request_id, connection, timeout_sec)


func request_game_disconnect_signal(node_path: String, signal_name: String, target_node_path: String, target_method: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:disconnect_signal", [request_id, node_path, signal_name, target_node_path, target_method], request_id, connection, timeout_sec)


func request_game_emit_signal(node_path: String, signal_name: String, args: Array,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:emit_signal", [request_id, node_path, signal_name, JSON.stringify(args)], request_id, connection, timeout_sec)


func _on_list_signals_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "[]")
	conn.send_deferred_response(rid, {"data": {"signals": parsed if parsed else [], "source": "game"}})


func _on_list_signals_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_connect_signal_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_connect_signal_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_disconnect_signal_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_disconnect_signal_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_emit_signal_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_emit_signal_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_pause(paused: bool,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:pause", [request_id, paused], request_id, connection, timeout_sec)


func request_game_get_scene_tree(
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_scene_tree", [request_id], request_id, connection, timeout_sec)


func request_game_get_node_info(node_path: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_node_info", [request_id, node_path], request_id, connection, timeout_sec)


func request_game_spawn_node(type_name: String, node_name: String, parent_path: String, properties: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:spawn_node", [request_id, type_name, node_name, parent_path, properties], request_id, connection, timeout_sec)


func request_game_remove_node(node_path: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:remove_node", [request_id, node_path], request_id, connection, timeout_sec)


func request_game_instantiate_scene(scene_path: String, parent_path: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:instantiate_scene", [request_id, scene_path, parent_path], request_id, connection, timeout_sec)


func _on_pause_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_get_scene_tree_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": {"tree": parsed if parsed else {}}})


func _on_get_scene_tree_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_get_node_info_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_get_node_info_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_spawn_node_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_spawn_node_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_remove_node_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_remove_node_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_instantiate_scene_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_instantiate_scene_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_get_performance(
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_performance", [request_id], request_id, connection, timeout_sec)


func request_game_get_ui_elements(
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_ui_elements", [request_id], request_id, connection, timeout_sec)


func request_game_get_nodes_in_group(group_name: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_nodes_in_group", [request_id, group_name], request_id, connection, timeout_sec)


func request_game_find_nodes_by_class(cls: String, root_path: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:find_nodes_by_class", [request_id, cls, root_path], request_id, connection, timeout_sec)


func _on_get_performance_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_get_ui_elements_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "[]")
	conn.send_deferred_response(rid, {"data": {"elements": parsed if parsed else []}})


func _on_get_nodes_in_group_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_get_nodes_in_group_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_find_nodes_by_class_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_find_nodes_by_class_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_get_camera(
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_camera", [request_id], request_id, connection, timeout_sec)


func request_game_set_camera(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:set_camera", [request_id, params_json], request_id, connection, timeout_sec)


func request_game_raycast(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:raycast", [request_id, params_json], request_id, connection, timeout_sec)


func request_game_play_animation(node_path: String, action: String, anim: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:play_animation", [request_id, node_path, action, anim], request_id, connection, timeout_sec)


func request_game_serialize_state(node_path: String, action: String, max_depth: int, data_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 15.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:serialize_state", [request_id, node_path, action, max_depth, data_json], request_id, connection, timeout_sec)


func _on_get_camera_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_set_camera_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_set_camera_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_raycast_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_raycast_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_play_animation_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_play_animation_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_serialize_state_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_serialize_state_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_get_audio(
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:get_audio", [request_id], request_id, connection, timeout_sec)


func request_game_audio_play(node_path: String, action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:audio_play", [request_id, node_path, action, params_json], request_id, connection, timeout_sec)


func request_game_audio_bus(bus_name: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:audio_bus", [request_id, bus_name, params_json], request_id, connection, timeout_sec)


func _on_get_audio_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_audio_play_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_audio_play_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_audio_bus_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_audio_bus_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_environment(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:environment", [request_id, action, params_json], request_id, connection, timeout_sec)


func _on_environment_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_environment_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_physics_body(node_path: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:physics_body", [request_id, node_path, params_json], request_id, connection, timeout_sec)


func _on_physics_body_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_physics_body_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_light_3d(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:light_3d", [request_id, action, params_json], request_id, connection, timeout_sec)


func request_game_mesh_instance(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:mesh_instance", [request_id, params_json], request_id, connection, timeout_sec)


func _on_light_3d_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_light_3d_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_mesh_instance_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_mesh_instance_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_navigate_path(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:navigate_path", [request_id, params_json], request_id, connection, timeout_sec)


func request_game_navigation_3d(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 15.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:navigation_3d", [request_id, action, params_json], request_id, connection, timeout_sec)


func _on_navigate_path_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_navigate_path_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_navigation_3d_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_navigation_3d_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_animation_tree(node_path: String, action: String, param: String, param2,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:animation_tree", [request_id, node_path, action, param, param2], request_id, connection, timeout_sec)


func request_game_create_animation(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 15.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:create_animation", [request_id, params_json], request_id, connection, timeout_sec)


func request_game_skeleton_ik(node_path: String, action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:skeleton_ik", [request_id, node_path, action, params_json], request_id, connection, timeout_sec)


func _on_animation_tree_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_animation_tree_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_create_animation_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_create_animation_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_skeleton_ik_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_skeleton_ik_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_time_scale(action: String, value: float,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:time_scale", [request_id, action, value], request_id, connection, timeout_sec)


func request_game_window(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:window", [request_id, action, params_json], request_id, connection, timeout_sec)


func request_game_gamepad(input_type: String, index: int, value: float, device: int,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:gamepad", [request_id, input_type, index, value, device], request_id, connection, timeout_sec)


func request_game_mouse_drag(from_x: float, from_y: float, to_x: float, to_y: float, button: int,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:mouse_drag", [request_id, from_x, from_y, to_x, to_y, button], request_id, connection, timeout_sec)


func request_game_ui_debug(node_path: String, action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:ui_debug", [request_id, node_path, action, params_json], request_id, connection, timeout_sec)


func _on_time_scale_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_window_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_gamepad_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_mouse_drag_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_ui_debug_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_ui_debug_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func request_game_debug_draw(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:debug_draw", [request_id, action, params_json], request_id, connection, timeout_sec)


func request_game_input_state(action: String, params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 5.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:input_state", [request_id, action, params_json], request_id, connection, timeout_sec)


func request_game_create_timer(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:create_timer", [request_id, params_json], request_id, connection, timeout_sec)


func request_game_tween_property(params_json: String,
	request_id: String, connection: McpConnection, timeout_sec: float = 10.0) -> void:
	if request_id.is_empty(): return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: _send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR, "No SceneTree"); return
	_send_debugger(tree, "mcp:tween_property", [request_id, params_json], request_id, connection, timeout_sec)


func _on_debug_draw_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_input_state_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_create_timer_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_create_timer_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])


func _on_tween_property_response(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	var parsed = JSON.parse_string(data[1] if data.size() > 1 else "{}")
	conn.send_deferred_response(rid, {"data": parsed if parsed else {}})


func _on_tween_property_error(data: Array) -> void:
	if data.size() < 2: return
	var rid: String = data[0]
	var pend = _pending.get(rid)
	if pend == null: return
	_clear_pending(rid)
	var conn: McpConnection = pend.connection
	if conn == null or not is_instance_valid(conn): return
	_send_error(conn, rid, ErrorCodes.INTERNAL_ERROR, data[1])
