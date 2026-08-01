@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Tests for McpConnection._make_session_id / _slugify — session ID format.


func suite_name() -> String:
	return "connection"


# ----- slug format -----

func test_make_session_id_uses_project_directory_name() -> void:
	var sid := McpConnection._make_session_id("/Users/foo/My Game/")
	var parts := sid.split("@")
	assert_eq(parts.size(), 2, "SID should be '<slug>@<hex>'")
	assert_eq(parts[0], "my-game")
	assert_eq(parts[1].length(), 4, "suffix should be 4 hex chars")
	for c in parts[1]:
		assert_true(
			(c >= "0" and c <= "9") or (c >= "a" and c <= "f"),
			"suffix char %s is not hex" % c,
		)


func test_make_session_id_handles_no_trailing_slash() -> void:
	var sid := McpConnection._make_session_id("/Users/foo/My Game")
	var parts := sid.split("@")
	assert_eq(parts[0], "my-game")


func test_make_session_id_empty_path_falls_back_to_project() -> void:
	var sid := McpConnection._make_session_id("")
	var parts := sid.split("@")
	assert_eq(parts[0], "project")
	assert_eq(parts[1].length(), 4)


func test_make_session_id_only_slashes_falls_back_to_project() -> void:
	var sid := McpConnection._make_session_id("///")
	var parts := sid.split("@")
	assert_eq(parts[0], "project")


func test_make_session_id_randomizes_suffix() -> void:
	var seen := {}
	for i in range(32):
		var sid := McpConnection._make_session_id("/Users/x/game/")
		seen[sid] = true
	## Avoid a flaky two-sample comparison: collect many IDs and verify
	## the suffix is not constant across repeated calls for the same path.
	assert_true(seen.size() > 1, "suffix should vary across repeated calls")


# ----- slugify -----

func test_slugify_lowercases() -> void:
	assert_eq(McpConnection._slugify("MyGame"), "mygame")


func test_slugify_collapses_punctuation_to_dashes() -> void:
	assert_eq(McpConnection._slugify("My Awesome_Game!"), "my-awesome-game")


func test_slugify_strips_leading_and_trailing_punctuation() -> void:
	assert_eq(McpConnection._slugify("  Hello World  "), "hello-world")
	assert_eq(McpConnection._slugify("!!!game!!!"), "game")


func test_slugify_preserves_alphanumeric() -> void:
	assert_eq(McpConnection._slugify("level42"), "level42")


func test_slugify_empty_returns_empty() -> void:
	assert_eq(McpConnection._slugify(""), "")
	assert_eq(McpConnection._slugify("!!!"), "")


# ----- handshake_ack parsing -----
#
# The server's handshake_ack reply carries the TRUE running server version so
# the dock's Setup-section "Server" line can stop lying about the plugin's
# expected version and instead flag self-update drift. McpConnection parses the
# ack in `_handle_message` and stashes the version on `server_version`.


func test_build_handshake_omits_auth_token_when_empty() -> void:
	## #690: empty token means "we have no secret" (dev server, older
	## server, external adoption) — the field must be ABSENT, not "", so
	## the server takes the compat-accept path instead of comparing "".
	var conn := McpConnection.new()
	var payload := conn._build_handshake()
	assert_false(payload.has("auth_token"), "empty token must omit the field entirely")
	assert_eq(payload.get("type"), "handshake")
	conn.free()


func test_build_handshake_includes_auth_token_when_set() -> void:
	var conn := McpConnection.new()
	conn.auth_token = "per-launch-secret"
	var payload := conn._build_handshake()
	assert_eq(payload.get("auth_token"), "per-launch-secret")
	conn.free()


# ----- 4003 auth-token-mismatch fallback -----
#
# The server's token is fixed per launch, so redialing with the same wrong
# token can never succeed — the reproduced multi-editor duplicate-spawn left
# an editor 4003-looping forever. After repeated rejections the connection
# must fall back to a token-less handshake, which the server accepts by
# design (#690).


func test_auth_mismatch_fallback_drops_token_after_repeated_4003() -> void:
	var conn := McpConnection.new()
	conn.auth_token = "stale-token"

	var first := conn._note_post_open_close(McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH)
	assert_eq(conn.auth_token, "stale-token",
		"one rejection may be a transient swap race — keep the token")
	assert_eq(first.get("reason_code"), "auth_token_mismatch")
	assert_eq(first.get("occurrence"), 1)
	assert_eq(first.get("recovery_action"), "retry_authenticated")

	var second := conn._note_post_open_close(McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH)
	assert_eq(conn.auth_token, "",
		"repeated 4003 must fall back to a token-less handshake")
	assert_eq(second.get("reason_code"), "auth_token_mismatch")
	assert_eq(second.get("occurrence"), 2)
	assert_eq(second.get("recovery_action"), "retry_tokenless")

	var payload := conn._build_handshake()
	assert_false(payload.has("auth_token"),
		"fallback handshake must omit the token field entirely")
	conn.free()


func test_auth_mismatch_streak_resets_on_other_close_codes() -> void:
	var conn := McpConnection.new()
	conn.auth_token = "per-launch-secret"

	conn._note_post_open_close(McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH)
	conn._note_post_open_close(1000)
	conn._note_post_open_close(McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH)

	assert_eq(conn.auth_token, "per-launch-secret",
		"non-consecutive rejections must not trigger the fallback")
	conn.free()


func test_auth_mismatch_streak_resets_on_handshake_ack() -> void:
	## Server swap shape: rejected once, then the next server accepted us.
	## A later unrelated 4003 must start a fresh streak, not inherit the
	## pre-ack one.
	var conn := McpConnection.new()
	conn.auth_token = "per-launch-secret"

	conn._transient_diagnostic = conn._note_post_open_close(
		McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH
	)
	conn._handle_message('{"type":"handshake_ack","server_version":"1.0.0"}')
	conn._note_post_open_close(McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH)

	assert_eq(conn.auth_token, "per-launch-secret",
		"an accepted handshake must reset the mismatch streak")
	assert_true(conn._transient_diagnostic.is_empty(),
		"an accepted handshake must clear the healed reconnect reason")
	conn.free()


func test_handle_message_stores_server_version_from_ack() -> void:
	var conn := McpConnection.new()
	assert_eq(conn.server_version, "", "server_version defaults to empty")
	conn._handle_message('{"type":"handshake_ack","server_version":"1.4.2"}')
	assert_eq(conn.server_version, "1.4.2")
	conn.free()


func test_handle_message_ignores_unknown_type() -> void:
	## The dispatcher branch requires both `request_id` and `command` — any
	## other typed message (future protocol additions) must no-op rather
	## than crash, so a newer server can roll additions without requiring
	## a plugin bump.
	var conn := McpConnection.new()
	conn._handle_message('{"type":"future_event","payload":{}}')
	assert_eq(conn.server_version, "", "unknown types must not touch server_version")
	conn.free()


func test_handle_message_survives_malformed_ack() -> void:
	## Forward-compat guard: if a future server sends handshake_ack with no
	## `server_version` field, McpConnection must default to empty instead of
	## crashing on missing-key access.
	var conn := McpConnection.new()
	conn._handle_message('{"type":"handshake_ack"}')
	assert_eq(conn.server_version, "", "missing field must default to empty, not crash")
	conn.free()


func test_disconnect_clears_server_version() -> void:
	## `server_version` must NOT survive a reconnect. `force_restart_server`
	## kills the old process and waits for a new one; if the replacement is
	## an older build without handshake_ack, it never updates the field, so
	## the dock would keep showing the killed server's version. Reproduced
	## live during the PR smoke test (amber "99.0.0-smoke-test" label stayed
	## visible after the Restart successfully swapped in a v1.4.2 server).
	## Clearing on the STATE_CLOSED transition keeps the dock honest.
	var conn := McpConnection.new()
	conn._handle_message('{"type":"handshake_ack","server_version":"1.2.3"}')
	assert_eq(conn.server_version, "1.2.3", "precondition: version stored from ack")
	## Force the STATE_CLOSED branch by flipping `_connected` true and
	## calling `disconnect_from_server`. The real path runs through
	## `_process`, but the observable side-effect we care about
	## (server_version cleared on the true → false flip) is codified
	## directly so a future refactor of _process can't silently break it.
	conn._connected = true
	conn.disconnect_from_server()
	## `disconnect_from_server` itself flips `_connected` but doesn't clear
	## server_version — that happens on the next STATE_CLOSED tick. Simulate
	## that tick directly via the same clearing idiom we use in _process.
	conn._connected = true  # re-arm so the branch will fire
	## Inline the STATE_CLOSED → false transition by calling the private
	## handler the way _process would; assert version cleared afterwards.
	conn._clear_on_disconnect()
	assert_eq(conn.server_version, "", "reconnect must not inherit stale version")
	conn.free()


func test_disconnect_clears_pending_deferred_responses() -> void:
	var conn := McpConnection.new()
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	dispatcher.mcp_logging = false
	dispatcher.register("later", func(_p): return McpDispatcher.DEFERRED_RESPONSE)
	dispatcher.enqueue({
		"request_id": "req-old-socket",
		"command": "later",
		"params": {},
	})
	dispatcher.tick(100.0)
	assert_eq(dispatcher.pending_deferred_count(), 1, "precondition: deferred request is tracked")

	conn.dispatcher = dispatcher
	conn._clear_on_disconnect()

	assert_eq(
		dispatcher.pending_deferred_count(),
		0,
		"reconnect must not inherit pending responses from the previous socket",
	)
	conn.free()


func test_disconnect_clears_queued_commands() -> void:
	## #712: commands queued by the dead connection must not execute under
	## the next one — the requester's futures were already failed
	## server-side, so a mutation landing after reconnect is an
	## uncorrelatable surprise write.
	var conn := McpConnection.new()
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	dispatcher.mcp_logging = false
	var executed: Array = []
	dispatcher.register("mutate", func(_p):
		executed.append(true)
		return {"data": {}})
	dispatcher.enqueue({"request_id": "req-stale", "command": "mutate", "params": {}})

	conn.dispatcher = dispatcher
	conn._clear_on_disconnect()

	var responses := dispatcher.tick(100.0)
	assert_eq(executed.size(), 0, "queued command must not run after disconnect")
	assert_eq(responses.size(), 0, "no responses should be produced for cleared commands")
	conn.free()


func test_send_event_reports_unsent_when_disconnected() -> void:
	var conn := McpConnection.new()
	assert_false(
		conn.send_event("readiness_changed", {"readiness": "ready"}),
		"state-change callers need a false return so they can retry later",
	)
	conn.free()


# ----- reconnect backoff and logging -----


func test_reconnect_delay_caps_at_sixty_seconds() -> void:
	var expected: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 60.0]
	for i in range(expected.size()):
		assert_eq(McpConnection._reconnect_delay_for_attempt(i), expected[i])
	assert_eq(McpConnection._reconnect_delay_for_attempt(7), 60.0)
	assert_eq(McpConnection._reconnect_delay_for_attempt(42), 60.0)


func test_reconnect_transition_logging_includes_initial_attempts() -> void:
	for attempt in range(1, 6):
		assert_true(
			McpConnection._should_log_reconnect_transition(attempt, 1000, 1000),
			"attempt %d should be logged for immediate diagnostics" % attempt,
		)


func test_reconnect_transition_logging_uses_time_heartbeat_after_initial_attempts() -> void:
	assert_false(
		McpConnection._should_log_reconnect_transition(6, 60_999, 1000),
		"later transition inside the one-minute heartbeat should stay quiet",
	)
	assert_true(
		McpConnection._should_log_reconnect_transition(6, 61_000, 1000),
		"later transition should log after one minute regardless of attempt number",
	)
	assert_true(McpConnection._should_log_reconnect_transition(99, 1, -1),
		"the first observed transition should always be visible")


func test_transport_snapshot_distinguishes_connecting_retrying_closing_and_open() -> void:
	var connecting := McpConnection._transport_status_snapshot(
		WebSocketPeer.STATE_CONNECTING, 12.5, 3, 0.0)
	assert_eq(connecting.get("phase"), "connecting")
	assert_eq(connecting.get("attempt"), 3)
	assert_eq(connecting.get("state_elapsed_sec"), 12.5)
	assert_false(connecting.has("retry_in_sec"),
		"an in-flight connection must not advertise a scheduled retry")

	var retrying := McpConnection._transport_status_snapshot(
		WebSocketPeer.STATE_CLOSED, 0.25, 3, 4.5)
	assert_eq(retrying.get("phase"), "retrying")
	assert_eq(retrying.get("retry_in_sec"), 4.5)

	var closing := McpConnection._transport_status_snapshot(
		WebSocketPeer.STATE_CLOSING, 1.0, 3, 4.5)
	assert_eq(closing.get("phase"), "closing")
	assert_false(closing.has("retry_in_sec"))

	var connected := McpConnection._transport_status_snapshot(
		WebSocketPeer.STATE_OPEN, 30.0, 0, 4.5)
	assert_eq(connected.get("phase"), "connected")
	assert_false(connected.has("retry_in_sec"))


func test_transport_status_wrapper_applies_generic_blocked_reason() -> void:
	var conn := McpConnection.new()
	conn.connect_blocked = true
	conn.connect_block_reason = "blocked for test"
	var snapshot := conn.get_transport_status()
	assert_eq(snapshot.get("phase"), "blocked")
	assert_eq(snapshot.get("reason_code"), "connection_blocked")
	assert_eq(snapshot.get("reason"), "blocked for test")
	assert_false(snapshot.has("retry_in_sec"))
	conn.free()


func test_reconnect_diagnostics_keep_preopen_and_postopen_failures_distinct() -> void:
	var preopen := McpConnection._preopen_failure_diagnostic(
		4,
		30.25,
		8.0,
		-1,
		"",
		"ws://127.0.0.1:9500"
	)
	assert_contains(preopen, "connection attempt 4 failed before OPEN after 30.3s")
	assert_contains(preopen, "retrying in 8s")
	assert_contains(preopen, "code -1")
	assert_contains(preopen, "reason <none>")
	assert_contains(preopen, "ws://127.0.0.1:9500")

	var opened := McpConnection._postopen_close_diagnostic(
		3600.0,
		4003,
		"auth\nfailed",
		"ws://127.0.0.1:9500"
	)
	assert_contains(opened, "connection lost after being open for 3600.0s")
	assert_contains(opened, "; reconnecting")
	assert_contains(opened, "code 4003")
	assert_contains(opened, "reason auth\\nfailed")

	var tokenless := McpConnection._postopen_close_diagnostic(
		1.0,
		McpConnection.CLOSE_CODE_AUTH_TOKEN_MISMATCH,
		"token mismatch",
		"ws://127.0.0.1:9500",
		{"occurrence": 2, "recovery_action": "retry_tokenless"},
	)
	assert_contains(tokenless, "token-less handshake (rejection 2/2)",
		"the post-OPEN line must surface the recovery action before the next ack")


func test_post_open_close_does_not_emit_preopen_duplicate() -> void:
	## Regression for #764 review: a peer created by `_attempt_reconnect`
	## retains a positive reconnect timer after reaching OPEN. On a later
	## drop it therefore spends multiple frames in CLOSED before redialing.
	## The first frame's post-OPEN diagnostic must consume the peer so the
	## second frame cannot mislabel the same close as a pre-OPEN failure.
	var conn := McpConnection.new()
	var buffer := McpLogBuffer.new()
	conn.log_buffer = buffer
	conn._url = "ws://127.0.0.1:9500"
	conn._connected = true
	conn._reconnect_timer = 5.0
	conn._preopen_failure_logged_for_peer = false

	## The connection owns a real WebSocketPeer, currently CLOSED. Seed only
	## the prior OPEN bookkeeping and drive the production state machine twice.
	conn._process(0.0)
	conn._process(0.0)

	var lines := buffer.get_recent(10)
	assert_eq(lines.size(), 1, "one CLOSED peer must emit exactly one diagnostic")
	assert_contains(lines[0], "connection lost after being open")
	assert_false(
		lines[0].contains("failed before OPEN"),
		"post-OPEN close must never be relabeled as a pre-OPEN failure"
	)
	conn.free()


func test_deliberate_disconnect_emits_no_close_diagnostic() -> void:
	## `disconnect_from_server` pre-clears `_connected` so deliberate closes
	## stay silent. The CLOSED tick must not reinterpret that established peer
	## as a failed pre-OPEN attempt, including server swaps where
	## `connect_blocked` remains false.
	var conn := McpConnection.new()
	var buffer := McpLogBuffer.new()
	conn.log_buffer = buffer
	conn._url = "ws://127.0.0.1:9500"
	conn._connected = true
	conn._reconnect_timer = 5.0
	conn._preopen_failure_logged_for_peer = false

	conn.disconnect_from_server()
	conn._process(0.0)
	conn._process(0.0)

	assert_eq(buffer.total_count(), 0, "deliberate post-OPEN close must stay silent")
	conn.free()


func test_blocked_connection_logs_once_and_stops_reconnect_loop() -> void:
	## Regression from the stale-server live smoke: blocked adoption logged the
	## actionable warning every reconnect tick because `_attempt_reconnect`
	## returned before resetting the timer. A blocked connection should surface
	## one clear message and then stop processing until the plugin is reloaded.
	var conn := McpConnection.new()
	var buffer := McpLogBuffer.new()
	conn.log_buffer = buffer
	conn.connect_blocked = true
	conn.connect_block_reason = "blocked for test"

	conn._attempt_reconnect()
	conn._attempt_reconnect()

	assert_eq(buffer.total_count(), 1, "blocked reconnect must log once, not every tick")
	assert_eq(buffer.get_recent(1)[0], "MCP | blocked for test")
	assert_false(conn.is_processing(), "blocked reconnect must stop Connection processing")
	conn.free()


# ----- pause depth -----


func test_nested_pause_resume_uses_depth_counter() -> void:
	var conn := McpConnection.new()
	assert_false(conn.pause_processing, "new connection should not start paused")
	assert_eq(conn.pause_depth(), 0)

	conn.pause()
	conn.pause()
	assert_true(conn.pause_processing, "connection should be paused while depth > 0")
	assert_eq(conn.pause_depth(), 2)

	conn.resume()
	assert_true(conn.pause_processing, "first resume must not clear a nested pause")
	assert_eq(conn.pause_depth(), 1)

	conn.resume()
	assert_false(conn.pause_processing, "processing resumes only when depth returns to zero")
	assert_eq(conn.pause_depth(), 0)
	conn.free()


func test_pause_processing_property_preserves_nested_pause_semantics() -> void:
	var conn := McpConnection.new()
	conn.pause_processing = true
	conn.pause_processing = true
	conn.pause_processing = false
	assert_true(conn.pause_processing, "legacy bool setter should decrement one level at a time")
	assert_eq(conn.pause_depth(), 1)
	conn.pause_processing = false
	assert_false(conn.pause_processing)
	assert_eq(conn.pause_depth(), 0)
	conn.free()


# ----- pause depth across disconnect/reconnect -----
#
# Issue #297 PR 4 checklist: "Connection lifecycle round-trip — disconnect
# -> reconnect -> handshake -> first command, with pause/resume interleaved."
# `_clear_on_disconnect` is the choke point that runs once per drop. It
# resets per-server state (server_version, pending deferred responses) but
# MUST NOT touch `_pause_depth`: pauses are owned by handlers (e.g.
# ResourceSaver mid-save in `utils/resource_io.gd`, scene save in
# `scene_handler.gd`). Clearing them on a socket drop would let the next
# `_process` tick resume polling while the editor is still in a re-entrant
# save window — the exact hazard #289 fixed.


func test_clear_on_disconnect_preserves_pause_depth() -> void:
	var conn := McpConnection.new()
	conn.pause()
	conn.pause()
	assert_eq(conn.pause_depth(), 2, "precondition: nested pause depth=2")

	conn._clear_on_disconnect()

	assert_eq(
		conn.pause_depth(), 2,
		"disconnect must leave handler-held pauses intact",
	)
	assert_true(
		conn.pause_processing,
		"_process must keep skipping the WebSocket poll while a save still owns the pause",
	)
	conn.resume()
	conn.resume()
	assert_eq(conn.pause_depth(), 0, "balanced resume drains depth to zero after a disconnect")
	conn.free()


func test_pause_resume_balances_across_repeated_reconnect_cycles() -> void:
	## Disconnect/reconnect cycles call `_clear_on_disconnect` once per
	## drop. Multiple cycles plus pause/resume calls interleaved between
	## them must still balance — depth is the source of truth and only
	## explicit resumes drain it.
	var conn := McpConnection.new()

	conn.pause()  # handler A acquires pause before any drop
	conn._clear_on_disconnect()  # cycle 1: server drops underneath A
	conn.pause()  # handler B starts mid-disconnect (e.g. queued save)
	conn._clear_on_disconnect()  # cycle 2: a second drop while B is mid-save
	assert_eq(
		conn.pause_depth(), 2,
		"both handler-held pauses must survive back-to-back drops",
	)

	conn.resume()  # handler B finishes
	assert_true(conn.pause_processing, "A's pause still gates polling")
	conn.resume()  # handler A finishes
	assert_eq(conn.pause_depth(), 0)
	assert_false(conn.pause_processing, "polling resumes only after every paired resume")
	conn.free()


# ----- outbound backpressure -----


func test_outbound_backpressure_limit_rejects_payload_that_would_overflow() -> void:
	assert_false(McpConnection._would_exceed_outbound_backpressure(0, 1024))
	assert_false(
		McpConnection._would_exceed_outbound_backpressure(
			McpConnection.OUTBOUND_BUFFER_LIMIT_BYTES - 10,
			10,
		)
	)
	assert_true(
		McpConnection._would_exceed_outbound_backpressure(
			McpConnection.OUTBOUND_BUFFER_LIMIT_BYTES - 10,
			11,
		)
	)


func test_might_exceed_uses_worst_case_four_bytes_per_code_point() -> void:
	## The cheap gate must upper-bound the encoded size (<= 4 UTF-8 bytes per
	## code point) so a "safe" verdict is never wrong.
	assert_false(McpConnection._might_exceed_outbound_backpressure(0, 1024))
	# Exact quarter of the limit; the operands are ints, so int-division is
	# intended (the limit is a power of two, so it divides evenly).
	@warning_ignore("integer_division")
	var char_budget := McpConnection.OUTBOUND_BUFFER_LIMIT_BYTES / 4
	assert_false(McpConnection._might_exceed_outbound_backpressure(0, char_budget))
	assert_true(McpConnection._might_exceed_outbound_backpressure(0, char_budget + 1))


func test_might_exceed_is_conservative_relative_to_exact_check() -> void:
	## When the cheap gate says "safe" the exact byte check must agree, because
	## actual UTF-8 bytes can never exceed char_count * 4. Guarding the exact
	## encode behind this gate must not let an overflowing payload slip through.
	var near := McpConnection.OUTBOUND_BUFFER_LIMIT_BYTES - 8
	## 1 code point -> at most 4 bytes, within the 8-byte headroom -> cleared as
	## safe, and the exact check agrees for any real 1..4 byte encoding.
	assert_false(McpConnection._might_exceed_outbound_backpressure(near, 1))
	assert_false(McpConnection._would_exceed_outbound_backpressure(near, 4))
	## 3 code points -> up to 12 bytes, over the 8-byte headroom -> the gate must
	## refuse to clear it so the exact encode still runs.
	assert_true(McpConnection._might_exceed_outbound_backpressure(near, 3))


func test_backpressure_error_is_structured_and_actionable() -> void:
	var err := McpConnection._make_backpressure_error("rid-1", 100, 200)
	assert_eq(err.request_id, "rid-1")
	assert_is_error(err, ErrorCodes.INTERNAL_ERROR)
	assert_has_key(err.error, "data")
	assert_eq(err.error.data.buffered_bytes, 100)
	assert_eq(err.error.data.message_bytes, 200)
	assert_contains(err.error.message, "max_resolution")


# ----- inbound packet drain cap (audit-v2 #12 / issue #356) -----


## Duck-typed stand-in for `WebSocketPeer` exposing only the two methods
## `_drain_inbound_packets` calls. Lets tests queue arbitrary packet counts
## without spinning up a real WebSocket pair.
class _FakeWebSocketPeer extends RefCounted:
	var _packets: Array[PackedByteArray] = []

	func get_available_packet_count() -> int:
		return _packets.size()

	func get_packet() -> PackedByteArray:
		if _packets.is_empty():
			return PackedByteArray()
		return _packets.pop_front()

	func queue_message(s: String) -> void:
		_packets.append(s.to_utf8_buffer())


## A minimal valid message: handshake_ack just stores `server_version` on
## the connection — no dispatcher needed, no side effects beyond a string
## assignment we discard.
const _DRAIN_TEST_MSG := '{"type":"handshake_ack","server_version":"1.0.0"}'


func test_drain_caps_at_PACKET_DRAIN_CAP_PER_TICK() -> void:
	## Pre-fix, the inline `while peer.get_available_packet_count() > 0`
	## drain had no upper bound — a flooding peer or fast batch could
	## blow the documented 4ms _process budget. Now the loop hard-caps
	## at PACKET_DRAIN_CAP_PER_TICK and spills the rest to the next tick.
	var conn := McpConnection.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK + 5):
		peer.queue_message(_DRAIN_TEST_MSG)

	var result := conn._drain_inbound_packets(peer)

	assert_eq(
		result["drained"],
		McpConnection.PACKET_DRAIN_CAP_PER_TICK,
		"drained exactly the per-tick cap",
	)
	assert_eq(result["spilled"], 5, "spilled = queue_size - cap")
	assert_eq(peer.get_available_packet_count(), 5, "5 packets remain on the peer for next tick")
	assert_eq(conn._packet_spillover_total, 5, "spill counter incremented by spillover")
	conn.free()


func test_drain_below_cap_does_not_increment_spillover() -> void:
	## Normal traffic: a handful of packets all drain in one tick, no
	## spillover, counter stays at zero.
	var conn := McpConnection.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(5):
		peer.queue_message(_DRAIN_TEST_MSG)

	var result := conn._drain_inbound_packets(peer)

	assert_eq(result["drained"], 5)
	assert_eq(result["spilled"], 0, "no spillover under the cap")
	assert_eq(peer.get_available_packet_count(), 0, "queue fully drained")
	assert_eq(conn._packet_spillover_total, 0, "counter stays at 0 when no spillover")
	conn.free()


func test_drain_at_exactly_cap_does_not_log_or_count_spillover() -> void:
	## Boundary: exactly cap packets queued, all drain in one tick. The
	## drain hit the cap but nothing remains on the peer — that's NOT a
	## flood signal and must not log or bump the counter.
	var conn := McpConnection.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK):
		peer.queue_message(_DRAIN_TEST_MSG)

	var result := conn._drain_inbound_packets(peer)

	assert_eq(result["drained"], McpConnection.PACKET_DRAIN_CAP_PER_TICK)
	assert_eq(result["spilled"], 0, "exactly cap == nothing left to spill")
	assert_eq(conn._packet_spillover_total, 0, "boundary case must not flag spillover")
	conn.free()


func test_drain_spillover_accumulates_across_ticks() -> void:
	## A sustained flood is multiple consecutive ticks each spilling. The
	## cumulative counter grows tick-over-tick so `logs_read` operators
	## can see the flood pattern, not just a single line.
	var conn := McpConnection.new()
	var peer := _FakeWebSocketPeer.new()

	# Tick 1: cap+10 queued → drain cap, 10 spilled.
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK + 10):
		peer.queue_message(_DRAIN_TEST_MSG)
	conn._drain_inbound_packets(peer)
	assert_eq(conn._packet_spillover_total, 10, "tick 1: 10 spilled")

	# Tick 2: 10 already on peer (from tick 1's spillover) + cap-9 fresh
	# queued = cap+1 total → drain cap, 1 spilled.
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK - 9):
		peer.queue_message(_DRAIN_TEST_MSG)
	conn._drain_inbound_packets(peer)
	assert_eq(
		conn._packet_spillover_total,
		11,
		"tick 2: counter grows by tick-2's spillover (1), not reset",
	)
	conn.free()


func test_drain_logs_spillover_line_when_cap_hit_and_packets_remain() -> void:
	## The issue's "Fix shape" calls out observability: flood patterns
	## must surface in `logs_read`. Pin the log emission so a future
	## refactor can't silently drop it.
	var conn := McpConnection.new()
	conn.log_buffer = McpLogBuffer.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK + 7):
		peer.queue_message(_DRAIN_TEST_MSG)

	conn._drain_inbound_packets(peer)

	# `conn.log_buffer` is declared as untyped on McpConnection (the field's
	# initial value is null), so the inferred return type of `.get_recent`
	# is Variant. Annotate explicitly — `:=` raises a parse error otherwise.
	var lines: Array = conn.log_buffer.get_recent(50)
	var matched := false
	for line in lines:
		var s := str(line)
		if s.find("[backpressure] inbound drain capped") >= 0:
			assert_contains(s, "%d/tick" % McpConnection.PACKET_DRAIN_CAP_PER_TICK)
			assert_contains(s, "7 packets spilled")
			assert_contains(s, "cumulative 7")
			matched = true
			break
	assert_true(matched, "expected a [backpressure] log line carrying the spillover counts")
	conn.free()


func test_drain_does_not_log_when_below_cap() -> void:
	## Counterpart guard: normal traffic must NOT emit the backpressure
	## line. A noisy false-positive would train operators to ignore the
	## one signal that actually means flood.
	var conn := McpConnection.new()
	conn.log_buffer = McpLogBuffer.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(5):
		peer.queue_message(_DRAIN_TEST_MSG)

	conn._drain_inbound_packets(peer)

	# Use a single boolean + outer assertion so an empty buffer still
	# fires one assertion (otherwise McpTestSuite's zero-assertion guard
	# would flag this as a skipped test).
	var lines: Array = conn.log_buffer.get_recent(50)
	var saw_backpressure := false
	for line in lines:
		if str(line).find("[backpressure]") >= 0:
			saw_backpressure = true
			break
	assert_false(
		saw_backpressure,
		"normal-traffic frame must not emit a backpressure log line",
	)
	conn.free()


func test_drain_does_not_log_at_exact_cap_with_empty_queue() -> void:
	## Boundary: drained == cap and the peer is empty. The drain *hit*
	## the cap but nothing remains to spill — this isn't a flood signal
	## and must not produce a log line.
	var conn := McpConnection.new()
	conn.log_buffer = McpLogBuffer.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK):
		peer.queue_message(_DRAIN_TEST_MSG)

	conn._drain_inbound_packets(peer)

	var lines: Array = conn.log_buffer.get_recent(50)
	var saw_backpressure := false
	for line in lines:
		if str(line).find("[backpressure]") >= 0:
			saw_backpressure = true
			break
	assert_false(
		saw_backpressure,
		"drain hitting cap exactly with empty queue is not a flood signal",
	)
	conn.free()


func test_clear_on_disconnect_resets_spillover_counter() -> void:
	## A new connection starts with a clean spillover history — the
	## previous connection's flood shouldn't pollute the new baseline.
	var conn := McpConnection.new()
	var peer := _FakeWebSocketPeer.new()
	for i in range(McpConnection.PACKET_DRAIN_CAP_PER_TICK + 3):
		peer.queue_message(_DRAIN_TEST_MSG)
	conn._drain_inbound_packets(peer)
	assert_eq(conn._packet_spillover_total, 3, "precondition: counter populated")

	conn._clear_on_disconnect()

	assert_eq(conn._packet_spillover_total, 0, "disconnect must reset the spillover counter")
	conn.free()


# ----- inbound command-frame validation -----

func _make_conn_with_dispatcher() -> Array:
	var conn := McpConnection.new()
	var dispatcher := McpDispatcher.new(McpLogBuffer.new())
	dispatcher.mcp_logging = false
	conn.dispatcher = dispatcher
	return [conn, dispatcher]


func test_handle_message_enqueues_well_formed_command_frame() -> void:
	var pair := _make_conn_with_dispatcher()
	var conn: McpConnection = pair[0]
	var dispatcher: McpDispatcher = pair[1]
	conn._handle_message('{"request_id": "r1", "command": "noop", "params": {}}')
	conn._handle_message('{"request_id": "r2", "command": "noop"}')
	assert_eq(dispatcher._command_queue.size(), 2,
		"well-formed frames (params optional) must be enqueued")
	conn.free()


func test_handle_message_drops_non_string_request_id() -> void:
	var pair := _make_conn_with_dispatcher()
	var conn: McpConnection = pair[0]
	var dispatcher: McpDispatcher = pair[1]
	conn._handle_message('{"request_id": 5, "command": "noop", "params": {}}')
	assert_eq(dispatcher._command_queue.size(), 0,
		"a non-String request_id would wedge the dispatcher's typed cast")
	conn.free()


func test_handle_message_drops_non_string_command() -> void:
	var pair := _make_conn_with_dispatcher()
	var conn: McpConnection = pair[0]
	var dispatcher: McpDispatcher = pair[1]
	conn._handle_message('{"request_id": "r1", "command": {"nested": true}}')
	assert_eq(dispatcher._command_queue.size(), 0,
		"a non-String command would wedge the dispatcher's typed cast")
	conn.free()


func test_handle_message_drops_non_dict_params() -> void:
	var pair := _make_conn_with_dispatcher()
	var conn: McpConnection = pair[0]
	var dispatcher: McpDispatcher = pair[1]
	conn._handle_message('{"request_id": "r1", "command": "noop", "params": [1, 2]}')
	conn._handle_message('{"request_id": "r2", "command": "noop", "params": "str"}')
	assert_eq(dispatcher._command_queue.size(), 0,
		"non-Dictionary params would wedge the dispatcher's typed cast")
	conn.free()
