## Plugin-side telemetry helper.
##
## Relays plugin-only events (dock startup, self-update outcome, plugin
## reload, dev-server toggle) to the Python MCP server via the existing
## `send_event("plugin_event", {...})` channel. The server's
## `transport/websocket.py` allowlists event names and forwards into the
## central telemetry pipeline — meaning opt-out, endpoint, customer_uuid
## and the bounded-queue worker stay in one place (Python), not
## duplicated in GDScript.
##
## Opt-out: honors `GODOT_AI_DISABLE_TELEMETRY` and `DISABLE_TELEMETRY`
## environment variables on the GDScript side too, so events are never
## buffered (let alone sent) when the operator opts out — useful when
## a tester wants to confirm the disable flag is effective before any
## handshake has happened.
##
## Buffering: events recorded before the WebSocket is connected go into
## a small bounded buffer and flush on the next `record_event` call once
## connected. The buffer is intentionally small (`_MAX_BUFFER`); plugin
## events are sparse, and a flood means something is misconfigured.

extends RefCounted

## Allowlist mirrored on the Python side in
## `src/godot_ai/transport/websocket.py::_PLUGIN_EVENT_NAMES`. Update
## both together.
const _ALLOWED_EVENTS := [
	"dock_startup",
	"plugin_reload",
	"self_update",
	"dev_server_toggle",
]

const _MAX_BUFFER := 32

var _connection
var _disabled: bool = false
var _pending: Array = []  # of {name: String, data: Dictionary}

func _init(connection) -> void:
	_connection = connection
	_disabled = _resolve_disabled()

static func _truthy(value: String) -> bool:
	return value.to_lower() in ["1", "true", "yes", "on"]

static func _resolve_disabled() -> bool:
	if _truthy(OS.get_environment("GODOT_AI_DISABLE_TELEMETRY")):
		return true
	if _truthy(OS.get_environment("DISABLE_TELEMETRY")):
		return true
	return false

func record_event(name: String, data: Dictionary = {}) -> void:
	if _disabled:
		return
	if not _ALLOWED_EVENTS.has(name):
		push_warning("godot_ai.telemetry: dropping unknown event %s" % name)
		return
	if _connection != null and _connection.is_connected:
		_flush()
		_send_one(name, data)
		return
	## Pre-handshake: stash in a small bounded buffer. The buffer is
	## flushed on the next `record_event` after the connection is up,
	## not via a signal (no `connection_changed` signal currently exists
	## and adding one for telemetry would invert the dependency).
	if _pending.size() >= _MAX_BUFFER:
		_pending.pop_front()
	_pending.append({"name": name, "data": data})

func _flush() -> void:
	if _pending.is_empty():
		return
	var to_send := _pending.duplicate()
	_pending.clear()
	for entry in to_send:
		_send_one(entry["name"], entry["data"])

func _send_one(name: String, data: Dictionary) -> void:
	if _connection == null:
		return
	_connection.send_event("plugin_event", {"name": name, "data": data})

# --- convenience emitters --------------------------------------------------

func record_dock_startup(extra: Dictionary = {}) -> void:
	record_event("dock_startup", extra)

func record_plugin_reload(success: bool, error: String = "") -> void:
	var data := {"success": success}
	if error != "":
		data["error"] = error.substr(0, 200)
	record_event("plugin_reload", data)

func record_self_update(
	status: String,
	from_version: String = "",
	to_version: String = "",
	error: String = "",
) -> void:
	var data := {"status": status}
	if from_version != "":
		data["from_version"] = from_version
	if to_version != "":
		data["to_version"] = to_version
	if error != "":
		data["error"] = error.substr(0, 200)
	record_event("self_update", data)

func record_dev_server_toggle(action: String) -> void:
	record_event("dev_server_toggle", {"action": action})

# --- test seam -------------------------------------------------------------

## Inject a fake connection or force the disabled flag for unit tests
## that don't have a live WebSocket. Production code does not call this.
func _test_set_state(connection, disabled: bool) -> void:
	_connection = connection
	_disabled = disabled
	_pending.clear()

func _test_pending_count() -> int:
	return _pending.size()
