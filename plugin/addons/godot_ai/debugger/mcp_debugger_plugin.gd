@tool
class_name McpDebuggerPlugin
extends EditorDebuggerPlugin

## Editor-side half of the game-process capture bridge.
##
## The game-side counterpart (`plugin/addons/godot_ai/runtime/game_helper.gd`,
## registered as autoload `_mcp_game_helper`) listens on EngineDebugger's
## message channel. This plugin sends "mcp:take_screenshot" requests and
## routes the replies back through the WebSocket Connection using the
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

var _log_buffer: McpLogBuffer

## Pending request_id -> {connection, deadline_ts, timer}
var _pending: Dictionary = {}


func _init(log_buffer: McpLogBuffer = null) -> void:
	_log_buffer = log_buffer


func _has_capture(prefix: String) -> bool:
	return prefix == CAPTURE_PREFIX


func _capture(message: String, data: Array, _session_id: int) -> bool:
	## Godot passes the full "prefix:tail" string as `message`.
	match message:
		"mcp:screenshot_response":
			_on_screenshot_response(data)
			return true
		"mcp:screenshot_error":
			_on_screenshot_error(data)
			return true
		"mcp:hello":
			## Unsolicited boot beacon from the game-side autoload so the
			## editor log buffer can prove the autoload actually loaded
			## and registered, independent of capture requests.
			if _log_buffer:
				_log_buffer.log("[debug] <- mcp:hello from game_helper")
			return true
	return false


## Request a game-process framebuffer capture over the debugger channel.
## Reply is pushed back through `connection` out-of-band because the MCP
## dispatcher has already returned a deferred-response marker for this
## request_id.
func request_game_screenshot(
	request_id: String,
	max_resolution: int,
	connection: Connection,
	timeout_sec: float = DEFAULT_TIMEOUT_SEC,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: screenshot request missing request_id")
		return

	var session: EditorDebuggerSession = _first_active_session()
	if session == null:
		_send_error(connection, request_id, McpErrorCodes.INTERNAL_ERROR,
			"No active debugger session — is the game actually running and started from this editor?")
		return

	_pending[request_id] = {"connection": connection}
	## MainLoop has no create_timer — it's a SceneTree method. We're inside
	## the editor, where the main loop is always a SceneTree, but GDScript's
	## static typing still needs the cast. `create_timer` doesn't declare a
	## return type in the engine bindings we see, so type `timer` explicitly
	## rather than inferring.
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var timer: SceneTreeTimer = tree.create_timer(timeout_sec)
		timer.timeout.connect(func() -> void: _on_timeout(request_id))
		_pending[request_id]["timer"] = timer

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

	var connection: Connection = pending.connection
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
	var connection: Connection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, McpErrorCodes.INTERNAL_ERROR, message)


func _on_timeout(request_id: String) -> void:
	var pending = _pending.get(request_id)
	if pending == null:
		return
	_pending.erase(request_id)
	var connection: Connection = pending.connection
	if connection == null or not is_instance_valid(connection):
		return
	_send_error(connection, request_id, McpErrorCodes.INTERNAL_ERROR,
		"Game screenshot timed out. The running game must include the _mcp_game_helper autoload (added automatically when the plugin is enabled — check Project Settings → Autoload). If the autoload is missing, re-enable the plugin and relaunch the game. For headless or custom-main-loop builds, use source='viewport' instead.")
	if _log_buffer:
		_log_buffer.log("[debug] !! screenshot timeout (%s)" % request_id)


func _send_error(connection: Connection, request_id: String, code: String, message: String) -> void:
	if connection == null or not is_instance_valid(connection):
		return
	var err := McpErrorCodes.make(code, message)
	connection.send_deferred_response(request_id, err)


func _clear_pending(request_id: String) -> void:
	_pending.erase(request_id)
