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
	signal connection_state_changed(is_open: bool)

	var is_connected := false
	var sent: Array = []

	func send_event(event_name: String, data: Dictionary = {}) -> bool:
		sent.append({"event": event_name, "data": data})
		return true

	func flip_connected(is_open: bool) -> void:
		is_connected = is_open
		connection_state_changed.emit(is_open)


const _TENV1 := "GODOT_AI_DISABLE_TELEMETRY"
const _TENV2 := "DISABLE_TELEMETRY"

var _saved_tenv1: Variant = null
var _saved_tenv2: Variant = null
var _had_telemetry_setting: bool = false
var _saved_telemetry_setting: Variant = null


func suite_name() -> String:
	return "plugin_telemetry"


func suite_setup(_ctx: Dictionary) -> void:
	_saved_tenv1 = OS.get_environment(_TENV1) if OS.has_environment(_TENV1) else null
	_saved_tenv2 = OS.get_environment(_TENV2) if OS.has_environment(_TENV2) else null
	var es := EditorInterface.get_editor_settings()
	_had_telemetry_setting = es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED)
	if _had_telemetry_setting:
		_saved_telemetry_setting = es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED)


func suite_teardown() -> void:
	_restore_tenv(_TENV1, _saved_tenv1)
	_restore_tenv(_TENV2, _saved_tenv2)
	var es := EditorInterface.get_editor_settings()
	if not _had_telemetry_setting:
		if es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
			es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, null)
	else:
		es.set_setting(McpSettings.SETTING_TELEMETRY_ENABLED, _saved_telemetry_setting)


func _restore_tenv(name: String, saved: Variant) -> void:
	if saved == null:
		OS.unset_environment(name)
	else:
		OS.set_environment(name, str(saved))


func _clear_telemetry_env_vars() -> void:
	OS.unset_environment(_TENV1)
	OS.unset_environment(_TENV2)


# ----- opt-out -----

func test_disabled_when_editor_setting_is_false() -> void:
	## Regression guard for the UI opt-out / plugin-reload race:
	## _inject_telemetry_env unsets GODOT_AI_DISABLE_TELEMETRY right after
	## OS.create_process, so the new plugin instance's Telemetry constructor
	## must fall back to the persisted EditorSetting instead of re-enabling.
	_clear_telemetry_env_vars()
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, false
	)
	var conn := StubConnection.new()
	var t := Telemetry.new(conn)
	var is_disabled := t._disabled
	assert_true(is_disabled,
		"telemetry must be disabled when EditorSetting is false and no env var is set")


func test_enabled_when_editor_setting_is_true() -> void:
	_clear_telemetry_env_vars()
	EditorInterface.get_editor_settings().set_setting(
		McpSettings.SETTING_TELEMETRY_ENABLED, true
	)
	var conn := StubConnection.new()
	var t := Telemetry.new(conn)
	var is_disabled := t._disabled
	assert_false(is_disabled,
		"telemetry must be enabled when EditorSetting is true and no env var is set")


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


func test_record_dev_server_toggle_emits_event() -> void:
	## dev_server_toggle is synchronous (no plugin reload involved), so
	## it should ship straight through to the WebSocket — no buffering.
	var conn := StubConnection.new()
	conn.is_connected = true
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	t.record_dev_server_toggle("start")
	t.record_dev_server_toggle("stop")

	assert_eq(conn.sent.size(), 2, "Both toggles should ship")
	assert_eq(conn.sent[0]["data"]["name"], "dev_server_toggle")
	assert_eq(conn.sent[0]["data"]["data"]["action"], "start")
	assert_eq(conn.sent[1]["data"]["data"]["action"], "stop")


func test_record_plugin_reload_emits_event() -> void:
	var conn := StubConnection.new()
	conn.is_connected = true
	var t := Telemetry.new(conn)
	t._test_set_state(conn, false)

	t.record_plugin_reload(true)
	t.record_plugin_reload(false, "could not re-enable")

	assert_eq(conn.sent.size(), 2)
	assert_eq(conn.sent[0]["data"]["data"]["success"], true)
	assert_eq(conn.sent[1]["data"]["data"]["success"], false)
	assert_eq(conn.sent[1]["data"]["data"]["error"], "could not re-enable")


func test_buffered_events_flush_when_connection_signal_fires() -> void:
	## Regression: ``record_dock_startup`` runs from ``plugin._enter_tree``
	## *before* the WebSocket reaches OPEN. Without subscribing to
	## ``connection_state_changed`` the buffer would never drain in
	## single-session installs that never emit a second plugin event.
	var conn := StubConnection.new()
	conn.is_connected = false
	var t := Telemetry.new(conn)
	## NOTE: not using _test_set_state because we want the constructor
	## path (which wires up the signal subscription) to run as in prod.
	t._disabled = false  # bypass env opt-out for the test

	t.record_dock_startup()
	t.record_self_update("success")
	assert_eq(conn.sent.size(), 0, "Both events should be buffered pre-connect")
	assert_eq(t._test_pending_count(), 2)

	## Simulate the WebSocket flipping to OPEN — this is what
	## ``Connection._process`` does in production.
	conn.flip_connected(true)

	assert_eq(t._test_pending_count(), 0, "Buffer must drain on connection_state_changed(true)")
	assert_eq(conn.sent.size(), 2, "Both buffered events should ship without a third record_event call")


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
