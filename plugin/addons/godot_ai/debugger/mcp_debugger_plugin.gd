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
## #490: how long to wait for the game's mcp:eval_compiled beacon before
## concluding the eval source failed to compile. A parse error aborts the
## game-side handler before it can reply, so without this we'd wait the
## full eval timeout for a syntax mistake. reload() of valid source is
## sub-millisecond, so 3s is comfortably clear of false positives.
const EVAL_COMPILE_GRACE_SEC := 3.0
## #490: once an eval compiles, the editor polls the game every this many
## seconds with mcp:eval_check. A backgrounded play-in-editor game has a
## frozen idle loop (no _process / SceneTreeTimer ticks) so it can't
## self-report a runtime error that aborted the eval — but its debugger
## capture callback still answers a probe. The editor's own loop keeps
## ticking, so it drives the poll. 0.35s keeps detection well under a second
## without flooding the channel; most evals reply before the first probe.
const EVAL_PROBE_INTERVAL_SEC := 0.35

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


func _capture(message: String, data: Array, session_id: int) -> bool:
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
			if _game_session_id != -1 and session_id != _game_session_id:
				if _log_buffer:
					_log_buffer.log("[debug] ignored stale mcp:hello from debugger session %d (current %d)" % [session_id, _game_session_id])
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
		"mcp:eval_ack":
			_on_eval_ack(data)
			return true
		"mcp:eval_compiled":
			_on_eval_compiled(data)
			return true
		"mcp:eval_runtime_error":
			_on_eval_runtime_error(data)
			return true
		"mcp:game_command_response":
			_on_game_command_response(data)
			return true
		"mcp:game_command_error":
			_on_game_command_error(data)
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
	## #490: eval requests also carry a compile-grace timer and a runtime probe.
	var grace: SceneTreeTimer = pending.get("grace_timer")
	var gcb: Callable = pending.get("grace_callable", Callable())
	if grace != null and grace.timeout.is_connected(gcb):
		grace.timeout.disconnect(gcb)
	var probe: SceneTreeTimer = pending.get("probe_timer")
	var pcb: Callable = pending.get("probe_callable", Callable())
	if probe != null and probe.timeout.is_connected(pcb):
		probe.timeout.disconnect(pcb)
	_pending.erase(request_id)


## --- game_eval: execute arbitrary GDScript in the running game ---

## Editor-side fallback timer for game_eval. MUST stay above the game-side
## EVAL_TIMEOUT_SEC (8.0) in runtime/game_helper.gd and below the dispatcher's
## game_eval budget (15000 ms) in dispatcher.gd — i.e. game 8s < editor 10s <
## dispatcher 15s. This timer only fires when the game never replies at all,
## and its message (the timeout_callable below) is intentionally generic. Drop
## timeout_sec at/below 8s and it pre-empts the game's actionable "Eval
## exceeded 8s" message — see the TIMEOUT ORDERING note on EVAL_TIMEOUT_SEC.
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
		_clear_pending(request_id)
		var conn: McpConnection = pending_entry.connection
		if conn == null or not is_instance_valid(conn):
			return
		_send_error(conn, request_id, ErrorCodes.INTERNAL_ERROR,
			"Game eval compiled and started running but never returned within %.0fs — the code is likely stuck in an infinite loop or awaiting a signal/timer that never fires. Check logs_read(source='game')." % timeout_sec)
		if _log_buffer:
			_log_buffer.log("[debug] !! eval timeout (%s)" % request_id)
	timer.timeout.connect(timeout_callable)

	## #490: arm the compile-grace timer. _on_eval_grace concludes a parse error
	## only when the game acked the eval (it received the message and started
	## reload()) but never sent mcp:eval_compiled — see there for why a missing
	## ack must NOT be read as a compile error.
	var grace: SceneTreeTimer = tree.create_timer(EVAL_COMPILE_GRACE_SEC)
	var grace_callable := func() -> void: _on_eval_grace(request_id)
	grace.timeout.connect(grace_callable)

	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
		"grace_timer": grace,
		"grace_callable": grace_callable,
		"acked": false,
		"compiled": false,
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


## #490: the game sends this at the top of _handle_eval, BEFORE reload() (so it
## survives a parse-error abort). It positively signals "the game received this
## eval and started compiling it" — letting _on_eval_grace tell a real parse
## error (acked, never compiled) apart from a message the game hasn't serviced
## yet (never acked — main thread blocked by a long frame/load or a CPU-bound
## prior eval).
func _on_eval_ack(data: Array) -> void:
	if data.is_empty():
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	pending_entry["acked"] = true
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_ack (%s)" % request_id)


## #490: compile-grace timer fired. Conclude a parse error ONLY when the game
## acked the eval (started reload()) but never sent mcp:eval_compiled. If it
## never acked, the game simply hasn't serviced the message yet — NOT a parse
## error — so leave _pending intact and let the normal eval timeout handle it
## rather than false-failing a valid eval and dropping its eventual real reply.
func _on_eval_grace(request_id: String) -> void:
	var pending_entry = _pending.get(request_id)
	if pending_entry == null or pending_entry.get("compiled", false):
		return
	if not pending_entry.get("acked", false):
		if _log_buffer:
			_log_buffer.log("[debug] eval grace: no ack yet, deferring to timeout (%s)" % request_id)
		return
	_clear_pending(request_id)
	var conn: McpConnection = pending_entry.connection
	if conn == null or not is_instance_valid(conn):
		return
	_send_error(conn, request_id, ErrorCodes.EVAL_COMPILE_ERROR,
		"Game eval failed to compile — likely a GDScript syntax/parse error. The parse error text is in the editor's Output/Debugger panel; it is not capturable from the running game. Check your eval code's syntax.")
	if _log_buffer:
		_log_buffer.log("[debug] !! eval compile error (%s)" % request_id)


## #490: the game sends this the instant reload() of the eval source
## succeeds. Flips the pending entry's `compiled` flag so the compile-grace
## timer won't fire a false EVAL_COMPILE_ERROR.
func _on_eval_compiled(data: Array) -> void:
	if data.is_empty():
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	pending_entry["compiled"] = true
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_compiled (%s)" % request_id)
	## #490: compiled OK — start polling for a runtime error that may have
	## aborted execute(). A backgrounded game can't self-report it, so the
	## editor probes via mcp:eval_check until the eval resolves.
	_arm_eval_probe(request_id)


## #490: the game reported a runtime error that aborted the eval — either
## from its _process fast path (focused game) or in answer to an editor
## eval_check probe (backgrounded game). Reply fast with the real error text
## instead of waiting for the hang timeout.
func _on_eval_runtime_error(data: Array) -> void:
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
	var msg := "Game eval raised a runtime error: %s" % message if not message.is_empty() else "Game eval raised a runtime error (no message captured). Check logs_read(source='game')."
	_send_error(connection, request_id, ErrorCodes.EVAL_RUNTIME_ERROR, msg)
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:eval_runtime_error (%s): %s" % [request_id, message])


## #490: arm one probe tick for an in-flight eval. Re-arms itself each tick
## until the request resolves — eval_response / eval_runtime_error /
## eval_compile_error / hang-timeout all call _clear_pending, which erases the
## entry and stops the chain. Uses the editor's own SceneTreeTimer because the
## editor loop keeps ticking even while a backgrounded game's loop is frozen.
func _arm_eval_probe(request_id: String) -> void:
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var probe_timer: SceneTreeTimer = tree.create_timer(EVAL_PROBE_INTERVAL_SEC)
	var probe_callable := func() -> void: _on_eval_probe_tick(request_id)
	pending_entry["probe_timer"] = probe_timer
	pending_entry["probe_callable"] = probe_callable
	probe_timer.timeout.connect(probe_callable)


## #490: poke the game for a runtime-error verdict, then re-arm. The game's
## _handle_eval_check answers with mcp:eval_runtime_error if a script error
## aborted this eval, else stays silent and we poll again next interval.
func _on_eval_probe_tick(request_id: String) -> void:
	if not _pending.has(request_id):
		return  ## resolved — stop probing
	var session: EditorDebuggerSession = _first_active_session()
	if session != null and session.is_active():
		session.send_message("mcp:eval_check", [request_id])
	_arm_eval_probe(request_id)


## --- game_command: curated runtime game operations ---

func request_game_command(
	op: String,
	params: Dictionary,
	request_id: String,
	connection: McpConnection,
	timeout_sec: float = 10.0,
) -> void:
	if request_id.is_empty():
		push_warning("MCP debugger: game command request missing request_id")
		return

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_send_error(connection, request_id, ErrorCodes.INTERNAL_ERROR,
			"Editor main loop is not a SceneTree — cannot schedule game command")
		return

	if is_game_capture_ready():
		_send_game_command(tree, op, params, request_id, connection, timeout_sec)
		return

	if _log_buffer:
		_log_buffer.log("[debug] waiting for game_helper hello before game_command (%s)" % request_id)
	_wait_then_game_command(tree, op, params, request_id, connection, timeout_sec)


func _wait_then_game_command(
	tree: SceneTree,
	op: String,
	params: Dictionary,
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
	_send_game_command(tree, op, params, request_id, connection, timeout_sec)


func _send_game_command(
	tree: SceneTree,
	op: String,
	params: Dictionary,
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
			"Game command '%s' timed out after %.0fs" % [op, timeout_sec])
		if _log_buffer:
			_log_buffer.log("[debug] !! game_command timeout (%s)" % request_id)
	timer.timeout.connect(timeout_callable)
	_pending[request_id] = {
		"connection": connection,
		"timer": timer,
		"timeout_callable": timeout_callable,
	}

	session.send_message("mcp:game_command", [request_id, op, JSON.stringify(params)])
	if _log_buffer:
		_log_buffer.log("[debug] -> mcp:game_command %s (%s)" % [op, request_id])


func _on_game_command_response(data: Array) -> void:
	if data.size() < 2:
		push_warning("MCP debugger: malformed game_command response (expected 2 fields, got %d)" % data.size())
		return
	var request_id: String = data[0]
	var pending_entry = _pending.get(request_id)
	if pending_entry == null:
		return
	_clear_pending(request_id)

	var connection: McpConnection = pending_entry.connection
	if connection == null or not is_instance_valid(connection):
		return

	var result_json: String = data[1] if data.size() > 1 else "{}"
	var json := JSON.new()
	var parse_err := json.parse(result_json)
	connection.send_deferred_response(request_id, {
		"data": json.data if parse_err == OK else {"source": "game", "result": result_json}
	})
	if _log_buffer:
		_log_buffer.log("[debug] <- mcp:game_command_response (%s)" % request_id)


func _on_game_command_error(data: Array) -> void:
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
		_log_buffer.log("[debug] <- mcp:game_command_error (%s): %s" % [request_id, message])
