@tool
extends McpTestSuite

const Telemetry := preload("res://addons/godot_ai/telemetry.gd")

## Tests for the plugin-side telemetry helper.
##
## The helper relays plugin-only events (dock_startup, self_update, …)
## through the existing `send_event("plugin_event", …)` channel. Behavior
## that matters for this layer:
## * Honor the opt-out flag (no buffering, no forwarding).
## * Drop events not in the allowlist.
## * Buffer pre-handshake events up to a bounded count, drop the oldest
##   on overflow, flush on the next emit once connected.

class StubConnection extends RefCounted:
	var is_connected := false
	var sent: Array = []

	func send_event(event_name: String, data: Dictionary = {}) -> bool:
		sent.append({"event": event_name, "data": data})
		return true


func suite_name() -> String:
	return "plugin_telemetry"


# ----- opt-out -----

func test_disabled_drops_event_without_send() -> void:
	var conn := StubConnection.new()
	conn.is_connected = true
	var t := Telemetry.new(conn)
	t._test_set_state(conn, true)  # force disabled

	t.record_dock_startup()
	assert_eq(conn.sent.size(), 0, "Disabled telemetry must not call send_event")
	assert_eq(t._test_pending_count(), 0, "Disabled telemetry must not buffer")


# ----- allowlist -----

func test_unknown_event_is_dropped() -> void:
	var conn := StubConnection.new()
	conn.is_connected = true
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	t.record_event("not_in_allowlist", {})
	assert_eq(conn.sent.size(), 0, "Unknown event names must not reach the wire")


func test_dock_startup_forwards_when_connected() -> void:
	var conn := StubConnection.new()
	conn.is_connected = true
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	t.record_dock_startup({"developer_mode": true})
	assert_eq(conn.sent.size(), 1, "Should send exactly one event")
	var payload: Dictionary = conn.sent[0]
	assert_eq(payload["event"], "plugin_event")
	assert_eq(payload["data"]["name"], "dock_startup")
	assert_eq(payload["data"]["data"]["developer_mode"], true)


# ----- buffering across handshake -----

func test_buffers_when_disconnected_and_flushes_on_next_emit() -> void:
	var conn := StubConnection.new()
	conn.is_connected = false
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	t.record_dock_startup()
	assert_eq(conn.sent.size(), 0, "Pre-connect emits should not call send_event yet")
	assert_eq(t._test_pending_count(), 1)

	## Connect comes up; next emit flushes the queued ones plus the new one.
	conn.is_connected = true
	t.record_self_update("success")
	assert_eq(t._test_pending_count(), 0, "Buffer should drain on flush")
	assert_eq(conn.sent.size(), 2, "Buffered event plus the new one must both flush")


func test_buffer_drops_oldest_at_cap() -> void:
	var conn := StubConnection.new()
	conn.is_connected = false
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	## Push well past the cap; only the cap should remain.
	for i in range(Telemetry._MAX_BUFFER + 5):
		t.record_event("dock_startup", {"i": i})

	assert_eq(t._test_pending_count(), Telemetry._MAX_BUFFER,
		"Buffer must clamp at _MAX_BUFFER and silently drop overflow")
