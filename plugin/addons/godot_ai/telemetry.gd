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
## Opt-out options priority:
##   1. `GODOT_AI_DISABLE_TELEMETRY` / `DISABLE_TELEMETRY` env vars —
##      checked first so CI / operators can force-disable without touching
##      EditorSettings.
##   2. The `godot_ai/telemetry_enabled` EditorSetting — set through the
##      MCP dock and persisted between sessions.
##
## When telemetry is disabled, events are never buffered or sent. If an env
## var is explicitly set to a non-truthy value, telemetry is enabled even if
## the editor setting is false.
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

## EditorSetting key used to defer a ``plugin_reload`` event across the
## disable -> enable boundary. Callers that trigger plugin reload (the
## dock reload button, ``editor_reload_plugin`` MCP-tool path) write
## here *before* the disable kills the live WebSocket; the new
## plugin's ``_enter_tree`` flushes via ``flush_pending_plugin_reload``.
const PENDING_PLUGIN_RELOAD_KEY := "godot_ai/pending_plugin_reload_event"


## Persist a ``plugin_reload`` event so the re-enabled plugin instance
## can emit it once its new WebSocket is up. Static so callers without
## a telemetry instance handle (e.g. ``editor_handler.reload_plugin``)
## can use it via the preloaded const alias.
static func record_pending_plugin_reload(source: String) -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return
	settings.set_setting(
		PENDING_PLUGIN_RELOAD_KEY,
		JSON.stringify({"source": source, "success": true}),
	)


## Read + clear an EditorSetting JSON-encoded event payload. Returns
## the parsed dict, or ``null`` if the key is absent / empty /
## malformed. Used by ``flush_pending_plugin_reload`` (below) and by
## ``plugin.gd::_flush_pending_self_update_telemetry``. Centralising
## the read-and-clear dance keeps both flush sites symmetric with the
## ``record_pending_*`` writers and prevents the "key gets stuck"
## class of bug if a future flush helper forgets the clear step.
static func _drain_editor_setting_dict(key: String):
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return null
	if not settings.has_setting(key):
		return null
	var raw := str(settings.get_setting(key))
	settings.set_setting(key, "")
	if raw == "":
		return null
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return parsed

var _connection
var _disabled: bool = false
var _pending: Array = []  # of {name: String, data: Dictionary}

func _init(connection) -> void:
	_connection = connection
	_disabled = not McpSettings.telemetry_enabled()
	## Subscribe to ``connection_state_changed`` so events buffered before
	## the WebSocket handshake (e.g. ``record_dock_startup`` from
	## ``plugin._enter_tree``) actually leave the editor. Without this,
	## the buffer only drained on the next ``record_event`` call — when
	## that call never came (the common single-session case), the very
	## events we cared about most sat in the queue forever.
	if _connection != null and _connection.has_signal("connection_state_changed"):
		_connection.connection_state_changed.connect(_on_connection_state_changed)


func record_event(name: String, data: Dictionary = {}) -> void:
	if _disabled:
		return
	if not _ALLOWED_EVENTS.has(name):
		## Drop silently — matches the server's behavior for unknown
		## names, and avoids editor yellow-bar noise from third-party
		## callers or stale event names mid-rollout.
		return
	if _connection != null and _connection.is_connected:
		_flush()
		_send_one(name, data)
		return
	## Pre-handshake: stash in a small bounded buffer. Drained on the
	## first ``connection_state_changed(true)`` after this point (see
	## ``_on_connection_state_changed``). Falling back to "drain on the
	## next record_event" is a footgun: the most useful plugin events
	## (``dock_startup``, pending ``self_update``) fire from
	## ``plugin._enter_tree`` before the handshake, and a single-session
	## editor may never emit a second event — so without the signal-
	## driven flush they sat buffered forever.
	if _pending.size() >= _MAX_BUFFER:
		_pending.pop_front()
	_pending.append({"name": name, "data": data})


func _on_connection_state_changed(is_open: bool) -> void:
	if is_open:
		_flush()

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


## Drain a pending ``plugin_reload`` event written by the previous
## instance before it disabled itself.
func flush_pending_plugin_reload() -> void:
	var parsed = _drain_editor_setting_dict(PENDING_PLUGIN_RELOAD_KEY)
	if parsed == null:
		return
	var data := {
		"success": bool(parsed.get("success", true)),
		"source": str(parsed.get("source", "unknown")),
	}
	var error := str(parsed.get("error", ""))
	if error != "":
		data["error"] = error.substr(0, 200)
	record_event("plugin_reload", data)

# --- test seam -------------------------------------------------------------

## Inject a fake connection or force the disabled flag for unit tests
## that don't have a live WebSocket. Production code does not call this.
func _test_set_state(connection, disabled: bool) -> void:
	_connection = connection
	_disabled = disabled
	_pending.clear()

func _test_pending_count() -> int:
	return _pending.size()
