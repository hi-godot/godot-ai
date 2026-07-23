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
## Mirror of the server's application close code for a handshake carrying a
## wrong auth token (#690; `websocket.py::_CLOSE_CODE_AUTH_TOKEN_MISMATCH`).
const CLOSE_CODE_AUTH_TOKEN_MISMATCH := 4003
## After this many consecutive post-OPEN token-mismatch rejections, drop the
## token and handshake token-less (see `_note_post_open_close`). Two, not
## one: a transient stale-record race during a server swap gets one chance
## to resolve before the token is given up.
const AUTH_MISMATCH_FALLBACK_CLOSES := 2
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Emitted whenever the underlying WebSocket open/closed state flips.
## Subscribers (e.g. the plugin-side telemetry helper) use this to drain
## events that were enqueued before the socket was ready. Emitted with
## ``true`` on first OPEN per connect, ``false`` on transition to CLOSED
## (including ``disconnect_from_server()``).
signal connection_state_changed(is_open: bool)

var _peer := WebSocketPeer.new()
## Seeded by plugin.gd from the configured EditorSettings port before the
## first dial, then republished with the fully resolved port once the
## deferred startup walk (#678) finishes resolving/spawning. Each connect
## attempt recomputes the URL from the latest value, so reconnects keep
## dialing the port the Python server was asked to bind.
var ws_port := ClientConfigurator.DEFAULT_WS_PORT
## Per-launch handshake auth token (#690). Set by plugin.gd from the value
## it generated for the server spawn (also persisted in the managed-server
## editor-settings record so a reloaded plugin instance adopting the same
## server keeps sending it). Empty means "don't send the field" — servers
## we didn't spawn (dev servers, older servers) have no token to match.
var auth_token := ""
var _url := ""
var _connected := false
var _reconnect_attempt := 0
var _reconnect_timer := 0.0
## One pre-OPEN failure diagnostic per WebSocketPeer. Without this guard the
## CLOSED state is polled every frame and would flood the editor log.
var _preopen_failure_logged_for_peer := false
var _session_id := ""
## Consecutive post-OPEN closes with CLOSE_CODE_AUTH_TOKEN_MISMATCH. NOT
## reset by `_clear_on_disconnect` — the streak is counted exactly at the
## close events it exists to observe, across reconnect attempts. Reset on
## any other close code and on a successful `handshake_ack`.
var _auth_mismatch_closes := 0
## Godot-AI Python package version reported by the server in its `handshake_ack`
## reply. Empty until the ack lands. Older servers (pre-handshake_ack) leave
## this empty forever — callers that gate on it (the dock's mismatch banner)
## must treat empty as "unknown, don't raise a false alarm".
var server_version := ""

var dispatcher
var log_buffer
var surfaced_error_tracker
## Set by plugin.gd. Lets the per-frame play-state poll end game-run
## bookkeeping when the game exits on its own (self-quit, crash) — the
## debugger session's stopped signal is not reliably connected, and no MCP
## stop op runs in that path (#642).
var debugger_plugin
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
	## Symmetric inbound bump (#690): the server sends up to 4 MB
	## (websocket.py max_size), but Godot's inbound default is 64 KB — a
	## large script/text write or batch_execute payload used to overflow
	## the peer buffer, drop the frame, and surface as an opaque 5s
	## timeout + reconnect with no error naming the size.
	_peer.inbound_buffer_size = OUTBOUND_BUFFER_LIMIT_BYTES
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
	## Run-stop bookkeeping must not wait behind the socket-state machine:
	## if the game stops while disconnected, the first command drained on
	## reconnect would still observe stale "live" state (PR #642 review).
	_check_game_run_play_state(EditorInterface.is_playing_scene())

	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_attempt = 0
				log_buffer.log("connected to server")
				_send_handshake()
				## Reset the edge detectors so the next _check_state_changes
				## tick re-emits any non-default scene/play state — the
				## handshake carries readiness only, so without this a
				## (re)connected server never learns the current scene.
				_last_scene_path = ""
				_last_play_state = false
				connection_state_changed.emit(true)

			_drain_inbound_packets(_peer)

			_check_state_changes()

			if dispatcher:
				for response in dispatcher.tick():
					_send_json(response)

		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				## This peer reached OPEN, so its one close diagnostic is the
				## post-OPEN line below. Mark the peer consumed; otherwise a
				## stale reconnect delay leaves it in CLOSED for another frame
				## and the pre-OPEN branch emits a mislabeled duplicate.
				_preopen_failure_logged_for_peer = true
				_clear_on_disconnect()
				var code := _peer.get_close_code()
				var reason := _peer.get_close_reason()
				log_buffer.log(_close_diagnostic(true, code, reason, _url))
				_note_post_open_close(code)
				connection_state_changed.emit(false)
			elif not _preopen_failure_logged_for_peer:
				_preopen_failure_logged_for_peer = true
				## Initial failure is attempt 1 for diagnostics. Later failures
				## follow the same first-five/each-tenth throttle as reconnect
				## progress so a missing listener stays observable but bounded.
				var failed_attempt := maxi(1, _reconnect_attempt)
				if _should_log_reconnect_attempt(failed_attempt):
					log_buffer.log(_close_diagnostic(
						false,
						_peer.get_close_code(),
						_peer.get_close_reason(),
						_url
					))
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
		## This peer reached OPEN and is being closed deliberately, so neither
		## the post-OPEN nor pre-OPEN close diagnostic applies. Consume its one
		## diagnostic before the CLOSED tick observes the pre-cleared flag.
		_preopen_failure_logged_for_peer = true
		## Pre-clearing _connected makes the STATE_CLOSED branch skip its
		## _clear_on_disconnect() — run it here so deliberate closes don't
		## leak the old server's version/deferred state into the next one.
		_clear_on_disconnect()
		connection_state_changed.emit(false)


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
		## Queued-but-unexecuted commands from the dead connection must not
		## run under the next one (#712): their requester's futures were
		## already failed server-side, so executing them after reconnect is
		## an uncorrelatable surprise write.
		dispatcher.clear_command_queue()


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
	_preopen_failure_logged_for_peer = false
	_peer.outbound_buffer_size = OUTBOUND_BUFFER_LIMIT_BYTES
	## Keep the reconnect peer symmetric with _ready()'s (#690).
	_peer.inbound_buffer_size = OUTBOUND_BUFFER_LIMIT_BYTES
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


static func _close_diagnostic(
	reached_open: bool,
	code: int,
	reason: String,
	url: String
) -> String:
	var phase := "disconnected after OPEN" if reached_open else "connection failed before OPEN"
	var reason_label := reason.strip_edges()
	if reason_label.is_empty():
		reason_label = "<none>"
	else:
		reason_label = reason_label.replace("\r", "\\r").replace("\n", "\\n")
	return "%s (code %d, reason %s, url %s)" % [phase, code, reason_label, url]


## Token-mismatch fallback (#690 follow-up). The server's auth token is
## fixed for its whole launch, so redialing with the same wrong token can
## never succeed — without this the reconnect loop 4003s forever. The
## reproduced multi-editor failure: a duplicate spawn overwrites the shared
## managed-server record with its fresh token, dies unable to bind, and
## this editor is left holding a token the surviving server never saw.
## After AUTH_MISMATCH_FALLBACK_CLOSES consecutive rejections, drop to a
## token-less handshake, which the server accepts by design (older plugins
## and adopted servers have no token, and the field is attacker-omittable —
## see websocket.py; omitting it gives up no security). Scope note: only
## this connection's copy of the token is dropped — the plugin static and
## the persisted record heal via the startup walk's adoption arms.
func _note_post_open_close(code: int) -> void:
	if code != CLOSE_CODE_AUTH_TOKEN_MISMATCH or auth_token.is_empty():
		_auth_mismatch_closes = 0
		return
	_auth_mismatch_closes += 1
	if _auth_mismatch_closes < AUTH_MISMATCH_FALLBACK_CLOSES:
		return
	auth_token = ""
	_auth_mismatch_closes = 0
	if log_buffer:
		log_buffer.log(
			"auth token rejected %d times (close code %d) — retrying with a token-less handshake"
			% [AUTH_MISMATCH_FALLBACK_CLOSES, CLOSE_CODE_AUTH_TOKEN_MISMATCH]
		)


func _log_blocked_notice_once() -> void:
	if _blocked_notice_logged:
		return
	_blocked_notice_logged = true
	if log_buffer and not connect_block_reason.is_empty():
		log_buffer.log(connect_block_reason)


func _send_handshake() -> void:
	_last_readiness = get_readiness()
	_send_json(_build_handshake())


## Split from _send_handshake so tests can assert the payload shape
## without a live WebSocket peer.
func _build_handshake() -> Dictionary:
	var payload := {
		"type": "handshake",
		"session_id": _session_id,
		"godot_version": Engine.get_version_info().get("string", "unknown"),
		"project_path": ProjectSettings.globalize_path("res://"),
		"plugin_version": ClientConfigurator.get_plugin_version(),
		"protocol_version": 1,
		"readiness": _last_readiness,
		"editor_pid": OS.get_process_id(),
		"server_launch_mode": ClientConfigurator.get_server_launch_mode(),
	}
	## Omit rather than send "" — the server treats an ABSENT token as a
	## compat-accepted older plugin, but a PRESENT wrong one as hostile.
	if not auth_token.is_empty():
		payload["auth_token"] = auth_token
	return payload


## Classify one raw inbound frame. Shared by the normal dispatch path
## (`_handle_message`, which enqueues commands) and the exclusive-run
## service path (`_service_handle_message`, which rejects them) — one
## parser, two sinks, so the paths can't drift. `kind` is one of:
## "ack", "command", "malformed_command", "ignore".
func _classify_message(raw: String) -> Dictionary:
	var parsed = JSON.parse_string(raw)
	if parsed == null:
		push_warning("MCP: failed to parse message: %s" % raw)
		return {"kind": "ignore", "parsed": null}
	if not (parsed is Dictionary):
		return {"kind": "ignore", "parsed": null}
	if parsed.get("type", "") == "handshake_ack":
		return {"kind": "ack", "parsed": parsed}
	if parsed.has("request_id") and parsed.has("command"):
		if (
			parsed.get("request_id") is String
			and parsed.get("command") is String
			and (not parsed.has("params") or parsed.get("params") is Dictionary)
		):
			return {"kind": "command", "parsed": parsed}
		return {"kind": "malformed_command", "parsed": parsed}
	return {"kind": "ignore", "parsed": parsed}


func _handle_message(raw: String) -> void:
	var classified := _classify_message(raw)
	match classified["kind"]:
		"ack":
			_handle_handshake_ack(classified["parsed"])
		"command":
			if dispatcher:
				dispatcher.enqueue(classified["parsed"])
		"malformed_command":
			_reply_malformed_command(classified["parsed"])


func _handle_handshake_ack(parsed: Dictionary) -> void:
	server_version = str(parsed.get("server_version", ""))
	## The server accepted our handshake — any token-mismatch streak is
	## over; a later unrelated 4003 starts a fresh one.
	_auth_mismatch_closes = 0


## Never enqueue a malformed command frame: the dispatcher's typed casts
## would error on the queue head every tick, wedging every later command
## behind it. Reply with an error when the request_id is usable so the
## server's pending future resolves instead of waiting out the full
## command timeout.
func _reply_malformed_command(parsed: Dictionary) -> void:
	push_warning("MCP: dropping malformed command frame (request_id/command must be String, params a Dictionary)")
	var rid: Variant = parsed.get("request_id")
	if rid is String and not String(rid).is_empty():
		var response := ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Malformed command frame: request_id/command must be strings and params a dict"
		)
		response["request_id"] = rid
		response["readiness"] = get_readiness()
		_stamp_error_watermark(response)
		_send_json(response)


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
	## Symmetric with McpDispatcher::_dispatch — stamp live readiness on the
	## deferred reply so the server's session cache self-heals from any
	## response, not just the synchronous ones. Lets `project_stop` (the
	## main deferred-response producer) stay correct even if its bespoke
	## `readiness_after` payload field were ever dropped.
	if not response.has("readiness"):
		response["readiness"] = get_readiness()
	if not response.has("error_watermark"):
		_stamp_error_watermark(response)
	if _send_json(response) and dispatcher != null:
		dispatcher.complete_deferred_response(request_id)


## Result of one cooperative transport-servicing pass during an exclusive
## synchronous run (currently only the test runner). PAUSED is an
## invariant violation for callers, not a healthy state: a pause held
## across servicing checkpoints would silently starve the heartbeat.
enum ServiceStatus { SERVICED, DISCONNECTED, PAUSED, BLOCKED }

## Cumulative cap on application packets processed across ONE exclusive
## run. Counts every drained packet — valid command, malformed frame, or
## ack-like — so no frame kind evades it. Past the cap the connection is
## closed (1013): bounded rejects, never unbounded stale buffering. 2048
## leaves headroom under Godot's default max_queued_packets (4096) and
## sits above stormtest's ~1000-call default workload; tune with
## telemetry/benchmarks if rejection traffic ever extends a checkpoint.
const EXCLUSIVE_RUN_PACKET_CAP := 2048
const CLOSE_CODE_EXCLUSIVE_RUN_FLOOD := 1013
## Reject-log throttle: first few rejects verbatim, then periodic totals.
const _SERVICE_REJECT_LOG_FIRST := 5
const _SERVICE_REJECT_LOG_EVERY := 100

## Service the WebSocket transport from inside a long synchronous handler
## (an "exclusive run" — the test runner). The editor main thread is
## blocked, so `_process` cannot poll; without this the server keepalive
## (20s ping interval / 20s timeout) closes the session mid-run. See
## docs/test-run-transport-starvation-plan.md.
##
## Contract — do NOT extend this method to dispatch:
## - `WebSocketPeer.poll()` has no heartbeat-only mode; it also buffers
##   application frames. Buffering them past this call would replay them
##   STALE after their server-side futures expire (the #712 hazard), so
##   every drained command frame is REJECTED immediately with a retryable
##   EDITOR_NOT_READY / EDITOR_TEST_RUNNING error instead.
## - Drains to quiescence: poll → drain everything available → poll again,
##   until no packets remain. A full packet queue could hide a ping deeper
##   in the TCP stream, so nothing may spill to a later checkpoint.
## - `run_state` is caller-owned mutable state carrying the cumulative
##   packet counter under "packets_serviced" — no connection-global
##   lifecycle that could leak if the run dies.
func service_transport_during_exclusive_run(run_state: Dictionary) -> ServiceStatus:
	if connect_blocked:
		return ServiceStatus.BLOCKED
	if pause_processing:
		return ServiceStatus.PAUSED
	while true:
		_peer.poll()
		if _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			return ServiceStatus.DISCONNECTED
		if _peer.get_available_packet_count() == 0:
			return ServiceStatus.SERVICED
		while _peer.get_available_packet_count() > 0:
			var raw: String = _peer.get_packet().get_string_from_utf8()
			if _service_note_packet(run_state):
				if log_buffer:
					log_buffer.log(
						"[busy] packet flood during test run (%d > cap %d) — closing connection"
						% [int(run_state.get("packets_serviced", 0)), EXCLUSIVE_RUN_PACKET_CAP]
					)
				_peer.close(CLOSE_CODE_EXCLUSIVE_RUN_FLOOD, "command flood during test run")
				return ServiceStatus.DISCONNECTED
			_service_handle_message(raw, int(run_state.get("packets_serviced", 0)))
	## Unreachable: every exit above returns. Keeps the typed signature happy.
	return ServiceStatus.SERVICED


## Shared between-phase checkpoint for exclusive runs: deadline first
## (cheap), then transport servicing via `service_cb`. Returns "" to
## continue, or a terminal outcome: "timeout" | "transport_lost" |
## "paused". Static and stateless so the runner's between-test checkpoints
## and the handler's discovery checkpoints share ONE outcome mapping —
## PAUSED is abort-worthy (a held pause would silently skip every later
## poll and starve the heartbeat), and DISCONNECTED/BLOCKED both mean "no
## live transport".
static func exclusive_run_checkpoint(
	service_cb: Callable, deadline_ticks_ms: int, run_state: Dictionary
) -> String:
	if deadline_ticks_ms > 0 and Time.get_ticks_msec() >= deadline_ticks_ms:
		return "timeout"
	if not service_cb.is_valid():
		return ""
	var status: int = service_cb.call(run_state)
	if status == ServiceStatus.SERVICED:
		return ""
	if status == ServiceStatus.PAUSED:
		return "paused"
	return "transport_lost"


## Count one application packet against the exclusive-run cap. Counts EVERY
## drained packet regardless of kind (valid command, malformed, ack-like)
## so no frame kind can evade the flood limit. Returns true once the cap is
## exceeded — the caller closes the connection.
static func _service_note_packet(run_state: Dictionary) -> bool:
	var count: int = int(run_state.get("packets_serviced", 0)) + 1
	run_state["packets_serviced"] = count
	return count > EXCLUSIVE_RUN_PACKET_CAP


## Exclusive-run sink for `_classify_message`: acks are still processed,
## malformed frames keep their normal reply, and valid commands are
## rejected without touching the dispatcher.
func _service_handle_message(raw: String, packets_serviced: int) -> void:
	var classified := _classify_message(raw)
	match classified["kind"]:
		"ack":
			_handle_handshake_ack(classified["parsed"])
		"command":
			_service_reject_command(classified["parsed"], packets_serviced)
		"malformed_command":
			_reply_malformed_command(classified["parsed"])


func _service_reject_command(parsed: Dictionary, packets_serviced: int) -> void:
	_send_json(_build_service_reject(parsed))
	if log_buffer and (
		packets_serviced <= _SERVICE_REJECT_LOG_FIRST
		or packets_serviced % _SERVICE_REJECT_LOG_EVERY == 0
	):
		## Ring-buffer only (echo=false): a flood must not bury the console.
		log_buffer.log(
			"[busy] rejected '%s' during test run (packet %d)"
			% [parsed.get("command", ""), packets_serviced],
			false,
		)


## Build the busy-reject response for a valid command frame that arrived
## mid-run. Split from the send so tests can assert the exact wire shape.
func _build_service_reject(parsed: Dictionary) -> Dictionary:
	var command: String = parsed.get("command", "")
	var response := ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_TEST_RUNNING,
		(
			"A test run is in progress on this editor — '%s' was not executed. "
			+ "Retry when the run completes, or fetch results afterward with "
			+ "test_manage(op=\"results_get\")."
		) % command,
		true,
	)
	response["request_id"] = parsed.get("request_id", "")
	response["readiness"] = get_readiness()
	_stamp_error_watermark(response)
	return response


func _hook_editor_signals() -> void:
	# Scene change: poll in _process since there's no direct signal for scene switch
	# Play state: EditorInterface signals
	EditorInterface.get_editor_settings()  # ensure interface is ready
	_last_scene_path = _get_current_scene_path()
	_last_play_state = EditorInterface.is_playing_scene()
	_last_play_state_for_run = _last_play_state


var _last_scene_path := ""
var _last_play_state := false
## Separate edge tracker for game-run bookkeeping: _last_play_state only
## advances when the play_state_changed event sends successfully, but ending
## run tracking must not depend on the websocket being up.
var _last_play_state_for_run := false
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
				## echo=false: readiness flips on every filesystem scan
				## (each import cycles importing -> ready), so echoing to
				## console spams every install during normal editing (#626).
				## The line stays in the ring for the dock's log panel.
				log_buffer.log("[event] readiness -> %s" % readiness, false)


## Playing→stopped edge for game-run bookkeeping. Runs every process tick
## (any socket state) so a self-quit game's run ends even while the
## transport is down or reconnecting.
func _check_game_run_play_state(playing: bool) -> void:
	if playing == _last_play_state_for_run:
		return
	if not playing and debugger_plugin != null:
		debugger_plugin.note_editor_play_stopped()
	_last_play_state_for_run = playing


func _get_current_scene_path() -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	return scene_root.scene_file_path if scene_root else ""


func _send_json(data: Dictionary) -> bool:
	if not _connected:
		return false
	var text := JSON.stringify(data)
	var buffered_bytes := _peer.get_current_outbound_buffered_amount()
	## `send_text` encodes the string to UTF-8 internally, so an exact
	## `to_utf8_buffer().size()` here would encode every payload twice. Almost
	## all payloads sit far below the limit, so gate on a cheap upper bound
	## (<= 4 UTF-8 bytes per code point) and only pay for the exact count when
	## the estimate lands near the backpressure ceiling.
	if _might_exceed_outbound_backpressure(buffered_bytes, text.length()):
		var message_bytes := text.to_utf8_buffer().size()
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


## Cheap pre-check on the code-point count: UTF-8 uses at most 4 bytes per code
## point, so `char_count * 4` upper-bounds the encoded size. When even that
## upper bound fits under the ceiling the payload is definitely safe and we can
## skip the exact encode; only a positive here warrants `to_utf8_buffer()`.
static func _might_exceed_outbound_backpressure(buffered_bytes: int, char_count: int) -> bool:
	return buffered_bytes + char_count * 4 > OUTBOUND_BUFFER_LIMIT_BYTES


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
	_stamp_error_watermark(err_response)
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
		## Stamp readiness on the backpressure error too — the server's
		## per-response self-heal applies to every response shape the
		## plugin emits, and the next legitimate reply may already be
		## queued behind this one.
		"readiness": get_readiness(),
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


func _stamp_error_watermark(response: Dictionary) -> void:
	McpSurfacedErrorTracker.stamp_watermark(response, surfaced_error_tracker)


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
