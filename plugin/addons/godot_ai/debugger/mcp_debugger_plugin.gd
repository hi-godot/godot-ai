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
