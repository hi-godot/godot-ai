@tool
extends McpTestSuite

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


# ----- reconnect backoff and logging -----


func test_reconnect_delay_caps_at_sixty_seconds() -> void:
	var expected: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 60.0]
	for i in range(expected.size()):
		assert_eq(McpConnection._reconnect_delay_for_attempt(i), expected[i])
	assert_eq(McpConnection._reconnect_delay_for_attempt(7), 60.0)
	assert_eq(McpConnection._reconnect_delay_for_attempt(42), 60.0)


func test_reconnect_logging_includes_initial_attempts() -> void:
	for attempt in range(1, 6):
		assert_true(
			McpConnection._should_log_reconnect_attempt(attempt),
			"attempt %d should be logged for immediate diagnostics" % attempt,
		)


func test_reconnect_logging_throttles_later_attempts() -> void:
	assert_false(McpConnection._should_log_reconnect_attempt(6), "attempt 6 should be quiet")
	assert_false(McpConnection._should_log_reconnect_attempt(9), "attempt 9 should be quiet")
	assert_true(
		McpConnection._should_log_reconnect_attempt(10),
		"attempt 10 should log periodic progress",
	)
	assert_false(McpConnection._should_log_reconnect_attempt(11), "attempt 11 should be quiet again")
	assert_true(
		McpConnection._should_log_reconnect_attempt(20),
		"attempt 20 should log periodic progress",
	)


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
